import Foundation
import Observation
import Sparkle

/// The release stream Clapboard asks Sparkle to follow.
///
/// Sparkle always includes its untagged default channel, so Dev is additive:
/// selecting it adds the `dev` channel on top and a Dev user still receives a
/// newer Main release. There is no channel that receives Dev *only*.
enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case main
    case dev

    var id: String { rawValue }

    var label: String {
        switch self {
        case .main: return "Main"
        case .dev: return "Dev"
        }
    }

    var detail: String {
        switch self {
        case .main: return "Stable releases only."
        case .dev: return "Preview releases plus all Main releases."
        }
    }

    /// Channel names returned from `SPUUpdaterDelegate.allowedChannels(for:)`.
    ///
    /// An empty set means Sparkle's default (Main) channel only.
    var additionalSparkleChannels: Set<String> {
        switch self {
        case .main: return []
        case .dev: return ["dev"]
        }
    }
}

/// Sparkle's delegate has to be an `NSObject`, and Sparkle asks it which
/// channels apply every time it evaluates the appcast. Keeping it separate
/// from the `@Observable` controller means the observation machinery never has
/// to coexist with `NSObject` dynamic dispatch.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    /// Written by `AppUpdateController` on the main thread, read by Sparkle on
    /// the main thread while it filters appcast items.
    var channel: UpdateChannel = .main

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channel.additionalSparkleChannels
    }
}

/// Owns Sparkle's standard updater and the channel preference behind
/// **Clapboard › Check for Updates…** and **Clapboard › Update Channel**.
///
/// Clapboard is a windowed app, so both live in the app menu next to the setup
/// assistant entries rather than in a menu-bar popover.
@MainActor
@Observable
final class AppUpdateController {
    /// What `Resources/Info.plist` ships until a maintainer pastes the real
    /// public key in (see `RELEASING.md`). A build that still carries it must
    /// never start Sparkle: an updater with no usable key would download an
    /// archive it cannot verify.
    static let publicKeyPlaceholder = "REPLACE_ME_WITH_SPARKLE_PUBLIC_ED_KEY"

    private static let channelDefaultsKey = "updateChannel"
    private static let expectedBundleIdentifier = "com.astroqore.Clapboard"

    /// Mirrors `SPUUpdater.canCheckForUpdates`; false while a check is already
    /// running, and permanently false in a build with no updater.
    private(set) var canCheckForUpdates = false

    /// Nil once Sparkle is running. Otherwise a sentence for the menu saying
    /// why in-app updates are off in this build, instead of a silently dead
    /// menu item.
    let unavailableReason: String?

    private(set) var channel: UpdateChannel

    @ObservationIgnored private let bundle: Bundle
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let delegate = UpdaterDelegate()
    @ObservationIgnored private var updaterController: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    /// `isEnabled: false` leaves Sparkle entirely unstarted — no updater, no
    /// scheduled check, no read of its defaults. A bundle without a feed URL
    /// or with the placeholder public key ends up in the same state on its own,
    /// which is what `swift build` output and every unsigned local build get.
    init(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        isEnabled: Bool = true
    ) {
        self.bundle = bundle
        self.defaults = defaults
        self.channel = defaults.string(forKey: Self.channelDefaultsKey)
            .flatMap(UpdateChannel.init(rawValue:)) ?? .main
        self.unavailableReason = Self.unavailableReason(for: bundle, isEnabled: isEnabled)
        delegate.channel = channel

        guard unavailableReason == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        updaterController = controller
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    /// `1.2.0 (7)` — the version pair Sparkle compares against the appcast.
    var currentVersionDescription: String {
        let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Development"
        guard let build = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String else {
            return version
        }
        return "\(version) (\(build))"
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    func setChannel(_ channel: UpdateChannel) {
        guard self.channel != channel else { return }
        self.channel = channel
        delegate.channel = channel
        defaults.set(channel.rawValue, forKey: Self.channelDefaultsKey)
        // The next scheduled check would otherwise still be filtered against
        // the channel that was selected when it was scheduled.
        updaterController?.updater.resetUpdateCycleAfterShortDelay()
    }

    private static func unavailableReason(for bundle: Bundle, isEnabled: Bool) -> String? {
        guard isEnabled else { return "In-app updates are turned off in this build." }
        guard bundle.bundleIdentifier == expectedBundleIdentifier else {
            // `swift run` and the test bundle both land here, and neither has
            // any business talking to the update feed.
            return "In-app updates need the packaged Clapboard.app."
        }
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feed.isEmpty else {
            return "This build has no update feed URL."
        }
        guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty, key != publicKeyPlaceholder else {
            return "This build has no Sparkle public key yet."
        }
        return nil
    }
}
