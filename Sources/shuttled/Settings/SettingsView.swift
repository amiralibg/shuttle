import AppKit
import Combine
import ShuttleCore
import SwiftUI
import WeftPlatform

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"
    case layout = "Layout"
    case shortcuts = "Shortcuts"
    case displays = "Displays"
    case apps = "Apps"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .layout: "rectangle.split.3x1"
        case .shortcuts: "keyboard"
        case .displays: "display.2"
        case .apps: "app.badge.checkmark"
        }
    }
}

struct SettingsRootView: View {
    @Bindable var model: SettingsModel
    @State private var pane: SettingsPane?

    init(model: SettingsModel, pane: SettingsPane = .layout) {
        self.model = model
        _pane = State(initialValue: pane)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label(pane.rawValue, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            Group {
                switch pane ?? .layout {
                case .general: GeneralPane(model: model)
                case .layout: LayoutPane(model: model)
                case .shortcuts: ShortcutsPane(model: model)
                case .displays: DisplaysPane(model: model)
                case .apps: AppsPane(model: model)
                }
            }
            .navigationTitle((pane ?? .layout).rawValue)
        }
        .onChange(of: model.config) { model.configDidChange() }
        .frame(minWidth: 720, minHeight: 520)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Open Shuttle at login", isOn: $model.launchesAtLogin)
                if let error = model.loginItemError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                LabeledContent("Accessibility") {
                    if model.accessibilityGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open Privacy Settings…") { model.openAccessibilitySettings() }
                    }
                }
            }

            Section {
                Toggle("Show desktop number", isOn: $model.config.menuBarShowsSpace)
                Toggle("Show column position", isOn: $model.config.menuBarShowsColumns)
                LabeledContent("Preview") {
                    MenuBarPreview(
                        showSpace: model.config.menuBarShowsSpace,
                        showColumns: model.config.menuBarShowsColumns,
                        status: model.status
                    )
                }
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Each block is a column on this desktop's ribbon; the solid one has focus.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Configuration File") {
                LabeledContent("Location") {
                    Text(model.configPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Open in Editor") { model.openConfigInEditor() }
                    Button("Show in Finder") { model.revealConfigInFinder() }
                    Spacer()
                    Button("Reload") { model.runCommand?("reload") }
                }
                if let error = model.saveError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                if model.warnings.isEmpty {
                    Label("No problems found", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    ForEach(model.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Text("Changes made here are saved straight away. Edits made by hand are picked up as soon as the file is saved, but saving from here rewrites the file and drops its comments.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shuttle").font(.title3.weight(.semibold))
                        Text(ShuttleVersion.full).font(.callout).foregroundStyle(.secondary)
                        Text("A scrolling window manager for macOS").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MenuBarPreview: View {
    let showSpace: Bool
    let showColumns: Bool
    let status: StatusSnapshot?

    var body: some View {
        let columns = status?.columns ?? 4
        let focused = status?.focusedColumnIndex ?? 1
        HStack(spacing: 4) {
            if showColumns {
                Image(nsImage: MenuBarController.ribbonImage(columns: columns, focused: focused))
            } else {
                Image(systemName: "rectangle.split.3x1")
            }
            if showSpace {
                Text("\(status?.spaceIndex ?? 2)").font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
    }
}

// MARK: - Layout

private struct LayoutPane: View {
    @Bindable var model: SettingsModel

    private static let widthPresets: [(String, Double)] = [("⅓", 0.333), ("½", 0.5), ("⅔", 0.666), ("Full", 1.0)]

    var body: some View {
        Form {
            Section {
                RibbonPreview(
                    gap: model.config.gap,
                    columnWidth: model.config.defaultColumnWidth,
                    centerMode: model.config.centerFocusedColumn,
                    omega: model.config.springOmega
                )
                .frame(height: 230)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text("A live preview: focus steps along the ribbon with your gap, column width, scrolling and animation settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Spacing") {
                LabeledContent("Gap between windows") {
                    HStack {
                        Slider(value: rounded(\.gap, to: 1), in: ShuttleConfig.gapRange)
                        Text("\(Int(model.config.gap)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section {
                Picker("Width", selection: presetBinding) {
                    ForEach(Self.widthPresets, id: \.1) { label, value in
                        Text(label).tag(Optional(value))
                    }
                    if presetBinding.wrappedValue == nil {
                        Text("Custom").tag(Double?.none)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("Exact width") {
                    HStack {
                        Slider(value: rounded(\.defaultColumnWidth, to: 0.01), in: ShuttleConfig.columnWidthRange)
                        Text("\(Int((model.config.defaultColumnWidth * 100).rounded()))%")
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            } header: {
                Text("New Columns")
            } footer: {
                Text("How wide a newly opened window's column starts, as a share of the screen. ⌥R cycles a column through ⅓, ½, ⅔ and full.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $model.config.fillSingleColumn) {
                    Text("Fill the screen when a desktop has one column")
                    Text("A second window brings back every column's own width.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Single Window")
            } footer: {
                Text("A desktop's only column is always centered, whichever scrolling option is chosen below.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Scrolling") {
                Picker("When focus moves", selection: $model.config.centerFocusedColumn) {
                    VStack(alignment: .leading) {
                        Text("Center the focused column")
                        Text("The ribbon always moves so focus sits in the middle.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(CenterMode.always)
                    VStack(alignment: .leading) {
                        Text("Scroll only when needed")
                        Text("The ribbon moves just enough to show the column. niri's default.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(CenterMode.never)
                }
                .pickerStyle(.radioGroup)
            }

            Section("Animation") {
                LabeledContent("Spring") {
                    VStack(spacing: 2) {
                        Slider(value: rounded(\.springOmega, to: 1), in: ShuttleConfig.springOmegaRange)
                        HStack {
                            Text("Relaxed")
                            Spacer()
                            Text("Snappy")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// A slider binding that writes whole steps. `Slider(step:)` draws a tick
    /// per step and nudges the value on appear, which reads as an edit and
    /// rewrote the file with nothing changed.
    private func rounded(_ key: WritableKeyPath<ShuttleConfig, Double>, to step: Double) -> Binding<Double> {
        Binding(
            get: { model.config[keyPath: key] },
            set: { value in
                let snapped = (value / step).rounded() * step
                if abs(snapped - model.config[keyPath: key]) > step / 2 { model.config[keyPath: key] = snapped }
            }
        )
    }

    /// The preset matching the current width, or nil for a custom width.
    private var presetBinding: Binding<Double?> {
        Binding(
            get: {
                Self.widthPresets.map(\.1).first { abs($0 - model.config.defaultColumnWidth) < 0.005 }
            },
            set: { value in
                if let value { model.config.defaultColumnWidth = value }
            }
        )
    }
}

/// A miniature screen with five columns. Focus steps right then back left
/// every 1.4 s, scrolled the way the daemon would scroll it, with a spring of
/// the same stiffness.
private struct RibbonPreview: View {
    let gap: Double
    let columnWidth: Double
    let centerMode: CenterMode
    let omega: Double

    @State private var focused = 1
    @State private var direction = 1
    @State private var offset: Double = 0
    private let columnCount = 5
    private let timer = Timer.publish(every: 1.4, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let screen = CGSize(width: min(geo.size.width - 40, geo.size.height * 1.6), height: min(geo.size.height, (geo.size.width - 40) / 1.6))
            let scale = screen.width / 1600.0
            let g = gap * scale
            let colW = (screen.width - 2 * g) * columnWidth
            let colH = screen.height - 2 * g

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                ForEach(0..<columnCount, id: \.self) { i in
                    let x = g + Double(i) * (colW + g) - offset
                    RoundedRectangle(cornerRadius: 4)
                        .fill(i == focused ? Color.accentColor : Color.secondary.opacity(0.35))
                        .overlay(alignment: .top) {
                            Capsule().fill(.white.opacity(0.6)).frame(width: max(colW * 0.3, 6), height: 3).padding(.top, 4)
                        }
                        .frame(width: max(colW, 4), height: colH)
                        .offset(x: x, y: g)
                }
            }
            .frame(width: screen.width, height: screen.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.5), lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { offset = target(for: focused, colW: colW, g: g, viewW: screen.width - 2 * g, from: 0) }
            .onReceive(timer) { _ in
                if focused + direction < 0 || focused + direction >= columnCount { direction.negate() }
                focused += direction
                let next = target(for: focused, colW: colW, g: g, viewW: screen.width - 2 * g, from: offset)
                withAnimation(.spring(response: 2 * .pi / omega * 1.6, dampingFraction: 1)) { offset = next }
            }
            .onChange(of: gap) { offset = target(for: focused, colW: colW, g: g, viewW: screen.width - 2 * g, from: offset) }
            .onChange(of: columnWidth) { offset = target(for: focused, colW: colW, g: g, viewW: screen.width - 2 * g, from: offset) }
        }
        .padding(.vertical, 16)
    }

    /// The same rule as `Strip.centerOffset` / `revealOffset`, in preview points.
    private func target(for index: Int, colW: Double, g: Double, viewW: Double, from current: Double) -> Double {
        let left = Double(index) * (colW + g)
        switch centerMode {
        case .always:
            return left + colW / 2 - viewW / 2
        case .never:
            if colW >= viewW { return left + colW / 2 - viewW / 2 }
            if left < current { return left }
            if left + colW > current + viewW { return left + colW - viewW }
            return current
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Drag the ribbon with", selection: $model.config.mouseModifier) {
                    Text("⌥ Option").tag("alt")
                    Text("⌘ Command").tag("cmd")
                    Text("⌃ Control").tag("ctrl")
                    Text("⇧ Shift").tag("shift")
                    Text("fn").tag("fn")
                }
            } header: {
                Text("Mouse")
            } footer: {
                Text("Hold the key and drag anywhere to slide the ribbon; flick to throw it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            let catalog = ShuttleAction.catalog(labels: model.config.spaceLabels)
            ForEach(ShuttleAction.Group.allCases, id: \.self) { group in
                // Desktops have a command per number and per name; only the
                // bound ones get a row, the rest are under "Add a Shortcut".
                let actions = catalog.filter { action in
                    action.group == group
                        && (group != .desktops || !model.chords(for: action.command).isEmpty
                            || ["space focus recent", "space focus next", "space focus prev"].contains(action.command))
                } + (group == .other ? model.customCommands.map { ShuttleAction.named($0, labels: model.config.spaceLabels) } : [])
                Section(group.rawValue) {
                    ForEach(actions) { action in
                        ShortcutRow(model: model, action: action)
                    }
                }
            }

            AddShortcutSection(model: model, catalog: catalog)

            ForEach(model.config.modes.keys.sorted(), id: \.self) { mode in
                let binds = model.config.modes[mode] ?? [:]
                Section {
                    ForEach(binds.keys.sorted(), id: \.self) { chord in
                        LabeledContent(ShuttleAction.named(binds[chord]!, labels: model.config.spaceLabels).title) {
                            Text(ChordFormat.display(chord))
                                .font(.system(.callout, design: .rounded).weight(.medium))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                        }
                    }
                } header: {
                    Text("\(mode.capitalized) Mode")
                } footer: {
                    let entry = model.config.keybindings.first { $0.value == "mode \(mode)" }?.key
                    Text("Entered with \(entry.map(ChordFormat.display) ?? "a “mode \(mode)” binding"); the menu bar shows \(mode.uppercased()) while it is on. Edit these keys under [mode.\(mode)] in the config file.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Default Shortcuts", role: .destructive) { model.restoreDefaultShortcuts() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Binds any command, including desktops by number or name.
private struct AddShortcutSection: View {
    @Bindable var model: SettingsModel
    let catalog: [ShuttleAction]
    @State private var command = "space focus 1"

    var body: some View {
        Section {
            Picker("Command", selection: $command) {
                ForEach(ShuttleAction.Group.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(catalog.filter { $0.group == group }) { action in
                            Text(action.title).tag(action.command)
                        }
                    }
                }
            }
            ShortcutRow(model: model, action: ShuttleAction.named(command, labels: model.config.spaceLabels))
        } header: {
            Text("Add a Shortcut")
        } footer: {
            Text("Pick a command, then press + and type the keys.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ShortcutRow: View {
    @Bindable var model: SettingsModel
    let action: ShuttleAction
    @State private var monitor: Any?
    @State private var conflict: String?

    private var recording: Bool { model.recordingCommand == action.command }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                ForEach(model.chords(for: action.command), id: \.self) { chord in
                    KeyCap(chord: chord) { model.unbind(chord) }
                }
                if recording {
                    Text(conflict ?? "Type a shortcut…")
                        .font(.callout)
                        .foregroundStyle(conflict == nil ? Color.accentColor : .orange)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().strokeBorder(Color.accentColor, lineWidth: 1))
                    Button("Cancel") { stop() }.buttonStyle(.borderless)
                } else {
                    Button {
                        start()
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Add a shortcut")
                }
            }
        } label: {
            Text(action.title)
            if action.title == action.command {
                Text("Custom command").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { if recording { stop() } }
    }

    private func start() {
        if model.recordingCommand != nil { model.endRecording() }
        model.beginRecording(action.command)
        conflict = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard model.recordingCommand == action.command else { return event }
            if event.keyCode == 53 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                stop()
                return nil
            }
            guard let chord = ChordFormat.chord(from: event) else {
                conflict = "Add ⌥, ⌃, ⇧ or ⌘"
                return nil
            }
            // A chord bound elsewhere moves here; its old row loses it visibly.
            model.bind(chord, to: action.command)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        model.endRecording()
    }
}

private struct KeyCap: View {
    let chord: String
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Text(ChordFormat.display(chord))
                .font(.system(.callout, design: .rounded).weight(.medium))
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Remove \(ChordFormat.display(chord))")
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.3)))
        .onHover { hovering = $0 }
        .help(chord)
    }
}

// MARK: - Displays

private struct DisplaysPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        let monitors = model.status?.monitors ?? model.systemMonitors
        Form {
            Section {
                DisplayArrangement(monitors: monitors)
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text("Each display keeps its own desktops, and each desktop its own ribbon. ⌃⌥ + arrow or H/J/K/L focuses the display that way; add ⇧ to take the focused column with you.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if monitors.count > 1 && !(model.status?.separateSpaces ?? SystemChecks.displaysHaveSeparateSpaces()) {
                Section {
                    Label {
                        Text("“Displays have separate Spaces” is off, so every display switches desktops together. Turn it on in System Settings › Desktop & Dock and log out to give each display its own.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }

            ForEach(monitors, id: \.uuid) { m in
                Section {
                    if m.desktops.isEmpty {
                        Text("No desktops reported.").foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                            ForEach(m.desktops, id: \.spaceID) { desktop in
                                let shortcut = desktop.label.flatMap { model.chords(for: "space focus \($0)").first }
                                    ?? model.chords(for: "space focus \(desktop.index)").first
                                DesktopCard(desktop: desktop, monitor: m, shortcut: shortcut, live: model.status != nil) {
                                    model.focusDesktop?(m.uuid, desktop.index)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    HStack {
                        Text(m.name)
                        if m.isMain { Text("Main").font(.caption2).padding(.horizontal, 5).background(Capsule().fill(.quaternary)) }
                        if m.isFocused { Text("Focused").font(.caption2).foregroundStyle(Color.accentColor) }
                        Spacer()
                        Text("\(Int(m.bounds.width))×\(Int(m.bounds.height))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ForEach(model.config.spaceLabels.indices, id: \.self) { i in
                    HStack {
                        Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                        TextField("Name", text: $model.config.spaceLabels[i], prompt: Text("unnamed"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        Button {
                            model.config.spaceLabels.remove(at: i)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this name; later names move up one desktop")
                    }
                }
                Button("Add Name") { model.config.spaceLabels.append("") }
            } header: {
                Text("Desktop Names")
            } footer: {
                Text("Names go to desktops in order, counting the main display's first and then the others, as weft and yabai count them. A name works anywhere a number does: space focus web, [[rule]] space = \"web\".")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The displays as System Settings arranges them, scaled to fit, each showing
/// its desktop number and its ribbon.
private struct DisplayArrangement: View {
    let monitors: [StatusSnapshot.Monitor]

    var body: some View {
        GeometryReader { geo in
            let minX = monitors.map(\.bounds.x).min() ?? 0
            let minY = monitors.map(\.bounds.y).min() ?? 0
            let maxX = monitors.map { $0.bounds.x + $0.bounds.width }.max() ?? 1
            let maxY = monitors.map { $0.bounds.y + $0.bounds.height }.max() ?? 1
            let pad = 20.0
            let scale = min((geo.size.width - 2 * pad) / max(maxX - minX, 1), (geo.size.height - 2 * pad) / max(maxY - minY, 1))
            let used = CGSize(width: (maxX - minX) * scale, height: (maxY - minY) * scale)
            let origin = CGPoint(x: (geo.size.width - used.width) / 2, y: (geo.size.height - used.height) / 2)

            ZStack(alignment: .topLeading) {
                ForEach(monitors, id: \.uuid) { m in
                    let w = m.bounds.width * scale - 6, h = m.bounds.height * scale - 6
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(m.isFocused ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.14))
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(m.isFocused ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: m.isFocused ? 2 : 1)
                        VStack(spacing: 4) {
                            Text(m.name).font(.caption.weight(.semibold)).lineLimit(1)
                            Text(m.desktopIndex.map { "Desktop \($0)" } ?? "Fullscreen app")
                                .font(.caption2).foregroundStyle(.secondary)
                            if m.columns > 0 {
                                Image(nsImage: MenuBarController.ribbonImage(columns: m.columns, focused: m.focusedColumnIndex))
                                    .renderingMode(.template)
                                    .foregroundStyle(m.isFocused ? Color.accentColor : .secondary)
                            }
                        }
                        .padding(4)
                    }
                    .frame(width: max(w, 20), height: max(h, 20))
                    .offset(x: origin.x + (m.bounds.x - minX) * scale + 3, y: origin.y + (m.bounds.y - minY) * scale + 3)
                }
            }
        }
    }
}

private struct DesktopCard: View {
    let desktop: StatusSnapshot.Desktop
    let monitor: StatusSnapshot.Monitor
    let shortcut: String?
    let live: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(desktop.isCurrent ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                    if desktop.isCurrent && monitor.columns > 0 {
                        Image(nsImage: MenuBarController.ribbonImage(columns: monitor.columns, focused: monitor.focusedColumnIndex))
                            .renderingMode(.template)
                            .foregroundStyle(Color.accentColor)
                            .scaleEffect(1.5)
                    } else {
                        Image(systemName: "rectangle.split.3x1").foregroundStyle(.secondary)
                    }
                }
                .frame(height: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(desktop.isCurrent ? Color.accentColor : .clear, lineWidth: 2)
                )
                HStack {
                    Text(desktop.label.map { "\(desktop.index) · \($0)" } ?? "Desktop \(desktop.index)")
                        .font(.headline).lineLimit(1)
                    Spacer()
                    if let shortcut {
                        Text(ChordFormat.display(shortcut)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!live)
    }

    private var label: String {
        if desktop.isCurrent { return monitor.columns == 1 ? "Showing · 1 column" : "Showing · \(monitor.columns) columns" }
        guard let n = desktop.windows else { return live ? "Not visited yet" : "—" }
        return n == 1 ? "1 window" : "\(n) windows"
    }
}

// MARK: - Apps

private struct AppsPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Text("Rules apply to windows as they open: send an app to a desktop, or leave it floating. Patterns are regular expressions; ^Safari$ matches Safari exactly. Every matching rule counts, and the first one to set a property wins.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            ForEach(model.config.rules.indices, id: \.self) { i in
                RuleEditor(model: model, index: i)
            }

            Section {
                HStack {
                    Button("Add Rule") { model.config.rules.append(WindowRule(app: "")) }
                    Menu("Add Rule for a Running App") {
                        ForEach(model.runningAppNames, id: \.self) { name in
                            Button(name) {
                                let escaped = NSRegularExpression.escapedPattern(for: name)
                                model.config.rules.append(WindowRule(app: "^\(escaped)$"))
                            }
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct RuleEditor: View {
    @Bindable var model: SettingsModel
    let index: Int

    private func text(_ key: WritableKeyPath<WindowRule, String?>) -> Binding<String> {
        Binding(
            get: { model.config.rules.indices.contains(index) ? model.config.rules[index][keyPath: key] ?? "" : "" },
            set: { value in
                guard model.config.rules.indices.contains(index) else { return }
                model.config.rules[index][keyPath: key] = value.isEmpty ? nil : value
            }
        )
    }

    private var tiled: Binding<Bool> {
        Binding(
            get: { model.config.rules.indices.contains(index) ? model.config.rules[index].manage != false : true },
            set: { value in
                guard model.config.rules.indices.contains(index) else { return }
                model.config.rules[index].manage = value ? nil : false
            }
        )
    }

    private var space: Binding<String> {
        Binding(
            get: { model.config.rules.indices.contains(index) ? model.config.rules[index].space ?? "" : "" },
            set: { value in
                guard model.config.rules.indices.contains(index) else { return }
                model.config.rules[index].space = value.isEmpty ? nil : value
            }
        )
    }

    var body: some View {
        if model.config.rules.indices.contains(index) {
            let rule = model.config.rules[index]
            Section {
                patternField("App", key: \.app, pattern: rule.app)
                patternField("Window title", key: \.title, pattern: rule.title)
                Toggle("Tile this app's windows", isOn: tiled)
                Picker("Open on desktop", selection: space) {
                    Text("Wherever it opens").tag("")
                    ForEach(model.config.spaceLabels.filter { !$0.isEmpty }, id: \.self) { label in
                        Text(label).tag(label)
                    }
                    ForEach(1...9, id: \.self) { n in
                        Text("Desktop \(n)").tag("\(n)")
                    }
                    if let current = rule.space, !current.isEmpty,
                       !model.config.spaceLabels.contains(current), Int(current).map({ (1...9).contains($0) }) != true {
                        Text(current).tag(current)
                    }
                }
                .disabled(rule.manage == false && rule.space == nil)
            } header: {
                HStack {
                    Text(rule.app?.isEmpty == false ? rule.app! : "New Rule")
                    Spacer()
                    Button(role: .destructive) {
                        model.config.rules.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete this rule")
                }
            }
        }
    }

    private func patternField(_ title: String, key: WritableKeyPath<WindowRule, String?>, pattern: String?) -> some View {
        let invalid = pattern.map { !$0.isEmpty && (try? NSRegularExpression(pattern: $0)) == nil } ?? false
        return LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                TextField(title, text: text(key), prompt: Text(title == "App" ? "^Safari$" : "any"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: 320)
                if invalid {
                    Text("Not a valid pattern").font(.caption).foregroundStyle(.red)
                }
            }
        }
    }
}
