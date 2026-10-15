import AppKit
import CoreGraphics

final class BrightnessManager: ObservableObject {
    static let shared = BrightnessManager()

    @Published private(set) var rawBrightness: Float = 0.75
    @Published private(set) var animatedBrightness: Float = 0.75
    @Published private(set) var lastChangeAt: Date = .distantPast
    @Published private(set) var isExternalDisplay: Bool = false

    private let visibleDuration: TimeInterval = 1.2
    private let client = XPCHelperClient.shared
    private var externalBrightnessMap: [CGDirectDisplayID: Float] = [:]

    private init() { refresh() }

    var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < visibleDuration }

    private func targetDisplayID() -> CGDirectDisplayID {
        let mouseLoc = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }),
           let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            return id
        }
        return CGMainDisplayID()
    }

    func refresh() {
        let displayID = targetDisplayID()
        let isExt = CGDisplayIsBuiltin(displayID) == 0
        Task { @MainActor in
            self.isExternalDisplay = isExt
            if !isExt, let current = await client.currentScreenBrightness() {
                publish(brightness: current, touchDate: false)
            } else if let saved = externalBrightnessMap[displayID] {
                publish(brightness: saved, touchDate: false)
            }
        }
    }

    @MainActor func setRelative(delta: Float) {
        let displayID = targetDisplayID()
        let isExt = CGDisplayIsBuiltin(displayID) == 0
        self.isExternalDisplay = isExt
        Task { @MainActor in
            let starting: Float
            if !isExt, let current = await client.currentScreenBrightness() {
                starting = current
            } else {
                starting = externalBrightnessMap[displayID] ?? rawBrightness
            }
            let target = max(0, min(1, starting + delta))
            await applyBrightness(target, to: displayID, isExternal: isExt)
            BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .brightness, value: CGFloat(target))
        }
    }

    func setAbsolute(value: Float) {
        let clamped = max(0, min(1, value))
        let displayID = targetDisplayID()
        let isExt = CGDisplayIsBuiltin(displayID) == 0
        Task { @MainActor in
            self.isExternalDisplay = isExt
            await applyBrightness(clamped, to: displayID, isExternal: isExt)
        }
    }

    @MainActor private func applyBrightness(_ value: Float, to displayID: CGDirectDisplayID, isExternal: Bool) async {
        if !isExternal {
            let ok = await client.setScreenBrightness(value)
            if ok {
                publish(brightness: value, touchDate: true)
                return
            }
        }
        externalBrightnessMap[displayID] = value
        let gammaMax = max(0.08, CGGammaValue(value))
        CGSetDisplayTransferByFormula(
            displayID,
            0, gammaMax, 1.0,
            0, gammaMax, 1.0,
            0, gammaMax, 1.0
        )
        publish(brightness: value, touchDate: true)
    }

    private func publish(brightness: Float, touchDate: Bool) {
        DispatchQueue.main.async {
            if self.rawBrightness != brightness || touchDate {
                if touchDate { self.lastChangeAt = Date() }
                self.rawBrightness = brightness
                self.animatedBrightness = brightness
            }
        }
    }
}

final class KeyboardBacklightManager: ObservableObject {
    static let shared = KeyboardBacklightManager()

    @Published private(set) var rawBrightness: Float = 0
    @Published private(set) var lastChangeAt: Date = .distantPast

    private let visibleDuration: TimeInterval = 1.2
    private let client = XPCHelperClient.shared

    private init() { refresh() }

    var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < visibleDuration }

    func refresh() {
        Task { @MainActor in
            if let current = await client.currentKeyboardBrightness() {
                publish(brightness: current, touchDate: false)
            }
        }
    }

    @MainActor func setRelative(delta: Float) {
        Task { @MainActor in
            let starting = await client.currentKeyboardBrightness() ?? rawBrightness
            let target = max(0, min(1, starting + delta))
            let ok = await client.setKeyboardBrightness(target)
            if ok {
                publish(brightness: target, touchDate: true)
            } else {
                refresh()
            }
            BoringViewCoordinator.shared.toggleSneakPeek(
                status: true,
                type: .backlight,
                value: CGFloat(target)
            )
        }
    }

    func setAbsolute(value: Float) {
        let clamped = max(0, min(1, value))
        Task { @MainActor in
            let ok = await client.setKeyboardBrightness(clamped)
            if ok {
                publish(brightness: clamped, touchDate: true)
            } else {
                refresh()
            }
        }
    }

    private func publish(brightness: Float, touchDate: Bool) {
        DispatchQueue.main.async {
            if self.rawBrightness != brightness || touchDate {
                if touchDate { self.lastChangeAt = Date() }
                self.rawBrightness = brightness
            }
        }
    }
}
