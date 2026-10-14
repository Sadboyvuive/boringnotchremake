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
    case ejectDisks = "ejectDisks"
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
        case .ejectDisks: return "Eject SSD"
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

    var defaultSubtitle: String {
        switch self {
        case .ejectDisks: return "Safely remove"
        case .screenshot: return "Copy area"
        case .screenRecord: return "Capture video"
        case .colorPicker: return "Copy HEX"
        case .toggleDarkMode: return "Switch theme"
        case .lockScreen: return "Screen saver"
        case .sleepDisplay: return "Turn off screen"
        case .airDrop: return "Quick share"
        case .emptyTrash: return "Clean Finder"
        case .openShortcutsApp: return "macOS Shortcuts"
        }
    }

    var defaultIcon: String {
        switch self {
        case .ejectDisks: return "eject.fill"
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
        "#FFFFFF"
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
            title: "Eject SSD",
            subtitle: "Safely remove",
            icon: "eject.fill",
            tintHex: "#FFFFFF",
            kind: .systemAction(.ejectDisks)
        ),
        NotchShortcutItem(
            title: "Screenshot",
            subtitle: "Copy area",
            icon: "camera.viewfinder",
            tintHex: "#FFFFFF",
            kind: .systemAction(.screenshot)
        )
    ]

    var tintColor: Color {
        Color.white
    }
}

// MARK: - ShortcutManager

@MainActor
final class ShortcutManager: ObservableObject {
    static let shared = ShortcutManager()

    @Published private(set) var availableAppleShortcuts: [String] = []
    @Published private(set) var isLoadingShortcuts: Bool = false
    @Published private(set) var runningSlotIndex: Int?
    @Published var statusBanner: String?

    private var bannerClearTask: Task<Void, Never>?

    private init() {
        ensureTwoSlots()
        refreshAppleShortcuts()
    }

    func ensureTwoSlots() {
        var items = Defaults[.notchShortcutItems]
        if items.isEmpty {
            items = NotchShortcutItem.defaultItems
            Defaults[.notchShortcutItems] = items
        } else if items.count == 1 {
            items.append(NotchShortcutItem.defaultItems[1])
            Defaults[.notchShortcutItems] = items
        }
    }

    func slotItem(at index: Int) -> NotchShortcutItem {
        ensureTwoSlots()
        let items = Defaults[.notchShortcutItems]
        if index >= 0 && index < items.count {
            return items[index]
        }
        return NotchShortcutItem.defaultItems[min(index, 1)]
    }

    func updateSlot(at index: Int, with item: NotchShortcutItem) {
        ensureTwoSlots()
        var items = Defaults[.notchShortcutItems]
        if index >= 0 && index < items.count {
            items[index] = item
        } else {
            items.append(item)
        }
        Defaults[.notchShortcutItems] = items
    }

    func setSlotToSystemAction(_ action: SystemShortcutAction, slotIndex: Int) {
        let item = NotchShortcutItem(
            title: action.defaultTitle,
            subtitle: action.defaultSubtitle,
            icon: action.defaultIcon,
            tintHex: "#FFFFFF",
            kind: .systemAction(action)
        )
        updateSlot(at: slotIndex, with: item)
    }

    func setSlotToAppleShortcut(_ name: String, slotIndex: Int) {
        let lower = name.lowercased()
        let icon = (lower.contains("eject") || lower.contains("ssd") || lower.contains("disk")) ? "eject.fill" : "bolt.fill"
        let item = NotchShortcutItem(
            title: name,
            subtitle: "Shortcut",
            icon: icon,
            tintHex: "#FFFFFF",
            kind: .appleShortcut(name: name)
        )
        updateSlot(at: slotIndex, with: item)
    }

    func pickAppForSlot(_ slotIndex: Int) {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application for Shortcut Button \(slotIndex + 1)"
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
                    subtitle: "Open App",
                    icon: "app.fill",
                    tintHex: "#FFFFFF",
                    kind: .openApp(bundleIdentifier: bundleID, appPath: url.path)
                )
                self.updateSlot(at: slotIndex, with: newItem)
            }
        }
    }

    func showBanner(_ message: String, duration: TimeInterval = 2.0) {
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

    func run(slotIndex: Int, viewModel: BoringViewModel? = nil) {
        let item = slotItem(at: slotIndex)
        runningSlotIndex = slotIndex

        switch item.kind {
        case .appleShortcut(let name):
            runAppleShortcut(named: name, slotIndex: slotIndex, viewModel: viewModel)

        case .systemAction(let action):
            runSystemAction(action, slotIndex: slotIndex, viewModel: viewModel)

        case .openApp(let bundleID, let appPath):
            if Defaults[.closeNotchOnShortcutRun] {
                viewModel?.close()
            }
            if !appPath.isEmpty, FileManager.default.fileExists(atPath: appPath) {
                NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
            } else if !bundleID.isEmpty,
                      let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.open(appURL)
            }
            runningSlotIndex = nil
            showBanner("Opened \(item.title)")

        case .openURL(let urlString):
            if Defaults[.closeNotchOnShortcutRun] {
                viewModel?.close()
            }
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
                showBanner("Opened \(item.title)")
            }
            runningSlotIndex = nil
        }
    }

    func runAppleShortcut(named name: String, slotIndex: Int? = nil, viewModel: BoringViewModel? = nil) {
        runningSlotIndex = slotIndex
        showBanner("Running \(name)…")

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
                self.runningSlotIndex = nil
                self.showBanner("Done!")
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

    private func runSystemAction(_ action: SystemShortcutAction, slotIndex: Int, viewModel: BoringViewModel?) {
        switch action {
        case .ejectDisks:
            Task { @MainActor in
                let script = """
                tell application "Finder"
                    eject (every disk whose ejectable is true)
                end tell
                """
                _ = try? await AppleScriptHelper.executeVoid(script)
                self.runningSlotIndex = nil
                self.showBanner("SSD / Disks Ejected")
            }

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
                        self.runningSlotIndex = nil
                    }
                }
            }

        case .screenRecord:
            viewModel?.close()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                let screenshotAppURL = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
                NSWorkspace.shared.open(screenshotAppURL)
                self.runningSlotIndex = nil
            }

        case .colorPicker:
            viewModel?.close()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                let selectedColor = await NSColorSampler().sample()
                self.runningSlotIndex = nil
                guard let rgb = selectedColor?.usingColorSpace(.sRGB) else { return }
                let r = Int(round(rgb.redComponent * 255))
                let g = Int(round(rgb.greenComponent * 255))
                let b = Int(round(rgb.blueComponent * 255))
                let hex = String(format: "#%02X%02X%02X", r, g, b)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hex, forType: .string)
                viewModel?.open()
                self.showBanner("Copied \(hex)")
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
                self.runningSlotIndex = nil
                self.showBanner("Switched theme")
            }

        case .lockScreen:
            viewModel?.close()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                let saverURL = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
                NSWorkspace.shared.open(saverURL)
                self.runningSlotIndex = nil
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
                    self.runningSlotIndex = nil
                }
            }

        case .airDrop:
            if Defaults[.closeNotchOnShortcutRun] {
                viewModel?.close()
            }
            if let airDropURL = URL(string: "nwnode://domain-AirDrop") {
                NSWorkspace.shared.open(airDropURL)
            }
            runningSlotIndex = nil

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
                self.runningSlotIndex = nil
                self.showBanner("Trash emptied")
            }

        case .openShortcutsApp:
            if Defaults[.closeNotchOnShortcutRun] {
                viewModel?.close()
            }
            let url = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")
            NSWorkspace.shared.open(url)
            runningSlotIndex = nil
        }
    }
}

// MARK: - HomeQuickShortcutsView (Rendered in the 'No events today' area)

struct HomeQuickShortcutsView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var shortcutManager = ShortcutManager.shared
    @Default(.homeShortcutCount) var homeShortcutCount
    @Default(.notchShortcutItems) var shortcutItems

    var body: some View {
        let count = min(max(homeShortcutCount, 1), 2)
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ForEach(0..<count, id: \.self) { slotIdx in
                    let item = shortcutManager.slotItem(at: slotIdx)
                    HomeShortcutSlotButton(
                        slotIndex: slotIdx,
                        item: item,
                        isCompact: count == 2,
                        isRunning: shortcutManager.runningSlotIndex == slotIdx,
                        onRun: {
                            shortcutManager.run(slotIndex: slotIdx, viewModel: vm)
                        }
                    )
                }
            }
            if let banner = shortcutManager.statusBanner {
                Text(banner)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .onAppear {
            shortcutManager.ensureTwoSlots()
            if shortcutManager.availableAppleShortcuts.isEmpty {
                shortcutManager.refreshAppleShortcuts()
            }
        }
    }
}

private struct HomeShortcutSlotButton: View {
    let slotIndex: Int
    let item: NotchShortcutItem
    let isCompact: Bool
    let isRunning: Bool
    let onRun: () -> Void

    @ObservedObject var shortcutManager = ShortcutManager.shared
    @Default(.homeShortcutCount) var homeShortcutCount
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onRun) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isHovered ? Color.white : Color.white.opacity(0.14))
                            .frame(width: 26, height: 26)

                        if isRunning {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(isHovered ? Color.black : Color.white)
                        } else if case .openApp(let bundleID, let appPath) = item.kind,
                                  let iconImage = resolveAppIcon(bundleID: bundleID, path: appPath) {
                            Image(nsImage: iconImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 18, height: 18)
                        } else {
                            Image(systemName: item.icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(isHovered ? Color.black : Color.white)
                        }
                    }

                    if !isCompact {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.white)
                                .lineLimit(1)
                            Text(item.subtitle)
                                .font(.system(size: 9.5))
                                .foregroundStyle(Color.white.opacity(0.55))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }

                if isCompact {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                        Text(item.subtitle)
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.12 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(isHovered ? 0.32 : 0.12), lineWidth: 1)
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.14), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Section("Shortcut Button \(slotIndex + 1)") {
                Button("Run \"\(item.title)\"") {
                    onRun()
                }
            }

            Menu("Change to System Action") {
                ForEach(SystemShortcutAction.allCases) { action in
                    Button(action.defaultTitle) {
                        shortcutManager.setSlotToSystemAction(action, slotIndex: slotIndex)
                    }
                }
            }

            if !shortcutManager.availableAppleShortcuts.isEmpty {
                Menu("Change to Mac Shortcut") {
                    ForEach(shortcutManager.availableAppleShortcuts, id: \.self) { name in
                        Button(name) {
                            shortcutManager.setSlotToAppleShortcut(name, slotIndex: slotIndex)
                        }
                    }
                }
            }

            Button("Choose Application (.app)…") {
                shortcutManager.pickAppForSlot(slotIndex)
            }

            Divider()

            Button(homeShortcutCount == 1 ? "Show 2 Shortcut Buttons" : "Show Only 1 Shortcut Button") {
                Defaults[.homeShortcutCount] = (homeShortcutCount == 1) ? 2 : 1
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

// MARK: - Settings Section for Home Quick Shortcuts

struct NotchShortcutsSettingsSection: View {
    @ObservedObject var shortcutManager = ShortcutManager.shared
    @Default(.boringShortcuts) var boringShortcuts
    @Default(.homeShortcutCount) var homeShortcutCount
    @Default(.alwaysShowHomeShortcuts) var alwaysShowHomeShortcuts
    @Default(.closeNotchOnShortcutRun) var closeNotchOnShortcutRun
    @Default(.notchShortcutItems) var shortcutItems

    @State private var customShortcut1: String = ""
    @State private var customShortcut2: String = ""

    var body: some View {
        Section {
            Defaults.Toggle(key: .boringShortcuts) {
                Text("Show custom shortcuts in 'No events today' area")
            }
            Picker("Number of shortcut buttons", selection: $homeShortcutCount) {
                Text("1 Button").tag(1)
                Text("2 Buttons").tag(2)
            }
            .disabled(!boringShortcuts)

            Defaults.Toggle(key: .alwaysShowHomeShortcuts) {
                Text("Always show shortcuts below calendar dates (even when events exist)")
            }
            .disabled(!boringShortcuts)

            Defaults.Toggle(key: .closeNotchOnShortcutRun) {
                Text("Auto-close notch after running a shortcut")
            }
            .disabled(!boringShortcuts)
        } header: {
            Text("Home Notch Shortcuts")
        } footer: {
            Text("Right-click any shortcut button directly in the notch (or configure below) to change its action, app, or macOS Shortcut.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }

        if boringShortcuts {
            slotConfigSection(slotIndex: 0, customName: $customShortcut1)
            if homeShortcutCount >= 2 {
                slotConfigSection(slotIndex: 1, customName: $customShortcut2)
            }
        }
    }

    @ViewBuilder
    private func slotConfigSection(slotIndex: Int, customName: Binding<String>) -> some View {
        let currentItem = shortcutManager.slotItem(at: slotIndex)
        Section {
            HStack {
                Text("Current:")
                    .foregroundStyle(Color.secondary)
                Image(systemName: currentItem.icon)
                Text(currentItem.title)
                    .fontWeight(.semibold)
                Text("(\(currentItem.subtitle))")
                    .foregroundStyle(Color.secondary)
                Spacer()
                Button("Choose App (.app)…") {
                    shortcutManager.pickAppForSlot(slotIndex)
                }
            }

            Menu("Set to Quick System Action: \(currentItem.title)") {
                ForEach(SystemShortcutAction.allCases) { action in
                    Button(action.defaultTitle) {
                        shortcutManager.setSlotToSystemAction(action, slotIndex: slotIndex)
                    }
                }
            }

            HStack {
                TextField("Or type macOS Shortcut name…", text: customName)
                    .textFieldStyle(.roundedBorder)
                Button("Set Mac Shortcut") {
                    let trimmed = customName.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    shortcutManager.setSlotToAppleShortcut(trimmed, slotIndex: slotIndex)
                    customName.wrappedValue = ""
                }
                .disabled(customName.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Shortcut Button \(slotIndex + 1)")
        }
    }
}
