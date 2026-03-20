//
//  ContentView.swift
//  禁用自带键盘
//
//  Created by ArtiSheng on 2026/3/19.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var keyboardManager: KeyboardManager
    @EnvironmentObject var daemonInstaller: DaemonInstaller

    var body: some View {
        VStack(spacing: 0) {
            // 顶部状态卡片
            StatusCard()

            Divider()

            // 键盘设备列表
            KeyboardListSection()

            Divider()

            // 底部控制区域
            ControlSection()
        }
        .frame(width: 520)
        .frame(minHeight: 400)
        .background(Color.clear.contentShape(Rectangle()))
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .onAppear {
            keyboardManager.startMonitoring()
            // 启动时不要自动聚焦到密码输入框
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }
}

// MARK: - 状态卡片

struct StatusCard: View {
    @EnvironmentObject var daemonInstaller: DaemonInstaller
    @EnvironmentObject var keyboardManager: KeyboardManager

    var statusColor: Color {
        if daemonInstaller.isBlocking {
            return .orange
        } else if daemonInstaller.isRunning {
            return .green
        } else {
            return .secondary
        }
    }

    var statusText: String {
        if daemonInstaller.isBlocking {
            return "持续屏蔽内置键盘中"
        } else if daemonInstaller.isRunning {
            return "运行中 · 等待外接键盘"
        } else if daemonInstaller.isInstalled {
            return "已启用但未运行"
        } else {
            return "未启用"
        }
    }

    var statusIcon: String {
        if daemonInstaller.isBlocking {
            return "keyboard.badge.ellipsis"
        } else if daemonInstaller.isRunning {
            return "checkmark.shield"
        } else {
            return "shield.slash"
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: statusIcon)
                .font(.system(size: 36))
                .foregroundStyle(statusColor)
                .frame(width: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(statusText)
                    .font(.headline)

                if daemonInstaller.isBlocking {
                    Text("内置键盘已禁用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if daemonInstaller.isRunning {
                    Text("连接外接键盘后将自动禁用内置键盘")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("请先点击下方按钮禁用自带键盘")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(20)
        .background(statusColor.opacity(0.08))
    }
}

// MARK: - 键盘设备列表

struct KeyboardListSection: View {
    @EnvironmentObject var keyboardManager: KeyboardManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已连接的设备")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(keyboardManager.keyboards.count) 个设备")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            if keyboardManager.keyboards.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("未检测到键盘设备")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 20)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(keyboardManager.keyboards.sorted { a, b in
                            if a.isBuiltIn != b.isBuiltIn { return a.isBuiltIn }
                            return a.name < b.name
                        }) { kb in
                            KeyboardRow(keyboard: kb)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
    }
}

// MARK: - 键盘行

struct KeyboardRow: View {
    let keyboard: KeyboardInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: keyboard.typeIcon)
                .font(.system(size: 16))
                .foregroundStyle(keyboard.isBuiltIn ? .orange : .blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(keyboard.name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(keyboard.typeLabel, systemImage: keyboard.isBuiltIn ? "laptopcomputer" : "rectangle.connected.to.line.below")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Label(keyboard.transportLabel, systemImage: "cable.connector")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("ID: \(keyboard.vendorID):\(keyboard.productID)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Text(keyboard.typeLabel)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(keyboard.isBuiltIn ? Color.orange.opacity(0.15) : Color.blue.opacity(0.15))
                .foregroundStyle(keyboard.isBuiltIn ? .orange : .blue)
                .cornerRadius(4)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }
}

// MARK: - 底部控制区域

struct ControlSection: View {
    @EnvironmentObject var daemonInstaller: DaemonInstaller
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if daemonInstaller.isInstalled {
                    Button(action: { daemonInstaller.forceKill() }) {
                        Label("取消禁用自带键盘", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundColor(.white)
                            .background(Color.red)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: { daemonInstaller.install() }) {
                        Label("禁用自带键盘", systemImage: "play.circle")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundColor(.white)
                            .background(Color.accentColor)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let error = daemonInstaller.installError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            // 密码管理区域
            HStack(spacing: 8) {
                SecureField("管理员密码", text: $daemonInstaller.password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .focused($isPasswordFocused)
                    .onChange(of: isPasswordFocused) { focused in
                        if !focused {
                            daemonInstaller.savePassword()
                        }
                    }
                if daemonInstaller.hasPassword {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help("密码已保存，启动/终止时自动填充")
                }
            }
        }
        .padding(16)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            daemonInstaller.savePassword()
        }
    }

}

#Preview {
    ContentView()
        .environmentObject(KeyboardManager())
        .environmentObject(DaemonInstaller())
}
