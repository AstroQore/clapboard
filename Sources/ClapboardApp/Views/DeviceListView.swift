import AVFoundation
import ClapboardCore
import SwiftUI

struct DeviceListView: View {
    let registry: AudioDeviceRegistry
    let permission: MicrophonePermission

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            permissionBanner
            Divider()
            Table(registry.devices) {
                TableColumn("Device") { device in
                    HStack(spacing: 6) {
                        Text(device.name)
                        if device.uid == registry.defaultInputUID {
                            badge("IN")
                        }
                        if device.uid == registry.defaultOutputUID {
                            badge("OUT")
                        }
                        if device.isHidden {
                            badge("hidden")
                        }
                    }
                }
                TableColumn("Transport") { device in
                    Text(device.transport.label)
                }
                .width(min: 80, ideal: 110)
                TableColumn("In") { device in
                    Text(device.hasInput ? streamsLabel(device.inputStreamChannels) : "–")
                        .monospacedDigit()
                }
                .width(min: 40, ideal: 60)
                TableColumn("Out") { device in
                    Text(device.hasOutput ? streamsLabel(device.outputStreamChannels) : "–")
                        .monospacedDigit()
                }
                .width(min: 40, ideal: 60)
                TableColumn("Rate") { device in
                    Text(rateLabel(device))
                        .monospacedDigit()
                        .foregroundStyle(device.supports(sampleRate: 48_000) ? .primary : .secondary)
                }
                .width(min: 90, ideal: 130)
                TableColumn("UID") { device in
                    Text(device.uid)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Divider()
            footer
        }
    }

    private var permissionBanner: some View {
        HStack {
            Image(systemName: permission.status == .authorized ? "mic.fill" : "mic.slash")
                .foregroundStyle(permission.status == .authorized ? .green : .orange)
            Text(permission.label)
                .font(.callout)
            Spacer()
            if permission.status == .notDetermined {
                Button("Allow Microphone") { permission.request() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Text("\(registry.devices.count) devices · updates automatically on plug / unplug")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = registry.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer()
            Button("Refresh") { registry.refresh() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }

    private func streamsLabel(_ streams: [Int]) -> String {
        streams.count == 1 ? "\(streams[0])" : streams.map(String.init).joined(separator: "+")
    }

    private func rateLabel(_ device: AudioDeviceInfo) -> String {
        let current = device.nominalSampleRate / 1000
        let formatted = current == current.rounded() ? String(Int(current)) : String(format: "%.1f", current)
        return "\(formatted) kHz" + (device.supports(sampleRate: 48_000) ? "" : " (no 48k)")
    }
}
