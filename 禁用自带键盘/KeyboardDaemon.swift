//
//  KeyboardDaemon.swift
//  禁用自带键盘
//
//  守护进程模式核心逻辑
//  以 root 权限运行，负责独占/释放内置键盘设备
//

import Foundation
import IOKit.hid

class KeyboardDaemon {

    private var hidManager: IOHIDManager?
    private var allDevices: [IOHIDDevice] = []
    private var seizedDevices: Set<IOHIDDevice> = []
    private let statusFilePath = "/tmp/com.keyboardblocker.daemon.status.json"
    private let logFilePath = "/tmp/com.keyboardblocker.daemon.log"
    private var heartbeatTimer: Timer?
    private var logFileHandle: FileHandle?

    // MARK: - 启动守护进程

    func start() {
        // 忽略 SIGPIPE（父进程关闭管道时不崩溃）
        signal(SIGPIPE, SIG_IGN)

        // 写 PID 文件
        let pidPath = "/tmp/com.keyboardblocker.daemon.pid"
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(toFile: pidPath, atomically: true, encoding: .utf8)

        log("========== 守护进程启动 ==========")
        log("PID: \(ProcessInfo.processInfo.processIdentifier)")
        log("UID: \(getuid()) (0=root)")
        log("可执行路径: \(ProcessInfo.processInfo.arguments.first ?? "未知")")
        log("参数: \(ProcessInfo.processInfo.arguments)")

        // 安装信号处理器，确保退出时释放所有独占的设备
        setupSignalHandlers()

        // 初始化 HID Manager
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = hidManager else {
            log("错误：无法创建 HID Manager")
            return
        }
        log("HID Manager 创建成功")

        // 匹配键盘设备
        let matchDict: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)
        log("已设置键盘设备匹配规则")

        // 注册回调
        let matchCB: IOHIDDeviceCallback = { ctx, _, _, device in
            guard let c = ctx else { return }
            Unmanaged<KeyboardDaemon>.fromOpaque(c).takeUnretainedValue().deviceMatched(device)
        }
        let removeCB: IOHIDDeviceCallback = { ctx, _, _, device in
            guard let c = ctx else { return }
            Unmanaged<KeyboardDaemon>.fromOpaque(c).takeUnretainedValue().deviceRemoved(device)
        }

        let ptr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCB, ptr)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, removeCB, ptr)
        log("已注册设备连接/断开回调")

        // 调度到主 RunLoop
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        log("已调度到主 RunLoop")

        let ret = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if ret != kIOReturnSuccess {
            log("⚠️ HID Manager 打开失败 (错误码: 0x\(String(ret, radix: 16)))")
            log("请在 系统设置 → 隐私与安全性 → 输入监控 中授权本应用")
            startRetryLoop(manager: manager)
        } else {
            log("✅ HID Manager 已成功打开")
        }

        writeStatus()
        startHeartbeat()
        log("初始化完成，等待设备回调...")
    }

    // MARK: - 权限重试循环

    private func startRetryLoop(manager: IOHIDManager) {
        DispatchQueue.global().async { [weak self] in
            var retryCount = 0
            while true {
                sleep(5)
                retryCount += 1
                let ret = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                if ret == kIOReturnSuccess {
                    self?.log("✅ HID Manager 在第 \(retryCount) 次重试后成功打开")
                    // 回到主线程重新评估设备状态（重试之前 seize 失败的操作）
                    DispatchQueue.main.async {
                        self?.log("重试成功，重新评估设备状态...")
                        self?.evaluateAndUpdate()
                    }
                    break
                }
                if retryCount % 12 == 0 {
                    self?.log("仍在等待输入监控权限授权... (已重试 \(retryCount) 次)")
                }
            }
        }
    }

    // MARK: - 设备连接

    private func deviceMatched(_ device: IOHIDDevice) {
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "未知"
        let manufacturer = IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String ?? ""
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let isBuiltIn = KeyboardManager.isBuiltInKeyboard(product: product, transport: transport)

        log("📥 设备连接:")
        log("   名称: \(product)")
        log("   厂商: \(manufacturer)")
        log("   传输: \(transport)")
        log("   VID:PID = \(vendorID):\(productID)")
        log("   判定: \(isBuiltIn ? "🖥 内置" : "⌨️ 外接")")

        allDevices.append(device)
        log("   当前设备总数: \(allDevices.count)")
        evaluateAndUpdate()
    }

    // MARK: - 设备断开

    private func deviceRemoved(_ device: IOHIDDevice) {
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "未知"
        log("📤 设备断开: \(product)")

        allDevices.removeAll { $0 == device }
        seizedDevices.remove(device)
        log("   当前设备总数: \(allDevices.count)")
        evaluateAndUpdate()
    }

    // MARK: - 评估并更新独占状态

    private func evaluateAndUpdate() {
        log("--- 评估设备状态 ---")

        var internalDevices: [IOHIDDevice] = []
        var externalDevices: [IOHIDDevice] = []

        for device in allDevices {
            let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
            if KeyboardManager.isBuiltInKeyboard(product: product, transport: transport) {
                internalDevices.append(device)
            } else {
                externalDevices.append(device)
            }
        }

        log("内置键盘: \(internalDevices.count) 个, 外接键盘: \(externalDevices.count) 个")
        log("已独占设备: \(seizedDevices.count) 个")

        if !externalDevices.isEmpty {
            // 有外接键盘 → 独占所有内置键盘
            log("检测到外接键盘，尝试独占内置键盘...")
            for device in internalDevices {
                if seizedDevices.contains(device) {
                    log("   已经在独占中，跳过")
                    continue
                }
                let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "未知"
                log("   正在独占: \(name)")

                // 先尝试关闭设备（如果已被 HID Manager 以普通模式打开）
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))

                // 以独占模式打开设备
                let ret = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
                if ret == kIOReturnSuccess {
                    seizedDevices.insert(device)
                    log("   ✅ 独占成功: \(name)")
                } else {
                    log("   ❌ 独占失败: \(name)")
                    log("   错误码: 0x\(String(ret, radix: 16))")
                    let retInt = Int(ret)
                    if retInt == -0x1ffffd1e { // kIOReturnNotPermitted
                        log("   → kIOReturnNotPermitted: 需要「输入监控」权限")
                    } else if retInt == -0x1ffffd3b { // kIOReturnExclusiveAccess
                        log("   → kIOReturnExclusiveAccess: 设备已被其他进程独占")
                    }
                }
            }
        } else {
            // 没有外接键盘 → 释放所有已独占的内置键盘
            if !seizedDevices.isEmpty {
                log("无外接键盘，释放所有独占...")
                for device in seizedDevices {
                    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
                    let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "未知"
                    log("   🔓 已释放: \(name)")
                }
                seizedDevices.removeAll()
            }
        }

        log("最终状态: blocking=\(!seizedDevices.isEmpty), seized=\(seizedDevices.count)")
        writeStatus()
    }

    // MARK: - 心跳定时器

    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            // 检查停止信号文件（GUI 创建此文件即可停止守护进程，无需 root）
            let stopFile = "/tmp/com.keyboardblocker.daemon.stop"
            if FileManager.default.fileExists(atPath: stopFile) {
                try? FileManager.default.removeItem(atPath: stopFile)
                self.log("收到停止信号，正在退出...")
                // 释放所有独占设备
                for device in self.seizedDevices {
                    IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
                }
                self.writeStatus()
                exit(0)
            }

            // 检查是否需要重试 seize
            let hasExternal = self.allDevices.contains { device in
                let p = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
                let t = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
                return !KeyboardManager.isBuiltInKeyboard(product: p, transport: t)
            }
            let hasUnseizedInternal = self.allDevices.contains { device in
                let p = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
                let t = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
                return KeyboardManager.isBuiltInKeyboard(product: p, transport: t) && !self.seizedDevices.contains(device)
            }
            if hasExternal && hasUnseizedInternal {
                self.log("⏰ 心跳: 检测到未独占的内置键盘，重试...")
                self.evaluateAndUpdate()
            }
            self.writeStatus()
        }
    }

    // MARK: - 写入状态文件

    private func writeStatus() {
        let externalNames = allDevices.compactMap { device -> String? in
            let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
            return KeyboardManager.isBuiltInKeyboard(product: product, transport: transport) ? nil : product
        }

        let internalNames = allDevices.compactMap { device -> String? in
            let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
            return KeyboardManager.isBuiltInKeyboard(product: product, transport: transport) ? product : nil
        }

        let status: [String: Any] = [
            "running": true,
            "blocking": !seizedDevices.isEmpty,
            "externalKeyboards": externalNames,
            "internalKeyboards": internalNames,
            "seizedCount": seizedDevices.count,
            "lastUpdate": ISO8601DateFormatter().string(from: Date())
        ]

        if let data = try? JSONSerialization.data(withJSONObject: status, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: statusFilePath))
        }
    }

    // MARK: - 释放所有设备

    func releaseAll() {
        for device in seizedDevices {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        seizedDevices.removeAll()
        log("已释放所有独占的键盘设备")

        // 更新状态文件
        let status: [String: Any] = [
            "running": false,
            "blocking": false,
            "externalKeyboards": [],
            "internalKeyboards": [],
            "seizedCount": 0,
            "lastUpdate": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: status, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: statusFilePath))
        }
    }

    // MARK: - 信号处理

    private func setupSignalHandlers() {
        // 捕获 SIGTERM 和 SIGINT，确保退出前释放键盘
        let handler: @convention(c) (Int32) -> Void = { _ in
            // 写入停止状态
            let status: [String: Any] = [
                "running": false, "blocking": false,
                "externalKeyboards": [], "internalKeyboards": [],
                "seizedCount": 0,
                "lastUpdate": ISO8601DateFormatter().string(from: Date())
            ]
            if let data = try? JSONSerialization.data(withJSONObject: status) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/com.keyboardblocker.daemon.status.json"))
            }
            exit(0)
        }
        signal(SIGTERM, handler)
        signal(SIGINT, handler)
    }

    // MARK: - 日志

    private func openLogFile() {
        // 清空旧日志并打开新文件
        FileManager.default.createFile(atPath: logFilePath, contents: nil)
        logFileHandle = FileHandle(forWritingAtPath: logFilePath)
        logFileHandle?.seekToEndOfFile()
    }

    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] \(message)\n"
        // 写到日志文件
        if logFileHandle == nil { openLogFile() }
        if let data = line.data(using: .utf8) {
            logFileHandle?.write(data)
        }
    }
}
