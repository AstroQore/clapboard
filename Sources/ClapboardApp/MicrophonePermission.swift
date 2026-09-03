import AVFoundation
import Observation

/// Tracks the TCC microphone authorization for this app.
///
/// Without authorization the HAL silently delivers zeros instead of an
/// error, so the engine must never start before this reports `.authorized`.
@MainActor
@Observable
final class MicrophonePermission {
    private(set) var status: AVAuthorizationStatus = .notDetermined

    func refresh() {
        status = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func request() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in
                self.refresh()
            }
        }
    }

    var label: String {
        switch status {
        case .authorized: return "Microphone access granted"
        case .denied: return "Microphone access denied — enable Clapboard in System Settings › Privacy & Security › Microphone"
        case .restricted: return "Microphone access restricted by policy"
        case .notDetermined: return "Microphone access not requested yet"
        @unknown default: return "Microphone access: unknown state"
        }
    }
}
