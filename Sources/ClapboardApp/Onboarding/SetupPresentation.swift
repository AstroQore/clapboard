import ClapboardCore
import SwiftUI

/// Everything the setup assistant adds to the main window, in one modifier so
/// that `ClapboardApp` gains a single line rather than a block.
///
/// Two things: the assistant sheet, and a banner for the one driver state a
/// user cannot work out on their own — the plug-in is on disk but `coreaudiod`
/// is not publishing the buses, so nothing in the device list explains why
/// `Clapboard Bus 1` is missing.
struct SetupPresentation: ViewModifier {
    @Bindable var onboarding: OnboardingController
    let installer: DriverInstaller
    let permission: MicrophonePermission
    let registry: AudioDeviceRegistry
    let engine: AudioEngine

    @State private var bannerDismissed = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if showBanner {
                    coreAudioBanner
                }
            }
            .sheet(isPresented: $onboarding.isPresented) {
                OnboardingView(
                    onboarding: onboarding,
                    installer: installer,
                    permission: permission,
                    engine: engine
                )
            }
            .onAppear {
                installer.attach(registry: registry)
                onboarding.presentIfNeeded()
            }
            // The registry republishes on every hot-plug, and a coreaudiod
            // restart is a hot-plug as far as the HAL is concerned.
            .onChange(of: registry.generation) { _, _ in installer.refresh() }
    }

    private var showBanner: Bool {
        installer.status.needsCoreAudioRestart && !bannerDismissed && !onboarding.isPresented
    }

    private var coreAudioBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(
                "The Clapboard virtual-device driver is installed, but Core Audio "
                + "is not publishing Clapboard Bus 1…4 yet."
            )
            .font(.callout)
            Spacer(minLength: 8)
            Button("Open Setup Assistant") { onboarding.present(at: .virtualDevices) }
            Button {
                bannerDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
