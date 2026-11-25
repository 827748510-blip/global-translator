import AppKit
import GlobalTranslatorCore

@MainActor
final class DesktopApplicationDelegate: NSObject, NSApplicationDelegate {
    private let controller: ApplicationController
    private let onQuit: @MainActor () -> Void

    init(controller: ApplicationController, onQuit: @escaping @MainActor () -> Void) {
        self.controller = controller
        self.onQuit = onQuit
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.showSettings()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.refreshPermissions()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        onQuit()
        return .terminateCancel // The runner flushes configuration and removes its socket/PID.
    }

    func installMenu(application: NSApplication) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "全局翻译")
        let about = NSMenuItem(title: "关于全局翻译", action: #selector(openAboutPanel), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "全局翻译设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏全局翻译", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let quit = NSMenuItem(title: "退出全局翻译", action: #selector(requestQuit), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"),
                                     ("拷贝", "copy:", "c"), ("粘贴", "paste:", "v"),
                                     ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        application.mainMenu = menu
    }

    @objc private func openAboutPanel() {
        NSApplication.shared.activate()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let credits = NSMutableAttributedString(
            string: "作者：\(AppMetadata.author) · \(AppMetadata.license) 开源协议\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle
            ]
        )
        credits.append(NSAttributedString(
            string: "GitHub 仓库（点 Star 支持）",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .link: AppMetadata.githubRepositoryURL,
                .paragraphStyle: paragraphStyle
            ]
        ))
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "\(AppMetadata.appName)（\(AppMetadata.displayName)）",
            .applicationVersion: AppMetadata.shortVersion,
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "Copyright © 2026 \(AppMetadata.author). All rights reserved."
        ])
    }

    @objc private func openSettings() { controller.showSettings() }
    @objc private func requestQuit() { onQuit() }
}
