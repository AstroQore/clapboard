import ClapboardCore
import SwiftUI

/// The ⌘, sheet: one row per action, each with the key that fires it.
struct HotkeysSettingsView: View {
    let hotkeys: HotkeyManager
    let engine: AudioEngine

    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Lanes that do not have a toggle row yet — the contents of the "+" menu.
    private var lanesWithoutBinding: [LaneConfig] {
        let bound = Set(hotkeys.entries.compactMap { entry -> UUID? in
            if case .toggleLaneMute(let id) = entry.action { return id }
            return nil
        })
        return engine.lanes.filter { !bound.contains($0.id) }
    }

    private var missingGlobalActions: [HotkeyAction] {
        HotkeyAction.globalActions.filter { action in
            !hotkeys.entries.contains { $0.action == action }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            rows
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 520, height: 420)
        .onReceive(tick) { now = $0 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Global shortcuts")
                .font(.headline)
            Text("These work while another app is in front — no Accessibility permission needed. Click a shortcut to record a new one; press ⎋ to cancel or ⌫ to clear.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rows: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(hotkeys.entries) { entry in
                    row(for: entry)
                    Divider()
                }
                if hotkeys.entries.isEmpty {
                    Text("No shortcuts yet.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 20)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func row(for entry: HotkeyEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.action.title(lanes: engine.lanes))
                    .foregroundStyle(entry.action.isImplemented ? .primary : .secondary)
                if let note = entry.action.unavailableNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                } else if let error = hotkeys.registrationErrors[entry.action] {
                    Text(error).font(.caption).foregroundStyle(.orange)
                } else if let fired = firedNote(entry.action) {
                    Text(fired).font(.caption).foregroundStyle(.green)
                }
            }
            Spacer(minLength: 8)

            KeyRecorderView(
                binding: entry.binding,
                isEnabled: entry.action.isImplemented
            ) { newBinding in
                hotkeys.setBinding(newBinding, for: entry.action)
            }
            .frame(width: 116, height: 22)

            Button {
                hotkeys.perform(entry.action)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(!entry.action.isImplemented || engine.lanes.isEmpty)
            .help("Run this action now, without the keyboard")

            Button {
                hotkeys.removeAction(entry.action)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this shortcut")
        }
        .padding(.vertical, 7)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    ForEach(missingGlobalActions, id: \.self) { action in
                        Button(action.title) { hotkeys.addAction(action) }
                    }
                    if !missingGlobalActions.isEmpty && !lanesWithoutBinding.isEmpty {
                        Divider()
                    }
                    ForEach(lanesWithoutBinding) { lane in
                        Button("Toggle \(lane.name)") {
                            hotkeys.addAction(.toggleLaneMute(laneID: lane.id))
                        }
                    }
                    if missingGlobalActions.isEmpty && lanesWithoutBinding.isEmpty {
                        Text("Every action already has a row")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                if let url = hotkeys.fileURL {
                    Button("Reveal hotkeys.json") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.link)
                    .help(url.path)
                }
            }

            if !hotkeys.conflicts.isEmpty {
                ForEach(Array(hotkeys.conflicts.keys), id: \.self) { key in
                    Label(
                        "\(key.displayString) is on \(hotkeys.conflicts[key]?.count ?? 0) actions — only the first will fire.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            if let error = hotkeys.lastFileError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            // macOS accepts the registration of a key it has already claimed
            // for itself and then keeps the key, so the only honest test is to
            // press it and watch the row light up.
            Text("Bus and solo shortcuts arrive with the bus routing model. If a shortcut never lights up green, macOS or another app already owns that key — pick another.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func firedNote(_ action: HotkeyAction) -> String? {
        guard let last = hotkeys.lastTriggered, last.action == action else { return nil }
        let age = now.timeIntervalSince(last.date)
        guard age < 5 else { return nil }
        return age < 1.5 ? "fired just now" : "fired \(Int(age))s ago"
    }
}
