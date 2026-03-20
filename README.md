<p align="center">
  <img src="图片/AppIcon.png" width="128" height="128" alt="App Icon">
</p>

<h1 align="center">Mac 禁用自带键盘</h1>

<p align="center">
  在外接键盘时禁用 MacBook 内置键盘，防止误触
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-blue?logo=apple" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-5.9+-orange?logo=swift" alt="Swift">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
</p>

---

## ✨ 功能特性

- 🔒 **一键禁用内置键盘** — 通过 IOKit HID 设备独占（Seize）机制，从驱动层面屏蔽内置键盘输入
- 🖥️ **实时设备监控** — 自动检测并显示所有已连接的设备，区分内置/外接
- 🛡️ **守护进程模式** — 以 root 权限运行后台守护进程，通过终端脚本实现安全的权限提升
- 🔄 **心跳状态监控** — 守护进程定期写入状态文件，GUI 实时反映运行状态
- 💾 **密码自动保存** — 管理员密码本地存储，启动/停止守护进程时自动填充，无需反复输入
- 🎯 **精准进程管理** — 使用 `kill(pid, 0)` + `errno` 检查精准判断进程存活状态

## 📸 截图

| 未启用 | 已启用 |
|:---:|:---:|
| ![未启用](图片/未启用.png) | ![启用](图片/启用.png) |

## 🔧 工作原理

1. **设备发现** — 通过 `IOHIDManager` 监听 HID 设备的连接和断开事件
2. **内置键盘识别** — 根据产品名（`Apple Internal`）和传输协议（`FIFO`/`SPI`）判断是否为内置键盘
3. **设备独占** — 使用 `kIOHIDOptionsTypeSeizeDevice` 标志独占内置键盘，使其事件不再传递给系统
4. **守护进程** — 通过生成 `.command` 脚本并在 Terminal.app 中执行，绕过 TCC 沙箱限制，以 root 权限运行后台守护进程

```
┌─────────────┐     Terminal.app      ┌──────────────────┐
│  GUI App    │ ──── .command ────▶   │  Daemon (root)   │
│  (用户态)    │     sudo 提权         │  IOKit HID Seize │
└─────────────┘                       └──────────────────┘
       │                                      │
       │  读取状态文件                          │  写入状态文件
       ▼                                      ▼
  /tmp/com.keyboardblocker.daemon.status.json
  /tmp/com.keyboardblocker.daemon.pid
```

## 📦 安装

### 从源码构建

```bash
# 克隆仓库
git clone https://github.com/YOUR_USERNAME/MAC禁用自带键盘.git
cd MAC禁用自带键盘

# 使用 Xcode 打开项目
open 禁用自带键盘/禁用自带键盘/禁用自带键盘.xcodeproj

# 或使用命令行构建
cd 禁用自带键盘/禁用自带键盘
xcodebuild -project 禁用自带键盘.xcodeproj -scheme 禁用自带键盘 -configuration Release build
```

### 系统要求

- macOS 13.0 (Ventura) 或更高版本
- 需要管理员密码（sudo 权限）用于守护进程提权

## 🚀 使用方法

1. **启动应用** — 打开「禁用自带键盘.app」
2. **输入密码** — 在底部密码框输入管理员密码（点击其他区域自动保存，下次无需重复输入）
3. **禁用自带键盘** — 点击「禁用自带键盘」按钮，终端窗口会弹出执行 sudo 命令
4. **取消禁用** — 点击「取消禁用自带键盘」按钮即可恢复内置键盘

## 📁 项目结构

```
禁用自带键盘/
├── main.swift              # 应用入口，启动 NSApplication
├── ______App.swift         # SwiftUI App 定义
├── ContentView.swift       # 主界面 UI（状态卡片、设备列表、控制区域）
├── KeyboardManager.swift   # IOKit HID 设备监控管理器
├── KeyboardDaemon.swift    # 守护进程核心逻辑（设备独占/释放）
├── DaemonInstaller.swift   # 守护进程安装/卸载/状态管理
└── Assets.xcassets/        # 应用资源（图标等）
```

## ⚠️ 注意事项

- 禁用内置键盘需要 **root 权限**，应用会通过终端执行 `sudo` 命令
- 管理员密码以 **明文** 存储在 `UserDefaults` 中，仅限本机使用，请勿在共享设备上使用
- 如果守护进程异常退出，可以在终端手动执行 `sudo pkill -f KeyboardDaemon` 恢复键盘
- 应用需要 **辅助功能权限**（系统偏好设置 → 隐私与安全性 → 辅助功能）

## 📄 开源许可

本项目采用 **GNU 通用公共许可证 v3.0（GPLv3）** 许可证。这意味着您可以自由使用、修改和分发本软件，但是：

- 任何基于本软件的衍生作品必须以相同的许可证发布
- 必须保留原始版权声明
- 您必须明确说明您对原始代码所做的任何更改

详细许可条款请参阅项目根目录下的 [LICENSE](LICENSE) 文件。

## 📞 联系方式

如有任何问题或建议，欢迎通过以下方式联系：

- **GitHub Issues**：[提交问题](https://github.com/ArtiSheng/MAC-Book-/issues)
- **电子邮件**：cc@artisheng.vip
- **QQ**：3447478882
