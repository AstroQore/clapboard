import Foundation

/// Whether the first-run setup assistant should open by itself.
///
/// The answer is keyed on the app version that last *completed* the assistant,
/// not on a boolean. A boolean can only ever be flipped once, so a release
/// that adds a step (a new permission, a second driver) would have no way to
/// show it to anyone who has already run the assistant once. Storing the
/// version lets a later release raise `requiredVersion` and re-run the flow
/// exactly for the people who have not seen the new step.
///
/// This lives outside the session document on purpose: it is a fact about
/// this Mac's setup, not part of the mix, and copying a session file to
/// another machine must not claim that machine is already set up.
public enum SetupCompletion {
    /// `UserDefaults` key holding the app version that completed the assistant.
    public static let defaultsKey = "setupAssistantCompletedVersion"

    /// Raise this when a new step is added that existing users must see.
    /// Anyone whose recorded version is older gets the assistant again.
    public static let requiredVersion = "0.1.0"

    /// Pure: present when nothing has been recorded, when what was recorded is
    /// unparseable, or when it predates the version that introduced the newest
    /// step.
    public static func shouldPresent(
        completedVersion: String?,
        required: String = requiredVersion
    ) -> Bool {
        guard let completedVersion,
              let completed = DriverVersion(completedVersion)
        else { return true }
        guard let required = DriverVersion(required) else { return false }
        return completed < required
    }
}
