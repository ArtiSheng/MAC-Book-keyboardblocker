//
//  DaemonInstaller.swift
//  禁用自带键盘
//
//  管理守护进程的启动和停止
//  启动：通过 .command 文件让 Terminal 执行 sudo，守护进程分离后 Terminal 可关闭
//  停止：写入信号文件，守护进程心跳检测后自动退出（无需 root）
//

import Foundation
import Combine
import AppKit

class DaemonInstaller: ObservableObject {

    static let daemonLabel = "com.keyboardblocker.daemon"
    static let statusFilePath = "/tmp/\(daemonLabel).status.json"
    static let pidFilePath = "/tmp/\(daemonLabel).pid"
    static let logFilePath = "/tmp/\(daemonLabel).log"
    static let stopFilePath = "/tmp/\(daemonLabel).stop"
    static let commandFilePath = "/tmp/\(daemonLabel).command"

    @Published var isInstalled: Bool = false
    @Published var isRunning: Bool = false
    @Published var isBlocking: Bool = false
    @Published var installError: String? = nil
    @Published var password: String = ""

    var hasPassword: Bool { !password.isEmpty }

    private static let passwordKey = "sudo-password"
    private var statusTimer: Timer?

    // MARK: - 密码管理（UserDefaults 明文存储）

    func loadPassword() {
        password = UserDefaults.standard.string(forKey: Self.passwordKey) ?? ""
    }

    func savePassword() {
        if password.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.passwordKey)
        } else {
            UserDefaults.standard.set(password, forKey: Self.passwordKey)
        }
    }

    /// 将密码中的特殊字符转义，用于 shell 脚本
    private var escapedPassword: String {
        password
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "'\\''")
    }

    init() {
        loadPassword()
        checkStatus()
        startStatusPolling()
    }

    deinit {
        statusTimer?.invalidate()
    }

    private func startStatusPolling() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkStatus()
        }
    }

    func checkStatus() {
        // 1. 先通过 PID 文件验证进程是否真的存活
        var processAlive = false
        if let pidStr = try? String(contentsOfFile: Self.pidFilePath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr) {
            let ret = kill(pid, 0)
            if ret == 0 {
                processAlive = true  // 同用户进程，活着
            } else if errno == EPERM {
                processAlive = true  // root 进程，活着但无权限发信号
            }
            // errno == ESRCH → 进程不存在，processAlive 保持 false
        }

        // 2. 进程已死 → 清理文件，标记未运行
        if !processAlive {
            try? FileManager.default.removeItem(atPath: Self.statusFilePath)
            try? FileManager.default.removeItem(atPath: Self.pidFilePath)
            DispatchQueue.main.async {
                self.isInstalled = false
                self.isRunning = false
                self.isBlocking = false
            }
            return
        }

        // 3. 进程活着 → 读取状态文件获取详细信息
        if let data = try? Data(contentsOf: URL(fileURLWithPath: Self.statusFilePath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let running = json["running"] as? Bool ?? false
            let blocking = json["blocking"] as? Bool ?? false
            DispatchQueue.main.async {
                self.isInstalled = true
                self.isRunning = running
                self.isBlocking = blocking
            }
        } else {
            // 进程活着但还没写状态文件
            DispatchQueue.main.async {
                self.isInstalled = true
                self.isRunning = true
                self.isBlocking = false
            }
        }
    }

    // MARK: - 启动守护进程

    func install() {
        guard let execPath = Bundle.main.executablePath else {
            DispatchQueue.main.async { self.installError = "无法获取应用程序路径" }
            return
        }

        // 清理旧的临时文件
        try? FileManager.default.removeItem(atPath: Self.statusFilePath)
        try? FileManager.default.removeItem(atPath: Self.logFilePath)
        try? FileManager.default.removeItem(atPath: Self.pidFilePath)

        // 生成 .command 脚本
        let script: String
        if hasPassword {
            script = """
            #!/bin/bash
            clear
            echo "正在启动守护进程..."
            echo '\(escapedPassword)' | sudo -S sh -c "'\(execPath)' --daemon </dev/null >/dev/null 2>&1 &" 2>/dev/null
            sleep 2
            if [ -f '\(Self.pidFilePath)' ]; then
                PID=$(cat '\(Self.pidFilePath)')
                echo "✅ 守护进程已启动！(PID: $PID)"
            else
                echo "❌ 启动失败，密码可能不正确"
                echo "按任意键关闭..."
                read -n 1
                rm -f "$0"
                exit 1
            fi
            echo "此窗口将在 2 秒后自动关闭..."
            sleep 2
            rm -f "$0"
            osascript -e 'tell application "Terminal" to close front window' &>/dev/null 2>&1
            """
        } else {
            script = """
            #!/bin/bash
            clear
            echo "请输入管理员密码..."
            sudo -v
            if [ $? -ne 0 ]; then
                echo "❌ 认证失败"
                read -n 1
                rm -f "$0"
                exit 1
            fi
            echo "正在启动守护进程..."
            sudo sh -c "'\(execPath)' --daemon </dev/null >/dev/null 2>&1 &"
            sleep 2
            if [ -f '\(Self.pidFilePath)' ]; then
                PID=$(cat '\(Self.pidFilePath)')
                echo "✅ 守护进程已启动！(PID: $PID)"
            else
                echo "✅ 守护进程已启动！"
            fi
            echo "此窗口将在 3 秒后自动关闭..."
            sleep 3
            rm -f "$0"
            osascript -e 'tell application "Terminal" to close front window' &>/dev/null 2>&1
            """
        }

        do {
            try script.write(toFile: Self.commandFilePath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: Self.commandFilePath
            )
        } catch {
            DispatchQueue.main.async {
                self.installError = "脚本创建失败: \(error.localizedDescription)"
            }
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: Self.commandFilePath))
        DispatchQueue.main.async { self.installError = nil }
    }


    func forceKill() {
        let sudoPrefix = hasPassword ? "echo '\(escapedPassword)' | sudo -S" : "sudo"
        let script = """
        #!/bin/bash
        \(hasPassword ? "" : "echo \"请输入管理员密码...\"\nsudo -v\nif [ $? -ne 0 ]; then echo \"❌ 认证失败\"; sleep 2; rm -f \"$0\"; exit 1; fi")
        \(sudoPrefix) launchctl bootout system/com.keyboardblocker.daemon 2>/dev/null
        \(sudoPrefix) rm -f /Library/LaunchDaemons/com.keyboardblocker.daemon.plist 2>/dev/null
        if [ -f '\(Self.pidFilePath)' ]; then
            PID=$(cat '\(Self.pidFilePath)')
            \(sudoPrefix) kill -9 $PID 2>/dev/null
        fi
        \(sudoPrefix) killall -9 禁用自带键盘 2>/dev/null
        rm -f '\(Self.pidFilePath)' '\(Self.statusFilePath)' '\(Self.stopFilePath)'
        echo "✅ 已清理所有守护进程"
        sleep 1
        rm -f "$0"
        osascript -e 'tell application "Terminal" to close front window' &>/dev/null 2>&1
        """

        // 立即删除状态文件并更新 UI，避免轮询读到旧状态
        try? FileManager.default.removeItem(atPath: Self.statusFilePath)
        try? FileManager.default.removeItem(atPath: Self.pidFilePath)
        try? FileManager.default.removeItem(atPath: Self.stopFilePath)
        DispatchQueue.main.async {
            self.isInstalled = false
            self.isRunning = false
            self.isBlocking = false
            self.installError = nil
        }

        do {
            try script.write(toFile: Self.commandFilePath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: Self.commandFilePath
            )
            NSWorkspace.shared.open(URL(fileURLWithPath: Self.commandFilePath))
        } catch {
            DispatchQueue.main.async {
                self.installError = "终止失败: \(error.localizedDescription)"
            }
        }
    }
}
