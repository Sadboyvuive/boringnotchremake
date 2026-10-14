//
//  BoringViewModel.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import AppKit
import Combine
import CoreGraphics
import Defaults
import SwiftUI

extension Notification.Name {
    static let notchFullscreenVisibilityChanged = Notification.Name("notchFullscreenVisibilityChanged")
}

class BoringViewModel: NSObject, ObservableObject {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var detector = FullscreenMediaDetector.shared

    let animationLibrary: BoringAnimations = .init()
    let animation: Animation?

    @Published var contentType: ContentType = .normal
    @Published private(set) var notchState: NotchState = .closed

    @Published var dragDetectorTargeting: Bool = false
    @Published var generalDropTargeting: Bool = false
    @Published var dropZoneTargeting: Bool = false
    @Published var dropEvent: Bool = false
    @Published var anyDropZoneTargeting: Bool = false
    var cancellables: Set<AnyCancellable> = []
    
    @Published var hideOnClosed: Bool = false {
        didSet {
            if oldValue != hideOnClosed {
                if hideOnClosed && notchState == .open {
                    close()
                }
                NotificationCenter.default.post(name: .notchFullscreenVisibilityChanged, object: nil)
            }
        }
    }

    @Published var edgeAutoOpenActive: Bool = false
    @Published var isHoveringCalendar: Bool = false
    @Published var isBatteryPopoverActive: Bool = false

    @Published var screenUUID: String?

    @Published var notchSize: CGSize = getClosedNotchSize()
    @Published var closedNotchSize: CGSize = getClosedNotchSize()
    
    let webcamManager = WebcamManager.shared
    @Published var isCameraExpanded: Bool = false
    @Published var isRequestingAuthorization: Bool = false
    
    deinit {
        destroy()
    }

    func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    init(screenUUID: String? = nil) {
        animation = animationLibrary.animation

        super.init()
        
        self.screenUUID = screenUUID
        notchSize = getClosedNotchSize(screenUUID: screenUUID)
        closedNotchSize = notchSize

        Publishers.CombineLatest3($dropZoneTargeting, $dragDetectorTargeting, $generalDropTargeting)
            .map { shelf, drag, general in
                shelf || drag || general
            }
            .assign(to: \.anyDropZoneTargeting, on: self)
            .store(in: &cancellables)
        
        setupDetectorObserver()
    }
    
    private func setupDetectorObserver() {
        let enabledPublisher = Defaults
            .publisher(.hideNotchOption)
            .map(\.newValue)
            .map { $0 != .never }
            .removeDuplicates()

        let screenPublisher = $screenUUID
            .compactMap { $0 }
            .removeDuplicates()

        let fullscreenStatusPublisher = detector.$fullscreenStatus
            .removeDuplicates()

        let timerPublisher = Timer.publish(every: 0.75, on: .main, in: .common)
            .autoconnect()
            .map { _ in () }
            .prepend(())

        Publishers.CombineLatest4(screenPublisher, fullscreenStatusPublisher, enabledPublisher, timerPublisher)
            .map { [weak self] screenUUID, fullscreenStatus, enabled, _ in
                guard enabled else { return false }
                let detectorFullscreen = fullscreenStatus[screenUUID] ?? false
                let gameOrBorderlessFullscreen = self?.isFrontmostAppFullscreenOrGame(screenUUID: screenUUID) ?? false
                return detectorFullscreen || gameOrBorderlessFullscreen
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shouldHide in
                withAnimation(.smooth) {
                    self?.hideOnClosed = shouldHide
                }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let enabled = Defaults[.hideNotchOption] != .never
                guard enabled else {
                    if self.hideOnClosed { self.hideOnClosed = false }
                    return
                }
                let uuid = self.screenUUID ?? NSScreen.main?.displayUUID ?? ""
                let detectorFS = self.detector.fullscreenStatus[uuid] ?? false
                let activeFS = self.isFrontmostAppFullscreenOrGame(screenUUID: uuid)
                let shouldHide = detectorFS || activeFS
                if self.hideOnClosed != shouldHide {
                    withAnimation(.smooth) {
                        self.hideOnClosed = shouldHide
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func isFrontmostAppFullscreenOrGame(screenUUID: String?) -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
        let bundleID = (frontApp.bundleIdentifier ?? "").lowercased()
        let appName = (frontApp.localizedName ?? "").lowercased()
        let exeName = (frontApp.executableURL?.lastPathComponent ?? "").lowercased()

        if bundleID.contains("boringnotch") || bundleID == "com.apple.finder" || bundleID == "com.apple.dock" {
            return false
        }

        // Direct detection for League of Legends game client & fullscreen Wine/Sikarugir games
        if bundleID.contains("leagueoflegends.gameclient") ||
           bundleID.contains("com.riotgames.leagueoflegends") ||
           exeName == "leagueoflegends" ||
           appName == "league of legends" {
            return true
        }

        let targetScreen = screenUUID.flatMap { NSScreen.screen(withUUID: $0) } ?? NSScreen.main
        guard let screen = targetScreen else { return false }
        let screenFrame = screen.frame

        // Check if the frontmost app has a borderless/fullscreen window covering the display
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let frontPID = frontApp.processIdentifier
        for entry in windowList {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == frontPID,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = boundsDict["Width"],
                  let h = boundsDict["Height"] else {
                continue
            }

            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            // Ignore tiny overlay/status bar windows
            if w >= screenFrame.width - 4 && h >= screenFrame.height - 4 && layer >= 0 {
                return true
            }
            // Also catch notched MacBook fullscreen games that span below the notch (height >= visibleFrame.height and width == screenFrame.width)
            let isGameOrWine = bundleID.contains("riotgames") ||
                               bundleID.contains("leagueoflegends") ||
                               exeName.contains("wine") ||
                               exeName.contains("sikarugir") ||
                               appName.contains("league")
            if isGameOrWine && w >= screenFrame.width - 4 && h >= screen.visibleFrame.height - 4 {
                return true
            }
        }

        return false
    }

    // Computed property for effective notch height
    var effectiveClosedNotchHeight: CGFloat {
        if hideOnClosed {
            return 0
        }
        return closedNotchSize.height
    }

    var chinHeight: CGFloat {
        if !Defaults[.hideTitleBar] || hideOnClosed {
            return 0
        }

        guard let currentScreen = screenUUID.flatMap({ NSScreen.screen(withUUID: $0) }) else {
            return 0
        }

        if notchState == .open { return 0 }

        let menuBarHeight = currentScreen.frame.maxY - currentScreen.visibleFrame.maxY
        let currentHeight = effectiveClosedNotchHeight

        if currentHeight == 0 { return 0 }

        return max(0, menuBarHeight - currentHeight)
    }

    func toggleCameraPreview() {
        if isRequestingAuthorization {
            return
        }

        switch webcamManager.authorizationStatus {
        case .authorized:
            if webcamManager.isSessionRunning {
                webcamManager.stopSession()
                isCameraExpanded = false
            } else if webcamManager.cameraAvailable {
                webcamManager.startSession()
                isCameraExpanded = true
            }

        case .denied, .restricted:
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)

                let alert = NSAlert()
                alert.messageText = "Camera Access Required"
                alert.informativeText = "Please allow camera access in System Settings."
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Cancel")

                if alert.runModal() == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }

                NSApp.setActivationPolicy(.accessory)
                NSApp.deactivate()
            }

        case .notDetermined:
            isRequestingAuthorization = true
            webcamManager.checkAndRequestVideoAuthorization()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.isRequestingAuthorization = false
            }

        default:
            break
        }
    }
    
    func isMouseHovering(position: NSPoint = NSEvent.mouseLocation) -> Bool {
        let screenFrame = getScreenFrame(screenUUID)
        if let frame = screenFrame {
            
            let baseY = frame.maxY - notchSize.height
            let baseX = frame.midX - notchSize.width / 2
            
            return position.y >= baseY && position.x >= baseX && position.x <= baseX + notchSize.width
        }
        
        return false
    }

    func open() {
        guard !hideOnClosed else { return }
        self.notchSize = openNotchSize
        self.notchState = .open
        
        // Force music information update when notch is opened
        MusicManager.shared.forceUpdate()
    }

    func close() {
        // Do not close while a share picker or sharing service is active
        if SharingStateManager.shared.preventNotchClose && !hideOnClosed {
            return
        }
        self.notchSize = getClosedNotchSize(screenUUID: self.screenUUID)
        self.closedNotchSize = self.notchSize
        self.notchState = .closed
        self.isBatteryPopoverActive = false
        self.coordinator.sneakPeek.show = false
        self.edgeAutoOpenActive = false

        if !ShelfStateViewModel.shared.isEmpty && Defaults[.openShelfByDefault] {
            coordinator.currentView = .shelf
        } else if !coordinator.openLastTabByDefault {
            coordinator.currentView = .home
        }
    }

    func closeHello() {
        Task { @MainActor in
            withAnimation(animationLibrary.animation) {
                coordinator.helloAnimationRunning = false
                close()
            }
        }
    }
}
