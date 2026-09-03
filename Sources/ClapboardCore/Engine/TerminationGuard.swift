import Darwin
import Dispatch
import Foundation

/// Tears every live engine down when the process is asked to die by signal.
///
/// `applicationWillTerminate` only runs for a Quit Apple event. `pkill`,
/// `kill`, Ctrl-C and a closing terminal deliver SIGTERM / SIGINT / SIGHUP,
/// which would otherwise end the process with its IOProc running and its
/// private aggregate device still registered with coreaudiod. Registered
/// engines are shut down on the main queue and the process then exits with
/// the conventional 128 + signal status.
@MainActor
public enum TerminationGuard {
    private struct Entry {
        weak var engine: AudioEngine?
    }

    private static var entries: [Entry] = []
    private static var sources: [DispatchSourceSignal] = []

    /// Called by `AudioEngine.init`; installs the signal sources on first use.
    public static func register(_ engine: AudioEngine) {
        entries.removeAll { $0.engine == nil }
        entries.append(Entry(engine: engine))
        installIfNeeded()
    }

    /// Shuts every registered engine down. Safe to call more than once.
    public static func shutdownAll() {
        for entry in entries {
            entry.engine?.shutdown()
        }
        entries.removeAll()
    }

    private static func installIfNeeded() {
        guard sources.isEmpty else { return }
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            // The default disposition would kill the process before the
            // dispatch source ever fires.
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    shutdownAll()
                    exit(128 + signalNumber)
                }
            }
            source.resume()
            sources.append(source)
        }
    }
}
