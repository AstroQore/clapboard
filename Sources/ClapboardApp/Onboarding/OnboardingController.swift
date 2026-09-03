import ClapboardCore
import Foundation
import Observation

/// Presentation state for the first-run setup assistant.
///
/// Every step is skippable and the sheet is dismissible at any point: nothing
/// in Clapboard is gated behind finishing it. Skipping is recorded so the last
/// step can say plainly what was left undone.
@MainActor
@Observable
final class OnboardingController {
    enum Step: Int, CaseIterable, Identifiable, Hashable {
        case welcome
        case microphone
        case virtualDevices
        case ready

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome: return "Welcome to Clapboard"
            case .microphone: return "Microphone access"
            case .virtualDevices: return "Virtual devices"
            case .ready: return "Ready"
            }
        }
    }

    var isPresented = false
    private(set) var step: Step = .welcome
    private(set) var skipped: Set<Step> = []

    private let defaults: UserDefaults
    private let appVersion: String

    init(
        defaults: UserDefaults = .standard,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? SetupCompletion.requiredVersion
    ) {
        self.defaults = defaults
        self.appVersion = appVersion
    }

    /// Opens the assistant on launch when this Mac has never finished it — or
    /// finished it before the version that introduced the newest step.
    func presentIfNeeded() {
        guard SetupCompletion.shouldPresent(
            completedVersion: defaults.string(forKey: SetupCompletion.defaultsKey)
        ) else { return }
        present(at: .welcome)
    }

    /// Opens it on demand, from the menu item.
    func present(at step: Step) {
        self.step = step
        skipped.remove(step)
        isPresented = true
    }

    var isFirstStep: Bool { step == Step.allCases.first }
    var isLastStep: Bool { step == Step.allCases.last }

    /// 0…1, for the progress bar in the header.
    var progress: Double {
        Double(step.rawValue) / Double(max(Step.allCases.count - 1, 1))
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        skipped.remove(previous)
        step = previous
    }

    /// Marks the current step as skipped and moves on. The last step has
    /// nothing to skip.
    func skip() {
        guard !isLastStep else { return finish() }
        skipped.insert(step)
        advance()
    }

    /// Records that this version's assistant has been *completed* and closes
    /// it. Reached by "Done", and by "Skip" on the last step.
    ///
    /// Closing the sheet another way — Escape, or clicking outside it —
    /// deliberately does not record anything, so the assistant comes back on
    /// the next launch. Escape is "not now", not "I have set this up", and
    /// the flow is four screens with a Skip on each: a user who means to
    /// dismiss it for good has a button that says so.
    func finish() {
        defaults.set(appVersion, forKey: SetupCompletion.defaultsKey)
        isPresented = false
    }
}
