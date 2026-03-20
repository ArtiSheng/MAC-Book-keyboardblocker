//
//  KeyboardManager.swift
//  禁用自带键盘
//
//  IOKit HID 键盘设备监控管理器
//  负责检测已连接的键盘设备，区分内置和外接键盘
//

import Foundation
import IOKit.hid
import Combine



// MARK: - 键盘设备信息

struct KeyboardInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let manufacturer: String
    let transport: String
    let vendorID: Int
    let productID: Int
    let isBuiltIn: Bool
    var typeLabel: String {
        isBuiltIn ? "内置" : "外接"
    }

    var typeIcon: String {
        isBuiltIn ? "laptopcomputer" : "rectangle.connected.to.line.below"
    }

    var transportLabel: String {
        switch transport.uppercased() {
        case "USB": return "USB"
        case "BLUETOOTH", "BLUETOOTHLE": return "蓝牙"
        case "FIFO", "SPI": return "内置总线"
        default: return transport.isEmpty ? "未知" : transport
        }
    }

    static func == (lhs: KeyboardInfo, rhs: KeyboardInfo) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 键盘管理器

class KeyboardManager: ObservableObject {
    @Published var keyboards: [KeyboardInfo] = []
    @Published var hasExternalKeyboard: Bool = false
    @Published var hasBuiltInKeyboard: Bool = false

    private var hidManager: IOHIDManager?
    private var deviceMap: [IOHIDDevice: KeyboardInfo] = [:]

    init() {}

    deinit {
        stopMonitoring()
    }

    // MARK: - 启动监控

    func startMonitoring() {
        guard hidManager == nil else { return }

        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = hidManager else { return }

        // 只匹配键盘设备
        let keyboardDict: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, [keyboardDict] as CFArray)

        // 注册设备连接回调
        let matchCallback: IOHIDDeviceCallback = { context, _, _, device in
            guard let ctx = context else { return }
            let mgr = Unmanaged<KeyboardManager>.fromOpaque(ctx).takeUnretainedValue()
            mgr.handleDeviceConnected(device)
        }

        // 注册设备断开回调
        let removalCallback: IOHIDDeviceCallback = { context, _, _, device in
            guard let ctx = context else { return }
            let mgr = Unmanaged<KeyboardManager>.fromOpaque(ctx).takeUnretainedValue()
            mgr.handleDeviceDisconnected(device)
        }

        let ptr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCallback, ptr)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, removalCallback, ptr)

        // 调度到主 RunLoop
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: - 停止监控

    func stopMonitoring() {
        guard let manager = hidManager else { return }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = nil
        deviceMap.removeAll()
    }

    // MARK: - 设备连接处理

    private func handleDeviceConnected(_ device: IOHIDDevice) {
        let info = makeKeyboardInfo(from: device)
        deviceMap[device] = info

        DispatchQueue.main.async {
            // 去重：同一物理设备可能有多个 HID 接口
            if !self.keyboards.contains(where: { $0.id == info.id }) {
                self.keyboards.append(info)
            }
            self.updateStatus()
        }
    }

    // MARK: - 设备断开处理

    private func handleDeviceDisconnected(_ device: IOHIDDevice) {
        guard let info = deviceMap[device] else { return }
        deviceMap.removeValue(forKey: device)

        DispatchQueue.main.async {
            self.keyboards.removeAll { $0.id == info.id }
            self.updateStatus()
        }
    }

    // MARK: - 更新状态

    private func updateStatus() {
        hasExternalKeyboard = keyboards.contains { !$0.isBuiltIn }
        hasBuiltInKeyboard = keyboards.contains { $0.isBuiltIn }
    }

    // MARK: - 解析设备信息

    private func makeKeyboardInfo(from device: IOHIDDevice) -> KeyboardInfo {
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "未知设备"
        let manufacturer = IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String ?? ""
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let isBuiltIn = Self.isBuiltInKeyboard(product: product, transport: transport)

        return KeyboardInfo(
            id: "\(vendorID):\(productID):\(product):\(transport)",
            name: product,
            manufacturer: manufacturer,
            transport: transport,
            vendorID: vendorID,
            productID: productID,
            isBuiltIn: isBuiltIn
        )
    }

    // MARK: - 内置键盘判断

    /// 判断一个键盘是否为 MacBook 内置键盘
    /// 依据硬件属性：产品名包含 "Apple Internal" 或传输协议为 FIFO（SPI 总线）
    static func isBuiltInKeyboard(product: String, transport: String) -> Bool {
        if product.contains("Apple Internal") { return true }
        if transport.uppercased() == "FIFO" { return true }
        return false
    }
}
