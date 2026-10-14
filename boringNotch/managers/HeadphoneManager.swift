//
//  HeadphoneManager.swift
//  boringNotch
//

import AppKit
import Combine
import CoreAudio
import Defaults
import Foundation
import IOKit
import SwiftUI

struct AudioOutputDeviceItem: Identifiable, Hashable {
    let id: AudioObjectID
    let name: String
    let isHeadphone: Bool
    let isCurrentDefault: Bool
    let icon: String
}

final class HeadphoneManager: ObservableObject {
    static let shared = HeadphoneManager()

    @Published private(set) var currentDeviceName: String = ""
    @Published private(set) var currentDeviceIcon: String = "headphones"
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var lastEventWasConnect: Bool = true
    @Published private(set) var transportLabel: String = "Bluetooth Audio"

    // Battery levels (0...100) if available from Bluetooth HID / IORegistry
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var leftBatteryPercent: Int?
    @Published private(set) var rightBatteryPercent: Int?
    @Published private(set) var caseBatteryPercent: Int?

    @Published private(set) var availableOutputDevices: [AudioOutputDeviceItem] = []

    private var previousDeviceID: AudioObjectID = kAudioObjectUnknown
    private var previousDataSourceID: UInt32 = 0
    private var didInitialFetch: Bool = false
    private var lastConnectedHeadphoneName: String = "Headphones"
    private var lastConnectedHeadphoneIcon: String = "airpodspro"
    private var lastConnectedTransportLabel: String = "Bluetooth Audio"

    // CoreAudio FourCC for External Headphones ('hdpn' = 0x6864706e)
    private let kHeadphoneDataSourceCode: UInt32 = 0x6864706e

    private init() {
        setupAudioListeners()
        fetchInitialDevice()
    }

    // MARK: - CoreAudio Queries

    func systemOutputDeviceID() -> AudioObjectID {
        var defaultDeviceID = kAudioObjectUnknown
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &defaultDeviceID
        )
        if status != noErr { return kAudioObjectUnknown }
        return defaultDeviceID
    }

    private func getDeviceName(deviceID: AudioObjectID) -> String? {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameCF: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &nameAddress,
            0,
            nil,
            &nameSize,
            &nameCF
        )
        if status == noErr {
            return nameCF as String
        }
        return nil
    }

    private func getDeviceTransportType(deviceID: AudioObjectID) -> UInt32 {
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &transportAddress,
            0,
            nil,
            &transportSize,
            &transportType
        )
        if status == noErr {
            return transportType
        }
        return 0
    }

    private func getDeviceDataSource(deviceID: AudioObjectID) -> UInt32 {
        var sourceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &sourceAddress) else { return 0 }
        var sourceID: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(deviceID, &sourceAddress, 0, nil, &size, &sourceID) == noErr {
            return sourceID
        }
        return 0
    }

    private func hasOutputChannels(deviceID: AudioObjectID) -> Bool {
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return false }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &dataSize, bufferListPointer) == noErr else {
            return false
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer.assumingMemoryBound(to: AudioBufferList.self))
        var totalChannels: UInt32 = 0
        for buffer in bufferList {
            totalChannels += buffer.mNumberChannels
        }
        return totalChannels > 0
    }

    private func classifyDevice(deviceID: AudioObjectID) -> (isHeadphone: Bool, displayName: String, icon: String, transportLabel: String) {
        let rawName = getDeviceName(deviceID: deviceID) ?? "Audio Output"
        let transportType = getDeviceTransportType(deviceID: deviceID)
        let dataSource = getDeviceDataSource(deviceID: deviceID)
        let lowerName = rawName.lowercased()

        let isBluetooth = (transportType == kAudioDeviceTransportTypeBluetooth ||
                           transportType == kAudioDeviceTransportTypeBluetoothLE)
        let isWiredJack = (dataSource == kHeadphoneDataSourceCode) ||
                          lowerName.contains("external headphones") ||
                          lowerName.contains("tai nghe")

        let isHeadphoneByName = lowerName.contains("airpod") ||
                                lowerName.contains("headphone") ||
                                lowerName.contains("headset") ||
                                lowerName.contains("earphone") ||
                                lowerName.contains("earbud") ||
                                lowerName.contains("buds") ||
                                lowerName.contains("beats") ||
                                lowerName.contains("wh-") ||
                                lowerName.contains("wf-") ||
                                lowerName.contains("bose") ||
                                lowerName.contains("sennheiser") ||
                                lowerName.contains("marshall") ||
                                lowerName.contains("jbl") ||
                                lowerName.contains("wireless")

        let isSpeakerName = lowerName.contains("speaker") ||
                            lowerName.contains("loa") ||
                            lowerName.contains("macbook") ||
                            lowerName.contains("internal") ||
                            lowerName.contains("hdmi") ||
                            lowerName.contains("displayport")

        let isHeadphone = isWiredJack || isBluetooth || (isHeadphoneByName && !isSpeakerName)

        let icon: String
        if lowerName.contains("max") {
            icon = "airpodsmax"
        } else if lowerName.contains("pro") && lowerName.contains("airpod") {
            icon = "airpodspro"
        } else if lowerName.contains("airpod") {
            icon = "airpods.gen3"
        } else if lowerName.contains("beats") {
            icon = "beats.headphones"
        } else if lowerName.contains("buds") || lowerName.contains("wf-") || lowerName.contains("earbud") {
            icon = "earbuds"
        } else if isHeadphone {
            icon = "headphones"
        } else {
            icon = "hifispeaker.fill"
        }

        let transport: String
        if isBluetooth {
            transport = "Bluetooth Audio"
        } else if isWiredJack {
            transport = "3.5mm Headphone Jack"
        } else if transportType == kAudioDeviceTransportTypeUSB {
            transport = "USB Audio"
        } else {
            transport = "System Audio"
        }

        let effectiveName = (isWiredJack && isSpeakerName) ? "External Headphones" : rawName
        return (isHeadphone, effectiveName, icon, transport)
    }

    // MARK: - Bluetooth Battery Lookup via IORegistry

    private func fetchBluetoothBatteryInfo(matching deviceName: String) -> (single: Int?, left: Int?, right: Int?, caseLevel: Int?) {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("AppleDeviceManagementHIDEventService")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return (nil, nil, nil, nil)
        }
        defer { IOObjectRelease(iterator) }

        let targetLower = deviceName.lowercased()
        var fallbackResult: (Int?, Int?, Int?, Int?) = (nil, nil, nil, nil)

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = propsRef?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            let product = (dict["Product"] as? String ?? "").lowercased()
            let single = (dict["BatteryPercent"] as? Int) ?? (dict["BatteryPercentSingle"] as? Int)
            let left = dict["BatteryPercentLeft"] as? Int
            let right = dict["BatteryPercentRight"] as? Int
            let caseVal = dict["BatteryPercentCase"] as? Int

            let hasAnyBattery = (single != nil && single! > 0) ||
                                (left != nil && left! > 0) ||
                                (right != nil && right! > 0)
            guard hasAnyBattery else { continue }

            let effectiveSingle: Int? = {
                if let s = single, s > 0 { return s }
                let vals = [left, right].compactMap { $0 }.filter { $0 > 0 }
                guard !vals.isEmpty else { return nil }
                return vals.reduce(0, +) / vals.count
            }()

            if !product.isEmpty && (targetLower.contains(product) || product.contains(targetLower)) {
                return (
                    effectiveSingle,
                    (left ?? 0) > 0 ? left : nil,
                    (right ?? 0) > 0 ? right : nil,
                    (caseVal ?? 0) > 0 ? caseVal : nil
                )
            }
            if fallbackResult.0 == nil {
                fallbackResult = (
                    effectiveSingle,
                    (left ?? 0) > 0 ? left : nil,
                    (right ?? 0) > 0 ? right : nil,
                    (caseVal ?? 0) > 0 ? caseVal : nil
                )
            }
        }

        return fallbackResult
    }

    // MARK: - Output Device Switching

    func refreshOutputDevicesList() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else { return }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else { return }

        let currentDefault = systemOutputDeviceID()
        var items: [AudioOutputDeviceItem] = []

        for id in deviceIDs where hasOutputChannels(deviceID: id) {
            let info = classifyDevice(deviceID: id)
            items.append(
                AudioOutputDeviceItem(
                    id: id,
                    name: info.displayName,
                    isHeadphone: info.isHeadphone,
                    isCurrentDefault: id == currentDefault,
                    icon: info.icon
                )
            )
        }

        DispatchQueue.main.async {
            self.availableOutputDevices = items
        }
    }

    func selectOutputDevice(_ deviceID: AudioObjectID) {
        var mutableID = deviceID
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            size,
            &mutableID
        )
        refreshOutputDevicesList()
    }

    // MARK: - Listeners & Popup Trigger

    private func fetchInitialDevice() {
        let deviceID = systemOutputDeviceID()
        previousDeviceID = deviceID
        if deviceID != kAudioObjectUnknown {
            previousDataSourceID = getDeviceDataSource(deviceID: deviceID)
            let info = classifyDevice(deviceID: deviceID)
            let battery = fetchBluetoothBatteryInfo(matching: info.displayName)
            DispatchQueue.main.async {
                self.isConnected = info.isHeadphone
                self.currentDeviceName = info.displayName
                self.currentDeviceIcon = info.icon
                self.transportLabel = info.transportLabel
                self.batteryPercent = battery.single
                self.leftBatteryPercent = battery.left
                self.rightBatteryPercent = battery.right
                self.caseBatteryPercent = battery.caseLevel
                if info.isHeadphone {
                    self.lastConnectedHeadphoneName = info.displayName
                    self.lastConnectedHeadphoneIcon = info.icon
                    self.lastConnectedTransportLabel = info.transportLabel
                    BoringViewCoordinator.shared.connectedDeviceName = info.displayName
                    BoringViewCoordinator.shared.connectedDeviceIcon = info.icon
                    BoringViewCoordinator.shared.headphoneConnected = true
                    BoringViewCoordinator.shared.headphoneBatteryPercent = battery.single
                }
            }
        }
        refreshOutputDevicesList()
        didInitialFetch = true
    }

    private func setupAudioListeners() {
        var defaultDevAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDevAddr,
            nil
        ) { [weak self] _, _ in
            self?.handleDeviceChange()
        }

        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddr,
            nil
        ) { [weak self] _, _ in
            self?.refreshOutputDevicesList()
            self?.handleDeviceChange()
        }
    }

    private func handleDeviceChange() {
        let currentID = systemOutputDeviceID()
        guard currentID != kAudioObjectUnknown else { return }
        let currentDataSource = getDeviceDataSource(deviceID: currentID)

        if currentID == previousDeviceID && currentDataSource == previousDataSourceID && didInitialFetch {
            return
        }

        previousDeviceID = currentID
        previousDataSourceID = currentDataSource

        guard didInitialFetch else {
            didInitialFetch = true
            return
        }

        let info = classifyDevice(deviceID: currentID)
        let battery = fetchBluetoothBatteryInfo(matching: info.displayName)
        refreshOutputDevicesList()

        DispatchQueue.main.async {
            let wasConnected = self.isConnected

            if info.isHeadphone {
                self.currentDeviceName = info.displayName
                self.currentDeviceIcon = info.icon
                self.transportLabel = info.transportLabel
                self.isConnected = true
                self.lastEventWasConnect = true
                self.batteryPercent = battery.single
                self.leftBatteryPercent = battery.left
                self.rightBatteryPercent = battery.right
                self.caseBatteryPercent = battery.caseLevel

                self.lastConnectedHeadphoneName = info.displayName
                self.lastConnectedHeadphoneIcon = info.icon
                self.lastConnectedTransportLabel = info.transportLabel

                BoringViewCoordinator.shared.connectedDeviceName = info.displayName
                BoringViewCoordinator.shared.connectedDeviceIcon = info.icon
                BoringViewCoordinator.shared.headphoneConnected = true
                BoringViewCoordinator.shared.headphoneBatteryPercent = battery.single

                if Defaults[.enableHeadphonePopup] {
                    BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .headphone)
                }
            } else if wasConnected {
                // Headphone was disconnected and audio fell back to speakers
                self.isConnected = false
                self.lastEventWasConnect = false
                self.batteryPercent = nil
                self.leftBatteryPercent = nil
                self.rightBatteryPercent = nil
                self.caseBatteryPercent = nil

                BoringViewCoordinator.shared.connectedDeviceName = self.lastConnectedHeadphoneName
                BoringViewCoordinator.shared.connectedDeviceIcon = self.lastConnectedHeadphoneIcon
                BoringViewCoordinator.shared.headphoneConnected = false
                BoringViewCoordinator.shared.headphoneBatteryPercent = nil

                if Defaults[.enableHeadphonePopup] && Defaults[.showHeadphoneDisconnectPopup] {
                    BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .headphone)
                }
            }
        }
    }

    @MainActor
    func triggerTestPopup(simulatedConnect: Bool = true) {
        let testName = isConnected && !currentDeviceName.isEmpty ? currentDeviceName : "AirPods Pro"
        let testIcon = isConnected && !currentDeviceIcon.isEmpty ? currentDeviceIcon : "airpodspro"
        let testBattery = batteryPercent ?? 88

        lastEventWasConnect = simulatedConnect
        if simulatedConnect {
            if leftBatteryPercent == nil && rightBatteryPercent == nil {
                leftBatteryPercent = 92
                rightBatteryPercent = 85
                caseBatteryPercent = 76
            }
            batteryPercent = testBattery
            transportLabel = "Bluetooth Audio"
        }

        BoringViewCoordinator.shared.connectedDeviceName = testName
        BoringViewCoordinator.shared.connectedDeviceIcon = testIcon
        BoringViewCoordinator.shared.headphoneConnected = simulatedConnect
        BoringViewCoordinator.shared.headphoneBatteryPercent = simulatedConnect ? testBattery : nil
        BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .headphone)
    }
}

// MARK: - Headphone Popup Views (Closed Notch)

struct HeadphoneInlineBarView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var headphoneManager = HeadphoneManager.shared
    @Default(.showHeadphoneBattery) var showHeadphoneBattery
    let closedNotchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: coordinator.connectedDeviceIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(coordinator.headphoneConnected ? .white : .gray)
                    .symbolEffect(.pulse, isActive: coordinator.headphoneConnected)
                Text(coordinator.connectedDeviceName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)

            Rectangle()
                .fill(.black)
                .frame(width: closedNotchWidth + 10)

            HStack(spacing: 6) {
                Circle()
                    .fill(coordinator.headphoneConnected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)

                if coordinator.headphoneConnected,
                   showHeadphoneBattery,
                   let battery = coordinator.headphoneBatteryPercent {
                    HStack(spacing: 4) {
                        Image(systemName: batterySymbol(for: battery))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(battery > 20 ? .green : .red)
                        Text("\(battery)%")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                } else {
                    Text(coordinator.headphoneConnected ? "Connected" : "Disconnected")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 12)
        }
        .frame(height: height, alignment: .center)
    }

    private func batterySymbol(for level: Int) -> String {
        switch level {
        case 85...100: return "battery.100percent"
        case 60..<85: return "battery.75percent"
        case 35..<60: return "battery.50percent"
        case 15..<35: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

struct HeadphonePopupCardView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var headphoneManager = HeadphoneManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @Default(.showHeadphoneBattery) var showHeadphoneBattery

    @State private var pulseAnimation: Bool = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            (coordinator.headphoneConnected ? Color.green : Color.orange)
                                .opacity(pulseAnimation ? 0.24 : 0.12)
                        )
                        .frame(width: 44, height: 44)
                        .scaleEffect(pulseAnimation ? 1.06 : 0.96)

                    Circle()
                        .strokeBorder(
                            (coordinator.headphoneConnected ? Color.green : Color.orange).opacity(0.5),
                            lineWidth: 1.5
                        )
                        .frame(width: 42, height: 42)

                    Image(systemName: coordinator.connectedDeviceIcon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(coordinator.connectedDeviceName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            Circle()
                                .fill(coordinator.headphoneConnected ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                            Text(coordinator.headphoneConnected ? "Connected" : "Disconnected")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(coordinator.headphoneConnected ? .green : .orange)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill((coordinator.headphoneConnected ? Color.green : Color.orange).opacity(0.16))
                        )
                    }

                    Text(headphoneManager.transportLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.gray)
                }

                Spacer(minLength: 8)

                if coordinator.headphoneConnected && showHeadphoneBattery {
                    batterySection
                }
            }

            if coordinator.headphoneConnected {
                HStack(spacing: 10) {
                    Image(systemName: volumeManager.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.gray)
                        .frame(width: 16)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.14))
                                .frame(height: 5)
                            Capsule()
                                .fill(Color.white)
                                .frame(
                                    width: max(0, min(1, CGFloat(volumeManager.isMuted ? 0 : volumeManager.rawVolume))) * geo.size.width,
                                    height: 5
                                )
                        }
                    }
                    .frame(height: 5)

                    Text("\(Int(round((volumeManager.isMuted ? 0 : volumeManager.rawVolume) * 100)))%")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.gray)
                        .frame(width: 32, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 390)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulseAnimation = true
            }
        }
    }

    @ViewBuilder
    private var batterySection: some View {
        if let left = headphoneManager.leftBatteryPercent,
           let right = headphoneManager.rightBatteryPercent {
            HStack(spacing: 6) {
                batteryPill(label: "L", percent: left)
                batteryPill(label: "R", percent: right)
                if let caseLevel = headphoneManager.caseBatteryPercent {
                    batteryPill(label: "C", percent: caseLevel)
                }
            }
        } else if let single = coordinator.headphoneBatteryPercent {
            HStack(spacing: 5) {
                Image(systemName: single > 20 ? "battery.100percent" : "battery.25percent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(single > 20 ? .green : .red)
                Text("\(single)%")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.1)))
        }
    }

    private func batteryPill(label: String, percent: Int) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(.gray)
            Text("\(percent)%")
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(percent > 20 ? .green : .red)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
    }
}

// MARK: - Open Notch Header Badge & Audio Output Switcher

struct HeadphoneHeaderButton: View {
    @ObservedObject var headphoneManager = HeadphoneManager.shared
    @State private var showDevicesPopover: Bool = false

    var body: some View {
        Button {
            headphoneManager.refreshOutputDevicesList()
            showDevicesPopover.toggle()
        } label: {
            Capsule()
                .fill(.black)
                .frame(height: 30)
                .overlay {
                    HStack(spacing: 5) {
                        Image(systemName: headphoneManager.isConnected ? headphoneManager.currentDeviceIcon : "headphones")
                            .foregroundColor(headphoneManager.isConnected ? .green : .white)
                            .imageScale(.medium)
                        if headphoneManager.isConnected, let battery = headphoneManager.batteryPercent {
                            Text("\(battery)%")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .fixedSize()
        }
        .buttonStyle(PlainButtonStyle())
        .popover(isPresented: $showDevicesPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Audio Output", systemImage: "speaker.wave.2.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Button {
                        HeadphoneManager.shared.triggerTestPopup(simulatedConnect: true)
                        showDevicesPopover = false
                    } label: {
                        Text("Preview Popup")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.bottom, 2)

                Divider()

                ForEach(headphoneManager.availableOutputDevices) { device in
                    Button {
                        headphoneManager.selectOutputDevice(device.id)
                        showDevicesPopover = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: device.icon)
                                .frame(width: 16)
                                .foregroundStyle(device.isCurrentDefault ? Color.accentColor : .secondary)
                            Text(device.name)
                                .font(.system(size: 12, weight: device.isCurrentDefault ? .semibold : .regular))
                                .lineLimit(1)
                            Spacer()
                            if device.isCurrentDefault {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .frame(width: 240)
        }
    }
}

// MARK: - Settings Section for Headphone Popups

struct HeadphonePopupSettingsSection: View {
    @Default(.enableHeadphonePopup) var enableHeadphonePopup
    @Default(.showHeadphoneDisconnectPopup) var showHeadphoneDisconnectPopup
    @Default(.showHeadphoneBattery) var showHeadphoneBattery
    @Default(.headphonePopupStyle) var headphonePopupStyle
    @Default(.showHeadphoneInHeader) var showHeadphoneInHeader

    var body: some View {
        Section {
            Defaults.Toggle(key: .enableHeadphonePopup) {
                Text("Show headphone connection popup")
            }
            Defaults.Toggle(key: .showHeadphoneDisconnectPopup) {
                Text("Show popup when headphones disconnect")
            }
            .disabled(!enableHeadphonePopup)

            Defaults.Toggle(key: .showHeadphoneBattery) {
                Text("Show battery level in headphone popup")
            }
            .disabled(!enableHeadphonePopup)

            Picker("Headphone popup style", selection: $headphonePopupStyle) {
                ForEach(HeadphonePopupStyle.allCases) { style in
                    Text(style.rawValue).tag(style)
                }
            }
            .disabled(!enableHeadphonePopup)

            Defaults.Toggle(key: .showHeadphoneInHeader) {
                Text("Show headphone & audio output switcher in open notch header")
            }

            HStack(spacing: 10) {
                Button("Test Connect Popup") {
                    HeadphoneManager.shared.triggerTestPopup(simulatedConnect: true)
                }
                .buttonStyle(.borderedProminent)

                Button("Test Disconnect Popup") {
                    HeadphoneManager.shared.triggerTestPopup(simulatedConnect: false)
                }
                .buttonStyle(.bordered)
            }
        } header: {
            Text("Headphone Popups")
        } footer: {
            Text("Automatically expands the notch when AirPods, Bluetooth headphones, or wired headphones connect or disconnect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
