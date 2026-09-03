import ClapboardCore
import SwiftUI

/// One lane's — or the master's — effect chain, as a row of chips.
///
/// Click a chip to bypass it, double-click to open the plug-in's own editor,
/// and use the chip's menu to reorder or remove it. `laneID == nil` is the
/// master bus, the same convention `AudioEngine.addEffect` uses.
struct EffectChainView: View {
    let engine: AudioEngine
    let laneID: UUID?

    @State private var showingPicker = false

    private var chain: [EffectConfig] {
        engine.effects(forLane: laneID)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "slider.horizontal.below.rectangle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("Effect chain — after the delay, before the fader")

            ForEach(Array(chain.enumerated()), id: \.element.id) { index, effect in
                EffectChipView(
                    engine: engine,
                    effect: effect,
                    index: index,
                    count: chain.count
                )
            }

            Button {
                showingPicker = true
            } label: {
                Image(systemName: "plus")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("Insert an Audio Unit")
            .disabled(chain.count >= RTLimits.maxEffectsPerChain)

            if engine.restoringEffects {
                ProgressView()
                    .controlSize(.mini)
                    .help("Loading the plug-ins this session saved")
            }

            Spacer(minLength: 0)

            if let laneID {
                LanePDCReadout(engine: engine, laneID: laneID)
            }
        }
        .sheet(isPresented: $showingPicker) {
            EffectPickerSheet(engine: engine, laneID: laneID)
        }
    }
}

/// "PDC +N sp": how much extra delay this lane is carrying so it stays level
/// with the lane whose chain is slowest.
private struct LanePDCReadout: View {
    let engine: AudioEngine
    let laneID: UUID

    var body: some View {
        let compensation = engine.pdcSamples[laneID] ?? 0
        let chain = engine.laneChainLatency(laneID)
        if compensation > 0 || chain > 0 {
            Text("PDC +\(compensation) sp")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(compensation > 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .help("This lane's plug-ins add \(chain) samples of latency; "
                      + "\(compensation) samples of delay are added on top so it stays "
                      + "aligned with the slowest lane.")
        }
    }
}

/// One plug-in.
private struct EffectChipView: View {
    let engine: AudioEngine
    let effect: EffectConfig
    let index: Int
    let count: Int

    @State private var hovering = false

    private var shortName: String {
        let trimmed = effect.displayName.split(separator: ":").last.map(String.init)
            ?? effect.displayName
        return trimmed.trimmingCharacters(in: .whitespaces)
    }

    private var latency: Int { engine.effectLatencySamples(id: effect.id) }

    var body: some View {
        HStack(spacing: 4) {
            Text(shortName)
                .font(.caption)
                .lineLimit(1)
            if latency > 0, !effect.bypass {
                Text("\(latency)sp")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if hovering {
                Button {
                    engine.removeEffect(id: effect.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(background, in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                effect.isAvailable ? Color.clear : Color.orange.opacity(0.6))
        }
        .foregroundStyle(foreground)
        .onHover { hovering = $0 }
        // Order matters: SwiftUI matches the higher count first, so the
        // single-click bypass never swallows a double-click.
        .onTapGesture(count: 2) {
            guard effect.isAvailable else { return }
            engine.openEffectWindow(id: effect.id)
        }
        .onTapGesture {
            guard effect.isAvailable else { return }
            engine.setEffectBypass(id: effect.id, !effect.bypass)
        }
        .help(helpText)
        .contextMenu {
            Button("Open Editor") { engine.openEffectWindow(id: effect.id) }
                .disabled(!effect.isAvailable)
            Button(effect.bypass ? "Enable" : "Bypass") {
                engine.setEffectBypass(id: effect.id, !effect.bypass)
            }
            .disabled(!effect.isAvailable)
            Divider()
            Button("Move Left") { engine.moveEffect(id: effect.id, to: index - 1) }
                .disabled(index == 0)
            Button("Move Right") { engine.moveEffect(id: effect.id, to: index + 1) }
                .disabled(index >= count - 1)
            Divider()
            Button("Remove", role: .destructive) { engine.removeEffect(id: effect.id) }
        }
        .onDeleteCommand { engine.removeEffect(id: effect.id) }
    }

    private var background: AnyShapeStyle {
        if !effect.isAvailable { return AnyShapeStyle(.quaternary) }
        return effect.bypass
            ? AnyShapeStyle(.quaternary)
            : AnyShapeStyle(Color.accentColor.opacity(0.25))
    }

    private var foreground: AnyShapeStyle {
        effect.isAvailable && !effect.bypass
            ? AnyShapeStyle(.primary)
            : AnyShapeStyle(.secondary)
    }

    private var helpText: String {
        if let reason = effect.unavailableReason { return "\(effect.displayName) — \(reason)" }
        return "\(effect.displayName)\(effect.bypass ? " (bypassed)" : "")"
            + " · \(latency) samples latency"
            + " · click to bypass, double-click for its editor"
    }
}

// MARK: - Picker

/// The plug-in menu: search, grouped by manufacturer with Apple first.
struct EffectPickerSheet: View {
    let engine: AudioEngine
    let laneID: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Entry] = []
    @State private var loading = true
    @State private var search = ""
    @State private var inserting: String?
    @State private var failure: String?

    struct Entry: Identifiable, Sendable {
        let info: AUComponentInfo
        /// Why Clapboard cannot host it here, if it cannot.
        let unavailableReason: String?
        var id: String { info.id }
    }

    private var groups: [(manufacturer: String, entries: [Entry])] {
        let matching = entries.filter { entry in
            guard !search.isEmpty else { return true }
            return entry.info.displayName.localizedCaseInsensitiveContains(search)
                || entry.info.id.localizedCaseInsensitiveContains(search)
        }
        let grouped = Dictionary(grouping: matching) { $0.info.manufacturerName }
        return grouped.keys.sorted { left, right in
            // Apple first: on an Apple Silicon Mac its effects are frequently
            // the only ones that can be hosted at all.
            if (left == "Apple") != (right == "Apple") { return left == "Apple" }
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if loading {
                ProgressView("Reading the plug-in folder…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 460)
        .task { await load() }
    }

    private var header: some View {
        HStack {
            Text(laneID == nil ? "Add Master Effect" : "Add Lane Effect")
                .font(.headline)
            Spacer()
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
        .padding(12)
    }

    private var list: some View {
        List {
            ForEach(groups, id: \.manufacturer) { group in
                Section(group.manufacturer.isEmpty ? "Unknown" : group.manufacturer) {
                    ForEach(group.entries) { entry in
                        row(entry)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.info.name)
                    .lineLimit(1)
                Text("\(entry.info.id) · \(entry.info.isAUv3 ? "AUv3" : "AUv2") "
                     + "· \(entry.info.versionString)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if inserting == entry.id {
                ProgressView().controlSize(.mini)
            }
        }
        .contentShape(Rectangle())
        .foregroundStyle(entry.unavailableReason == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .help(entry.unavailableReason ?? entry.info.displayName)
        .onTapGesture {
            guard entry.unavailableReason == nil, inserting == nil else { return }
            insert(entry)
        }
    }

    private var footer: some View {
        HStack {
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text("Greyed entries cannot be hosted on this Mac — hover for the reason.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    /// Enumeration opens every bundle in the plug-in folder, which takes the
    /// better part of a second on a machine with many plug-ins, and the
    /// architecture probe reads each one's Mach-O header. Both belong off the
    /// main thread.
    private func load() async {
        guard loading else { return }
        let found: [Entry] = await Task.detached(priority: .userInitiated) {
            AUCatalog.effects().map {
                Entry(info: $0, unavailableReason: AUAvailability.reason(for: $0))
            }
        }.value
        entries = found
        loading = false
    }

    private func insert(_ entry: Entry) {
        inserting = entry.id
        failure = nil
        Task { @MainActor in
            defer { inserting = nil }
            do {
                _ = try await engine.addEffect(entry.info, toLane: laneID)
                dismiss()
            } catch {
                failure = String(describing: error)
            }
        }
    }
}
