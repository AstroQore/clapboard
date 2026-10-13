import ClapboardCore
import SwiftUI

/// One strip's effect chain, as chips.
///
/// Each chip has a power button that bypasses the plug-in, a name that opens
/// its own editor, and a menu to reorder or remove it.
///
/// Laid out as a row in the row-based mixer and as a column in a console strip;
/// `axis` is the only difference, so the two never drift apart.
struct EffectChainView: View {
    /// Which chain is on screen.
    ///
    /// Every strip's chain is editable — `AudioEngine`'s chain API names an
    /// `EffectTarget`, and a lane and a bus are equally addressable. `.master`
    /// is only here because the row-based mixer still says "the master chain"
    /// rather than naming a bus; it resolves to `.bus(masterBusID)` like any
    /// other bus strip.
    enum Subject: Hashable {
        case lane(UUID)
        case master
        case bus(UUID)

        @MainActor
        func target(in engine: AudioEngine) -> EffectTarget {
            switch self {
            case .lane(let id): return .lane(id)
            case .master: return engine.masterEffectTarget
            case .bus(let id): return .bus(id)
            }
        }
    }

    let engine: AudioEngine
    let subject: Subject
    var axis: Axis = .horizontal

    @State private var showingPicker = false

    /// The pre-console spelling: a lane id, or `nil` for the master bus.
    init(engine: AudioEngine, laneID: UUID?, axis: Axis = .horizontal) {
        self.init(engine: engine, subject: laneID.map(Subject.lane) ?? .master, axis: axis)
    }

    init(engine: AudioEngine, subject: Subject, axis: Axis = .horizontal) {
        self.engine = engine
        self.subject = subject
        self.axis = axis
    }

    private var target: EffectTarget { subject.target(in: engine) }

    private var chain: [EffectConfig] { engine.effects(for: target) }

    var body: some View {
        Group {
            if axis == .horizontal {
                HStack(spacing: 6) { content }
            } else {
                VStack(alignment: .leading, spacing: 3) { content }
            }
        }
        .sheet(isPresented: $showingPicker) {
            EffectPickerSheet(engine: engine, target: target)
        }
    }

    @ViewBuilder
    private var content: some View {
        if axis == .horizontal {
            Image(systemName: "slider.horizontal.below.rectangle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help(Self.help)
        }

        ForEach(Array(chain.enumerated()), id: \.element.id) { index, effect in
            EffectChipView(
                engine: engine,
                effect: effect,
                index: index,
                count: chain.count,
                fillsWidth: axis == .vertical
            )
        }

        Button {
            showingPicker = true
        } label: {
            if axis == .vertical {
                Label("Effect", systemImage: "plus")
                    .font(.caption2)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Image(systemName: "plus")
                    .font(.caption2)
            }
        }
        .buttonStyle(.borderless)
        .help("Insert an Audio Unit")
        .disabled(chain.count >= RTLimits.maxEffectsPerChain)

        if engine.restoringEffects {
            ProgressView()
                .controlSize(.mini)
                .help("Loading the plug-ins this session saved")
        }

        if axis == .horizontal {
            Spacer(minLength: 0)
            if case .lane(let laneID) = subject {
                LanePDCReadout(engine: engine, laneID: laneID)
            }
        }
    }

    private static let help = "Effect chain — after the delay, before the fader"
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

/// One plug-in: a power button, its name, and its latency.
///
/// The power button is the bypass switch and nothing else is — the same shape
/// as an insert slot on a hardware console or in a DAW, where the on/off
/// control is a thing you can see and point at rather than a gesture you have
/// to know. The name opens the plug-in's own editor. The context menu repeats
/// both and adds reorder and remove; `⌫` removes.
private struct EffectChipView: View {
    let engine: AudioEngine
    let effect: EffectConfig
    let index: Int
    let count: Int
    /// Console strips are 120 pt wide, so a chip there fills the column rather
    /// than sizing to its name.
    var fillsWidth: Bool = false

    @State private var hovering = false

    private var shortName: String {
        let trimmed = effect.displayName.split(separator: ":").last.map(String.init)
            ?? effect.displayName
        return trimmed.trimmingCharacters(in: .whitespaces)
    }

    private var latency: Int { engine.effectLatencySamples(id: effect.id) }

    /// Running: available and not bypassed. Everything the chip's look says
    /// follows from this one bit.
    private var isActive: Bool { effect.isAvailable && !effect.bypass }

    var body: some View {
        HStack(spacing: 5) {
            powerButton
            nameButton
            if fillsWidth { Spacer(minLength: 0) }
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
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .background(background, in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                effect.isAvailable ? Color.clear : Color.orange.opacity(0.6))
        }
        .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .onHover { hovering = $0 }
        .contextMenu {
            Button(effect.bypass ? "Enable" : "Bypass") {
                engine.setEffectBypass(id: effect.id, !effect.bypass)
            }
            .disabled(!effect.isAvailable)
            Button("Open Editor") { engine.openEffectWindow(id: effect.id) }
                .disabled(!effect.isAvailable)
            Divider()
            Button("Move Earlier") { engine.moveEffect(id: effect.id, to: index - 1) }
                .disabled(index == 0)
            Button("Move Later") { engine.moveEffect(id: effect.id, to: index + 1) }
                .disabled(index >= count - 1)
            Divider()
            Button("Remove", role: .destructive) { engine.removeEffect(id: effect.id) }
        }
        .onDeleteCommand { engine.removeEffect(id: effect.id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(effect.displayName)
    }

    /// The bypass switch. Lit and filled while the plug-in runs, hollow and
    /// dim while it is bypassed; disabled, not hidden, for a plug-in that is
    /// not installed, so the chip keeps its shape.
    private var powerButton: some View {
        Button {
            engine.setEffectBypass(id: effect.id, !effect.bypass)
        } label: {
            Image(systemName: isActive ? "power.circle.fill" : "power.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .disabled(!effect.isAvailable)
        .help(powerHelp)
        .accessibilityLabel("Enabled")
        .accessibilityValue(effect.bypass ? "off" : "on")
    }

    private var nameButton: some View {
        Button {
            engine.openEffectWindow(id: effect.id)
        } label: {
            HStack(spacing: 4) {
                Text(shortName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .strikethrough(effect.bypass && effect.isAvailable, color: .secondary)
                if latency > 0, isActive {
                    Text("\(latency)sp")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!effect.isAvailable)
        .help(nameHelp)
    }

    private var background: AnyShapeStyle {
        isActive ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(.quaternary)
    }

    private var powerHelp: String {
        if let reason = effect.unavailableReason { return "\(effect.displayName) — \(reason)" }
        return effect.bypass
            ? "Bypassed — click to enable \(effect.displayName)"
            : "On — click to bypass \(effect.displayName)"
    }

    private var nameHelp: String {
        if let reason = effect.unavailableReason { return "\(effect.displayName) — \(reason)" }
        return "\(effect.displayName)\(effect.bypass ? " (bypassed)" : "")"
            + " · \(latency) samples latency · click to open its editor"
    }
}

// MARK: - Picker

/// The plug-in menu: search, grouped by manufacturer with Apple first.
struct EffectPickerSheet: View {
    let engine: AudioEngine
    /// The strip the chosen plug-in is appended to — a lane or any bus.
    let target: EffectTarget

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
        // The search field earns focus when the user types; nothing should be
        // ringed just because the sheet opened.
        .clapboardNoInitialFocus()
        .task { await load() }
    }

    /// Named after the strip rather than "lane"/"bus", so adding to `Drums`
    /// says `Drums` and the Master bus keeps the wording it always had.
    private var title: String {
        switch target {
        case .lane(let id):
            return "Add \(engine.lane(id: id)?.name ?? "Lane") Effect"
        case .bus(let id):
            return "Add \(engine.bus(id: id)?.name ?? "Bus") Effect"
        }
    }

    private var header: some View {
        HStack {
            Text(title)
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
                _ = try await engine.addEffect(entry.info, to: target)
                dismiss()
            } catch {
                failure = String(describing: error)
            }
        }
    }
}
