import AVFoundation
import AppKit
import ClapboardCore
import SwiftUI

/// The first-run setup assistant: what Clapboard is, the microphone
/// permission, and the virtual devices — four skippable steps in one sheet.
///
/// Nothing here is a gate. The sheet can be closed at any step and the app is
/// fully usable behind it; the Help menu brings it back.
struct OnboardingView: View {
    @Bindable var onboarding: OnboardingController
    let installer: DriverInstaller
    let permission: MicrophonePermission
    let engine: AudioEngine?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 540, height: 460)
        .onAppear {
            permission.refresh()
            installer.refresh()
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(onboarding.step.title)
                    .font(.headline)
                Spacer()
                Text("Step \(onboarding.step.rawValue + 1) of \(OnboardingController.Step.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: onboarding.progress)
                .progressViewStyle(.linear)
                .accessibilityLabel("Setup progress")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Button("Back") { onboarding.back() }
                .disabled(onboarding.isFirstStep)
            Spacer()
            if !onboarding.isLastStep {
                // A plain button, not `.buttonStyle(.link)`: skipping a step is
                // an action, and the link style publishes it to the
                // accessibility tree as `AXLink` with no name.
                Button("Skip") { onboarding.skip() }
            }
            Button(onboarding.isLastStep ? "Done" : "Continue") {
                onboarding.isLastStep ? onboarding.finish() : onboarding.advance()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch onboarding.step {
        case .welcome: welcomeStep
        case .microphone: microphoneStep
        case .virtualDevices: virtualDevicesStep
        case .ready: readyStep
        }
    }

    // MARK: - 1. Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Many microphones, one mix.")
                .font(.title3.weight(.medium))
            Text(
                "Clapboard captures several microphones at once, lines them up by "
                + "the sound of a single clap, and mixes them into one output. "
                + "Each microphone gets its own fader, mute, and effects; the "
                + "result goes wherever you want it."
            )
            bullet("mic.fill", "Add a lane per microphone, from any input device on this Mac.")
            bullet("hand.clap.fill", "Clap once. Auto Sync measures the delay between lanes and corrects it.")
            bullet("slider.vertical.3", "Mix, route to buses, and send the result to speakers or to another app.")
            Divider().padding(.vertical, 2)
            Label {
                Text(
                    "Everything happens on this Mac. Clapboard has no account, no "
                    + "network access, and sends nothing anywhere. The only file it "
                    + "writes is its own session in your Application Support folder."
                )
            } icon: {
                Image(systemName: "lock.fill")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - 2. Microphone

    private var microphoneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                "Clapboard needs macOS's microphone permission to read any audio "
                + "input — including USB interfaces and mixers, not just the "
                + "built-in microphone."
            )
            Label {
                Text(
                    "Without it macOS does not report an error: it hands Clapboard "
                    + "digital silence. Meters sit still and recordings come back "
                    + "empty, with nothing to explain why."
                )
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            statusBox(
                icon: microphoneIcon,
                tint: microphoneTint,
                text: permission.label
            )

            HStack(spacing: 10) {
                Button("Allow Microphone Access…") { permission.request() }
                    .disabled(permission.status != .notDetermined)
                if permission.status == .denied || permission.status == .restricted {
                    Button("Open System Settings…") { openMicrophoneSettings() }
                }
            }
            if permission.status == .denied {
                Text(
                    "macOS only shows its permission prompt once. Turn Clapboard on "
                    + "under Privacy & Security › Microphone, then come back here."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var microphoneIcon: String {
        switch permission.status {
        case .authorized: return "checkmark.circle.fill"
        case .denied, .restricted: return "xmark.circle.fill"
        default: return "questionmark.circle.fill"
        }
    }

    private var microphoneTint: Color {
        switch permission.status {
        case .authorized: return .green
        case .denied, .restricted: return .red
        default: return .secondary
        }
    }

    private func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 3. Virtual devices

    private var virtualDevicesStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                "Clapboard can add four audio devices to this Mac, named "
                + "Clapboard Bus 1 to Clapboard Bus 4, so OBS, Zoom, Discord or "
                + "QuickTime can hear your mix. Send a bus to one of them here, "
                + "then pick the same one as the microphone over there."
            )
            Label {
                Text("Optional. Speakers and headphones work without this.")
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            statusBox(icon: driverIcon, tint: driverTint, text: installer.status.summary)

            switch installer.phase {
            case .awaitingInstall, .awaitingUninstall:
                waitingRow
            case .installed:
                finishedRow("checkmark.circle.fill", .green, "The buses are here. You can close the Installer.")
            case .uninstalled:
                finishedRow("checkmark.circle.fill", .green, "The virtual devices have been removed.")
            case .timedOut:
                finishedRow(
                    "clock.badge.exclamationmark", .orange,
                    "Stopped watching after three minutes. If you finished the "
                    + "Installer, reopen this assistant to check."
                )
            case .failed(let message):
                finishedRow("xmark.circle.fill", .red, message)
            case .idle:
                installerNotes
            }

            HStack(spacing: 10) {
                Button(installButtonTitle) { installer.install(engine: engine) }
                    .disabled(!installer.status.canInstall || isBusy)
                if installer.status.canUninstall {
                    Button("Uninstall…") { installer.uninstall(engine: engine) }
                        .disabled(isBusy)
                }
                if isBusy || installer.phase != .idle {
                    Button("Stop Waiting") { installer.acknowledge() }
                }
            }
            if !installer.status.canInstall {
                Text(
                    "No installer package was built into this copy of Clapboard. "
                    + "Build one with Scripts/build_driver_pkg.sh and rebuild the app."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var installButtonTitle: String {
        switch installer.status.state {
        case .outdated: return "Update…"
        case .installed: return "Reinstall…"
        default: return "Install…"
        }
    }

    private var isBusy: Bool {
        installer.phase == .awaitingInstall || installer.phase == .awaitingUninstall
    }

    /// The three things a person deserves to know before an administrator
    /// password prompt appears.
    private var installerNotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            bullet(
                "key.fill",
                "macOS's own Installer opens and asks for an administrator "
                + "password. Clapboard never sees it."
            )
            bullet(
                "speaker.slash.fill",
                "Core Audio restarts at the end, so audio on this Mac cuts out for "
                + "a second. Clapboard stops its engine first."
            )
            bullet(
                "clock.fill",
                "You can do this later — Clapboard › Set Up Virtual Devices…"
            )
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var waitingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(
                installer.phase == .awaitingUninstall
                    ? "Waiting for the uninstaller to finish…"
                    : "Installer opened. Waiting for Clapboard Bus 1 to appear…"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func finishedRow(_ icon: String, _ tint: Color, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
        .font(.callout)
    }

    private var driverIcon: String {
        if installer.status.needsCoreAudioRestart { return "exclamationmark.triangle.fill" }
        switch installer.status.state {
        case .installed: return installer.status.devicesPresent
            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        case .outdated: return "arrow.triangle.2.circlepath.circle.fill"
        case .notInstalled: return "circle.dashed"
        case .installerUnavailable: return "xmark.circle.fill"
        }
    }

    private var driverTint: Color {
        if installer.status.needsCoreAudioRestart { return .orange }
        switch installer.status.state {
        case .installed: return .green
        case .outdated: return .orange
        case .notInstalled: return .secondary
        case .installerUnavailable: return .red
        }
    }

    // MARK: - 4. Ready

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Never claim a setup that did not happen: a user who skipped both
            // steps is ready to start, not set up.
            Text(microphoneReady && installer.status.devicesPresent
                ? "You're set up."
                : "You can start now.")
                .font(.title3.weight(.medium))
            VStack(alignment: .leading, spacing: 10) {
                summaryRow(
                    done: microphoneReady,
                    skipped: onboarding.skipped.contains(.microphone),
                    done_: "Microphone access granted.",
                    todo: "Microphone access is not granted — lanes will record silence "
                        + "until it is."
                )
                summaryRow(
                    done: installer.status.devicesPresent,
                    skipped: onboarding.skipped.contains(.virtualDevices),
                    done_: "Clapboard Bus 1…\(max(installer.status.busDeviceUIDs.count, 1)) "
                        + "are available to other apps.",
                    todo: "Virtual devices are not set up — the mix can still go to any "
                        + "real output device."
                )
            }
            Divider().padding(.vertical, 2)
            Text(
                "Add a lane for each microphone, clap once and run Auto Sync, then "
                + "mix. Anything you skipped is one menu item away: "
                + "Clapboard › Show Setup Assistant."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var microphoneReady: Bool { permission.status == .authorized }

    private func summaryRow(
        done: Bool, skipped: Bool, done_: String, todo: String
    ) -> some View {
        Label {
            Text(done ? done_ : todo)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : (skipped ? "minus.circle" : "circle"))
                .foregroundStyle(done ? Color.green : Color.secondary)
        }
    }

    // MARK: - Shared pieces

    private func bullet(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon).foregroundStyle(.tint)
        }
    }

    private func statusBox(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
