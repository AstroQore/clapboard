import CoreAudio
import Foundation

/// Whether this app may capture other applications' audio.
public enum SystemAudioAuthorization: Equatable, Sendable {
    /// Nothing has asked yet in this run.
    case notDetermined
    /// A real tap was created and destroyed successfully.
    case authorized
    /// The HAL refused; the string is what to tell the user.
    case denied(String)

    public var isAuthorized: Bool { self == .authorized }

    public var label: String {
        switch self {
        case .notDetermined: return "System audio access not checked yet"
        case .authorized: return "System audio access granted"
        case .denied(let reason): return reason
        }
    }
}

/// The system-audio-capture permission, which is **not** the Microphone one.
///
/// Core Audio process taps sit behind their own TCC service. Unlike the
/// microphone, `AVFoundation` has no `requestAccess` for it and there is no
/// public "status" query either: the only supported way to find out is to
/// create a tap and see whether the HAL allows it. `probe()` therefore *is*
/// the request — the first call raises the system prompt (the app must declare
/// `NSAudioCaptureUsageDescription` in its `Info.plist` for that prompt to
/// appear at all), and the answer comes back on a later call once the user has
/// decided.
///
/// The probe deliberately builds the same kind of tap the engine builds — a
/// real, private, unmuted system-wide tap excluding Clapboard itself — and
/// destroys it immediately, so a pass here means the engine's taps will pass
/// too, and it leaves nothing behind.
public enum ProcessTapPermission {
    /// The System Settings pane the permission lives in. Kept in one place so
    /// every error string names the same thing.
    public static let settingsPaneName = "Audio Recording"

    public static func probe() -> SystemAudioAuthorization {
        do {
            let tap = try ProcessTapFactory.make(
                TapSpec(target: .systemAudio, name: "permission probe", mono: true))
            tap.destroy()
            return .authorized
        } catch let error as ProcessTapError {
            return .denied(error.description)
        } catch {
            return .denied(String(describing: error))
        }
    }
}
