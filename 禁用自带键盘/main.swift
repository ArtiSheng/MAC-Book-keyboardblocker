//
//  main.swift
//  禁用自带键盘
//
//  双模式入口：
//  - 无参数启动 → GUI 模式（SwiftUI 窗口）
//  - --daemon 参数 → 守护进程模式（root HID 独占）
//

import SwiftUI

if CommandLine.arguments.contains("--daemon") {
    // 守护进程模式：以 root 运行，负责独占内置键盘
    let daemon = KeyboardDaemon()
    daemon.start()
    RunLoop.main.run()
} else {
    // GUI 模式：显示用户界面
    KeyboardBlockerApp.main()
}
