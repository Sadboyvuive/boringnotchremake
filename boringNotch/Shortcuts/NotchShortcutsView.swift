//
//  NotchShortcutsView.swift
//  boringNotch
//

import AppKit
import Combine
import Defaults
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Models

enum SystemShortcutAction: String, Codable, CaseIterable, Identifiable, Hashable, Defaults.Serializable {
    case screenshot = "screenshot"
    case screenRecord = "screenRecord"
    case colorPicker = "colorPicker"
    case toggleDarkMode = "toggleDarkMode"
    case lockScreen = "lockScreen"
    case sleepDisplay = "sleepDisplay"
    case airDrop = "airDrop"
    case emptyTrash = "emptyTrash"
    case openShortcutsApp = "openShortcutsApp"

    var id: String { rawValue }

    var defaultTitle: String {
        switch self {
        case .screenshot: return "Screenshot"
        case .screenRecord: return "Screen Record"
        case .colorPicker: return "Color Picker"
        case .toggleDarkMode: return "Dark Mode"
        case .lockScreen: return "Lock Screen"
        case .sleepDisplay: return "Sleep Display"
        case .airDrop: return "AirDrop"
        case .emptyTrash: return "Empty Trash"
        case .openShortcutsApp: return "Shortcuts App"
        }
    }

    var defaultIcon: String {
        switch self {
        case .screenshot: return "camera.viewfinder"
        case .screenRecord: return "record.circle"
        case .colorPicker: return "eyedropper.halffull"
        case .toggleDarkMode: return "moon.stars.fill"
        case .lockScreen: return "lock.fill"
        case .sleepDisplay: return "moon.zzz.fill"
        case .airDrop: return "airplayaudio"
        case .emptyTrash: return "trash.fill"
        case .openShortcutsApp: return "bolt.square.fill"
        }
    }

    var defaultTintHex: String {
        switch self {
        case .screenshot: return "#0A84FF"
        case .screenRecord: return "#FF453A"
        case .colorPicker: return "#BF5AF2"
        case .toggleDarkMode: return "#5E5CE6"
        case .lockScreen: return "#FF9F0A"
        case .sleepDisplay: return "#64D2FF"
        case .airDrop: return "#30D158"
        case .emptyTrash: return "#8E8E93"
        case .openShortcutsApp: return "#FF375F"
        }
    }
}

enum NotchShortcutKind: Codable, Hashable, Defaults.Serializable {
    case systemAction(SystemShortcutAction)
    case appleShortcut(name: String)
    case openApp(bundleIdentifier: String, appPath: String)
    case openURL(urlString: String)
}

struct NotchShortcutItem: Codable, Identifiable, Hashable, Defaults.Serializable {
    var id: UUID = UUID()
    var title: String
    var subtitle: String
    var icon: String
    var tintHex: String
    var kind: NotchShortcutKind

    static let defaultItems: [NotchShortcutItem] = [
        NotchShortcutItem(
            title: "Screenshot",
            subtitle: "Copy selection",
            icon: "camera.viewfinder",
            tintHex: "#0A84FF",
            kind: .systemAction(.screenshot)
        ),
        NotchShortcutItem(
            title: "Color Picker",
            subtitle: "Copy HEX color",
            icon: "eyedropper.halffull",
            tintHex: "#BF5AF2",
            kind: .systemAction(.colorPicker)
        ),
        NotchShortcutItem(
            title: "Dark Mode",
            subtitle: "Toggle theme",
            icon: "moon.stars.fill",
            tintHex: "#5E5CE6",
            kind: .systemAction(.toggleDarkMode)
        ),
        NotchShortcutItem(
            title: "Screen Record",
            subtitle: "Capture video",
            icon: "record.circle",
            tintHex: "#FF453A",
            kind: .systemAction(.screenRecord)
        ),
        NotchShortcutItem(
            title: "AirDrop",
            subtitle: "Quick share",
            icon: "airplayaudio",
            tintHex: "#30D158",
            kind: .systemAction(.airDrop)
        ),
        NotchShortcutItem(
            title: "Lock Screen",
            subtitle: "Screen saver",
            icon: "lock.fill",
            tintHex: "#FF9F0A",
            kind: .systemAction(.lockScreen)
        ),
        NotchShortcutItem(
            title: "Sleep Display",
            subtitle: "Turn off screen",
            icon: "moon.zzz.fill",
            tintHex: "#64D2FF",
            kind: .systemAction(.sleepDisplay)
        ),
        NotchShortcutItem(
            title: "Shortcuts App",
            subtitle: "Open macOS app",
            icon: "bolt.fill",
            tintHex: "#FF375F",
            kind: .systemAction(.openShortcutsApp)
        )
    ]

    var tintColor: Color {
        Color(nsColor: NSColor(hexString: tintHex) ?? .controlAccentColor)
    }
}

private extension NSColor {
    convenience init?(hexString: String) {
        var cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleaned.hasPrefix("#") {
            cleaned.removeFirst()
        }
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else { return nil }
        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}

// MARK: - ShortcutManager

@MainActor
final class ShortcutManager: ObservableObject {
    static let shared = ShortcutManager()

    @Published private(set) var availableAppleShortcuts: [String] = []
    @Published private(set) var isLoadingShortcuts: Bool = false
    @Published private(set) var runningItemID: UUID?
    @Published private(set) var runningShortcutName: String?
    @Published var statusBanner: String?

    private var bannerClearTask: Task<Void, Never>?

    private init() {
        refreshAppleShortcuts()
    }

    func showBanner(_ message: String, duration: TimeInterval = 2.4) {
        bannerClearTask?.cancel()
        withAnimation(.smooth(duration: 0.2)) {
            statusBanner = message
        }
        bannerClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.2)) {
                self.statusBanner = nil
            }
        }
    }

    func refreshAppleShortcuts() {
        guard !isLoadingShortcuts else { return }
        isLoadingShortcuts = true

        Task.detached(priority: .userInitiated) {
            var names = Self.fetchShortcutsViaCLI()
            if names.isEmpty {
                names = await Self.fetchShortcutsViaAppleScript()
            }
            let sorted = Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            await MainActor.run {
                self.availableAppleShortcuts = sorted
                self.isLoadingShortcuts = false
            }
        }
    }

    nonisolated private static func fetchShortcutsViaCLI() -> [String] {
        let process = Process()
        let exeURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        guard FileManager.default.isExecutableFile(atPath: exeURL.path) else { return [] }
        process.executableURL = exeURL
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            return output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } catch {
            return []
        }
    }

    nonisolated private static func fetchShortcutsViaAppleScript() async -> [String] {
        let script = """
        tell application "Shortcuts Events"
            get name of every shortcut
        end tell
        """
        guard let descriptor = try? await AppleScriptHelper.execute(script) else { return [] }
        guard descriptor.numberOfItems > 0 else { return [] }
        var result: [String] = []
        for idx in 1...descriptor.numberOfItems {
            if let item = descriptor.atIndex(idx)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !item.isEmpty {
                result.append(item)
            }
        }
        return result
    }

    func isAppleShortcutPinned(_ name: String) -> Bool {
        Defaults[.notchShortcutItems].contains { item in
            if case .appleShortcut(let pinnedName) = item.kind {
                return pinnedName == name
            }
            return false
        }
    }

    func togglePinAppleShortcut(_ name: String) {
        var items = Defaults[.notchShortcutItems]
        if let idx = items.firstIndex(where: {
            if case .appleShortcut(let pinnedName) = $0.kind {
                return pinnedName == name
            }
            return false
        }) {
            items.remove(at: idx)
            Defaults[.notchShortcutItems] = items
            showBanner("Unpinned \"\(name)\"")
        } else {
            let palette = ["#FF375F", "#0A84FF", "#30D158", "#BF5AF2", "#FF9F0A", "#5E5CE6", "#64D2FF"]
            let colorHex = palette[abs(name.hashValue) % palette.count]
            let newItem = NotchShortcutItem(
                title: name,
                subtitle: "Mac Shortcut",
                icon: "bolt.fill",
                tintHex: colorHex,
                kind: .appleShortcut(name: name)
            )
            items.append(newItem)
            Defaults[.notchShortcutItems] = items
            showBanner("Pinned \"\(name)\"")
        }
    }

    func removeShortcutItem(_ item: NotchShortcutItem) {
        var items = Defaults[.notchShortcutItems]
        items.removeAll { $0.id == item.id }
        Defaults[.notchShortcutItems] = items
    }

    func resetToDefaultShortcuts() {
        Defaults[.notchShortcutItems] = NotchShortcutItem.defaultItems
        showBanner("Reset shortcuts to defaults")
    }

    func run(_ item: NotchShortcutItem, viewModel: BoringViewModel? = nil) {
        runningItemID = item.id

        switch item.kind {
        case .appleShortcut(let name):
            runAppleShortcut(named: name, itemID: item.id, viewModel: viewModel)

        case .systemAction(let action):
            runSystemAction(action, itemID: item.id, viewModel: viewModel)

        case .openApp(let bundleID, let appPath):
            Task { @MainActor in
                if Defaults[.closeNotchOnShortcutRun] {
                    viewModel?.close()
                }
                if !appPath.isEmpty, FileManager.default.fileExists(atPath: appPath) {
                    NSWorkspace.shared.openApplication(
                        at: URL(fileURLWithPath: appPath),
                        configuration: NSWorkspace.OpenConfiguration()
                    )
                } else if !bundleID.isEmpty,
                          let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    NSWorkspace.shared.openApplication(
                        at: appURL,
                        configuration: NSWorkspace.OpenConfiguration()
                    )
                }
                self.runningItemID = nil
                self.showBanner("Opened \(item.title)")
            }

        case .openURL(let urlString):
            Task { @MainActor in
                if Defaults[.closeNotchOnShortcutRun] {
                    viewModel?.close()
                }
                if let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                    self.showBanner("Opened \(item.title)")
                }
                self.runningItemID = nil
            }
        }
    }

    func runAppleShortcut(named name: String, itemID: UUID? = nil, viewModel: BoringViewModel? = nil) {
        runningShortcutName = name
        if let itemID {
            runningItemID = itemID
        }
        showBanner("Running \"\(name)\"…")

        Task.detached(priority: .userInitiated) {
            let ranCLI = Self.executeShortcutViaCLI(named: name)
            if !ranCLI {
                await MainActor.run {
                    var allowed = CharacterSet.urlQueryAllowed
                    allowed.remove(charactersIn: "&+=?")
                    if let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed),
                       let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            await MainActor.run {
                self.runningItemID = nil
                self.runningShortcutName = nil
                self.showBanner("Finished \"\(name)\"")
                if Defaults[.closeNotchOnShortcutRun] {
                    viewModel?.close()
                }
            }
        }
    }

    nonisolated private static func executeShortcutViaCLI(named name: String) -> Bool {
        let exeURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        guard FileManager.default.isExecutableFile(atPath: exeURL.path) else { return false }
        let process = Process()
        process.executableURL = exeURL
        process.arguments = ["run", name]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func runSystemAction(_ action: SystemShortcutAction, itemID: UUID, viewModel: BoringViewModel?) {
        switch action {
        case .screenshot:
            viewModel?.close()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                Task.detached {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    proc.arguments = ["-i", "-c"]
                    try? proc.run()
                    proc.waitUntilExit()
                    await MainActor.run {
                        self.runningItemID = nil
                        self.showBanner("Screenshot copied to clipboard")
                    }
                }
            }

        case .screenRecord:
            viewModel?.close()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                let screenshotAppURL = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
                NSWorkspace.shared.openApplication(
                    at: screenshotAppURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
                self.runningItemID = nil
                self.showBanner("Opened Screen Recorder")
            }

        case .colorPicker:
            viewModel?.close()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                let sampler = NSColorSampler()
                sampler.show { selectedColor in
                    Task { @MainActor in
                        self.runningItemID = nil
                        guard let rgb = selectedColor?.usingColorSpace(.sRGB) else { return }
                        let r = Int(round(rgb.redComponent * 255))
                        let g = Int(round(rgb.greenComponent * 255))
                        let b = Int(round(rgb.blueComponent * 255))
                        let hex = String(format: "#%02X%02X%02X", r, g, b)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(hex, forType: .string)
                        viewModel?.open()
                        BoringViewCoordinator.shared.currentView = .shortcuts
                        self.showBanner("Copied \(hex) to clipboard")
                    }
                }
            }

        case .toggleDarkMode:
            Task { @MainActor in
                let script = """
                tell application "System Events"
                    tell appearance preferences
                        set dark mode to not dark mode
                    end tell
                end tell
                """
                _ = try? await AppleScriptHelper.executeVoid(script)
                self.runningItemID = nil
                self.showBanner("Toggled appearance mode")
            }

        case .lockScreen:
            viewModel?.close()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                let saverURL = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
                NSWorkspace.shared.openApplication(
                    at: saverURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
                self.runningItemID = nil
            }

        case .sleepDisplay:
            viewModel?.close()
            Task.detached {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                proc.arguments = ["displaysleepnow"]
                try? proc.run()
                proc.waitUntilExit()
                await MainActor.run {
                    self.runningItemID = nil
                }
            }

        case .airDrop:
            if Defaults[.closeNotchOnShortcutRun] {
                viewModel?.close()
            }
            if let airDropURL = URL(string: "nwnode://domain-AirDrop") {
                NSWorkspace.shared.open(airDropURL)
            }
            runningItemID = nil
            showBanner("Opened AirDrop")

        case .emptyTrash:
            Task { @MainActor in
                let script = """
                tell application "Finder"
                    if (count of items in trash) > 0 then
                        empty trash
                    end if
                end tell
                """
                _ = try? await AppleScriptHelper.executeVoid(script)
                self.runningItemID = nil
                self.showBanner("Emptied Trash")
            }

        case .openShortcutsApp:
            if Defaults[.closeNotchOnShortcutRun] {
                viewModel?.close()
            }
            let url = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            runningItemID = nil
        }
    }
}

// MARK: - NotchShortcutsView (Open Notch View)

struct NotchShortcutsView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var shortcutManager = ShortcutManager.shared
    @Default(.notchShortcutItems) var pinnedItems

    enum TabFilter: String, CaseIterable {
        case pinned = "Quick Actions"
        case macShortcuts = "Mac Shortcuts"
        case add = "Add New"
    }

    @State private var selectedFilter: TabFilter = .pinned
    @State private var searchText: String = ""
    @State private var newCustomShortcutName: String = ""
    @State private var selectedSystemAction: SystemShortcutAction = .screenshot

    var body: some View {
        HStack(spacing: 12) {
            sidebarColumn
            mainPanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 4)
        .onAppear {
            if shortcutManager.availableAppleShortcuts.isEmpty {
                shortcutManager.refreshAppleShortcuts()
            }
        }
    }

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            sidebarButton(title: "Quick Actions", icon: "bolt.fill", filter: .pinned, badgeCount: pinnedItems.count)
            sidebarButton(
                title: "Mac Shortcuts",
                icon: "square.stack.3d.up.fill",
                filter: .macShortcuts,
                badgeCount: shortcutManager.availableAppleShortcuts.count
            )
            sidebarButton(title: "Add Shortcut", icon: "plus.circle.fill", filter: .add, badgeCount: nil)

            Spacer(minLength: 2)

            if let banner = shortcutManager.statusBanner {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 10))
                    Text(banner)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .transition(.opacity)
            } else {
                Button {
                    let url = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Open Shortcuts.app")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.gray)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 145)
    }

    private func sidebarButton(title: String, icon: String, filter: TabFilter, badgeCount: Int?) -> some View {
        let isSelected = selectedFilter == filter
        return Button {
            withAnimation(.smooth(duration: 0.2)) {
                selectedFilter = filter
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .gray)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .white : .gray)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let badgeCount, badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? .white : .gray)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.white.opacity(isSelected ? 0.22 : 0.08)))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var mainPanel: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .overlay {
                switch selectedFilter {
                case .pinned:
                    pinnedGridView
                case .macShortcuts:
                    macShortcutsListView
                case .add:
                    quickAddPanel
                }
            }
    }

    private var pinnedGridView: some View {
        Group {
            if pinnedItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bolt.slash.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.gray)
                    Text("No pinned shortcuts")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.gray)
                    Button("Restore Defaults") {
                        shortcutManager.resetToDefaultShortcuts()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(
                        rows: [
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8)
                        ],
                        spacing: 8
                    ) {
                        ForEach(pinnedItems) { item in
                            ShortcutTileCard(
                                item: item,
                                isRunning: shortcutManager.runningItemID == item.id,
                                onRun: {
                                    shortcutManager.run(item, viewModel: vm)
                                },
                                onRemove: {
                                    shortcutManager.removeShortcutItem(item)
                                }
                            )
                        }
                    }
                    .padding(10)
                }
            }
        }
    }

    private var macShortcutsListView: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                    TextField("Search Mac Shortcuts…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))

                Button {
                    shortcutManager.refreshAppleShortcuts()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(5)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("Reload shortcuts from macOS Shortcuts.app")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            let filtered = shortcutManager.availableAppleShortcuts.filter {
                searchText.isEmpty || $0.localizedCaseInsensitiveContains(searchText)
            }

            if shortcutManager.isLoadingShortcuts {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Text("Loading Shortcuts…")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
                Spacer()
            } else if filtered.isEmpty {
                Spacer()
                VStack(spacing: 4) {
                    Text(shortcutManager.availableAppleShortcuts.isEmpty
                         ? "No Apple Shortcuts found"
                         : "No matching shortcuts")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.gray)
                    Text("You can also type any Shortcut name in 'Add Shortcut'.")
                        .font(.system(size: 10))
                        .foregroundStyle(.gray.opacity(0.8))
                }
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(
                        rows: [
                            GridItem(.flexible(), spacing: 6),
                            GridItem(.flexible(), spacing: 6)
                        ],
                        spacing: 8
                    ) {
                        ForEach(filtered, id: \.self) { name in
                            MacShortcutRowChip(
                                name: name,
                                isPinned: shortcutManager.isAppleShortcutPinned(name),
                                isRunning: shortcutManager.runningShortcutName == name,
                                onRun: {
                                    shortcutManager.runAppleShortcut(named: name, viewModel: vm)
                                },
                                onTogglePin: {
                                    shortcutManager.togglePinAppleShortcut(name)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var quickAddPanel: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pin Apple Shortcut by Name")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    TextField("Shortcut name in Shortcuts.app", text: $newCustomShortcutName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                    Button("Pin") {
                        let trimmed = newCustomShortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        if !shortcutManager.isAppleShortcutPinned(trimmed) {
                            shortcutManager.togglePinAppleShortcut(trimmed)
                        }
                        newCustomShortcutName = ""
                        selectedFilter = .pinned
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newCustomShortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Divider().overlay(Color.white.opacity(0.1))

                HStack(spacing: 8) {
                    Button {
                        pickApplicationToAdd()
                    } label: {
                        Label("Pin Application…", systemImage: "app.badge.plus")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        shortcutManager.resetToDefaultShortcuts()
                        selectedFilter = .pinned
                    } label: {
                        Label("Reset Defaults", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(12)
            Spacer(minLength: 0)
        }
    }

    private func pickApplicationToAdd() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application to Pin to Notch"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        SharingStateManager.shared.preventNotchClose = true
        panel.begin { response in
            Task { @MainActor in
                SharingStateManager.shared.preventNotchClose = false
                guard response == .OK, let url = panel.url else { return }
                let appName = url.deletingPathExtension().lastPathComponent
                let bundleID = Bundle(url: url)?.bundleIdentifier ?? ""
                let newItem = NotchShortcutItem(
                    title: appName,
                    subtitle: "Launch App",
                    icon: "app.fill",
                    tintHex: "#0A84FF",
                    kind: .openApp(bundleIdentifier: bundleID, appPath: url.path)
                )
                var items = Defaults[.notchShortcutItems]
                items.append(newItem)
                Defaults[.notchShortcutItems] = items
                shortcutManager.showBanner("Pinned \(appName)")
                selectedFilter = .pinned
            }
        }
    }
}

private struct ShortcutTileCard: View {
    let item: NotchShortcutItem
    let isRunning: Bool
    let onRun: () -> Void
    let onRemove: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onRun) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(item.tintColor.opacity(isHovered ? 0.95 : 0.8))
                        .frame(width: 28, height: 28)

                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                    } else if case .openApp(let bundleID, let appPath) = item.kind,
                              let iconImage = resolveAppIcon(bundleID: bundleID, path: appPath) {
                        Image(nsImage: iconImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: item.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(width: 138, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.14 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(item.tintColor.opacity(isHovered ? 0.55 : 0.15), lineWidth: 1)
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button("Run \"\(item.title)\"") {
                onRun()
            }
            Divider()
            Button("Remove from Notch", role: .destructive) {
                onRemove()
            }
        }
    }

    private func resolveAppIcon(bundleID: String, path: String) -> NSImage? {
        if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        if !bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}

private struct MacShortcutRowChip: View {
    let name: String
    let isPinned: Bool
    let isRunning: Bool
    let onRun: () -> Void
    let onTogglePin: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onRun) {
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(Color.pink.opacity(0.85))
                            .frame(width: 22, height: 22)
                        if isRunning {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.white)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            Button(action: onTogglePin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isPinned ? .yellow : .gray)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help(isPinned ? "Unpin from Notch" : "Pin to Notch")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 165, height: 34)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.13 : 0.07))
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Settings Section for Notch Shortcuts

struct NotchShortcutsSettingsSection: View {
    @ObservedObject var shortcutManager = ShortcutManager.shared
    @Default(.boringShortcuts) var boringShortcuts
    @Default(.closeNotchOnShortcutRun) var closeNotchOnShortcutRun
    @Default(.notchShortcutItems) var pinnedItems
    @State private var customShortcutName: String = ""
    @State private var selectedSystemAction: SystemShortcutAction = .screenshot

    var body: some View {
        Section {
            Defaults.Toggle(key: .boringShortcuts) {
                Text("Show Shortcuts tab in notch")
            }
            Defaults.Toggle(key: .closeNotchOnShortcutRun) {
                Text("Auto-close notch after running a shortcut")
            }
            .disabled(!boringShortcuts)

            HStack {
                TextField("Apple Shortcut name…", text: $customShortcutName)
                    .textFieldStyle(.roundedBorder)
                Button("Pin Apple Shortcut") {
                    let trimmed = customShortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    if !shortcutManager.isAppleShortcutPinned(trimmed) {
                        shortcutManager.togglePinAppleShortcut(trimmed)
                    }
                    customShortcutName = ""
                }
                .disabled(customShortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack {
                Picker("Add System Action", selection: $selectedSystemAction) {
                    ForEach(SystemShortcutAction.allCases) { action in
                        Text(action.defaultTitle).tag(action)
                    }
                }
                Button("Add Action") {
                    let item = NotchShortcutItem(
                        title: selectedSystemAction.defaultTitle,
                        subtitle: "System Action",
                        icon: selectedSystemAction.defaultIcon,
                        tintHex: selectedSystemAction.defaultTintHex,
                        kind: .systemAction(selectedSystemAction)
                    )
                    pinnedItems.append(item)
                }
                Button("Reset Defaults") {
                    shortcutManager.resetToDefaultShortcuts()
                }
            }
        } header: {
            Text("Notch Shortcuts Bar")
        } footer: {
            Text("Access pinned Quick Actions and macOS Shortcuts directly from the Shortcuts tab inside the notch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
