import AppKit
import GitBrowserCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// One controller per window/tab; each owns an independent repo session.
    private var windowControllers: [MainWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Remove media temp files left behind by a previous crash.
        TempMediaFileManager.shared.sweepAtStartup()

        NSApp.applicationIconImage = AppIcon.make()
        buildMainMenu()

        let controller = makeWindowController()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Optional: open a repository passed on the command line,
        // e.g. `swift run GitBrowser https://github.com/owner/repo`.
        if let initial = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            controller.openRepository(urlString: initial)
        }
    }

    /// Creates and retains a window controller; released when its window closes.
    @discardableResult
    func makeWindowController() -> MainWindowController {
        let controller = MainWindowController()
        windowControllers.append(controller)
        if let window = controller.window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification, object: window
            )
        }
        return controller
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.willCloseNotification, object: window
        )
        windowControllers.removeAll { $0.window === window }
    }

    @objc func newWindow(_ sender: Any?) {
        let controller = makeWindowController()
        controller.showWindow(sender)
        controller.focusURLField(sender)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    // MARK: - Open Recent

    /// Rebuilds the Open Recent submenu each time it is shown.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Open Recent" else { return }
        menu.removeAllItems()
        let recents = RecentRepos.all()
        for urlString in recents {
            let item = NSMenuItem(title: urlString, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = urlString
            menu.addItem(item)
        }
        if recents.isEmpty {
            let empty = NSMenuItem(title: "No Recent Repositories", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecents(_:)), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String else { return }
        let controller = (NSApp.keyWindow?.windowController as? MainWindowController)
            ?? {
                let created = makeWindowController()
                created.showWindow(nil)
                return created
            }()
        controller.openRepository(urlString: urlString)
    }

    @objc private func clearRecents(_ sender: Any?) {
        RecentRepos.clear()
    }

    func applicationWillTerminate(_ notification: Notification) {
        TempMediaFileManager.shared.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About GitBrowser", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit GitBrowser", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let newWindowItem = NSMenuItem(title: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        newWindowItem.target = self
        fileMenu.addItem(newWindowItem)
        fileMenu.addItem(withTitle: "New Tab", action: #selector(NSResponder.newWindowForTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Open Repository…", action: #selector(MainWindowController.focusURLField(_:)), keyEquivalent: "o")
        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let openRecentMenu = NSMenu(title: "Open Recent")
        openRecentMenu.delegate = self
        openRecentItem.submenu = openRecentMenu
        fileMenu.addItem(openRecentItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find…", action: #selector(MainWindowController.showFind(_:)), keyEquivalent: "f")
        editMenu.addItem(withTitle: "Find Next", action: #selector(MainWindowController.findNextInPage(_:)), keyEquivalent: "g")
        let findPrevItem = NSMenuItem(title: "Find Previous", action: #selector(MainWindowController.findPreviousInPage(_:)), keyEquivalent: "g")
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(findPrevItem)
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let goMenuItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")
        goMenu.addItem(withTitle: "Go to File…", action: #selector(MainWindowController.goToFile(_:)), keyEquivalent: "p")
        let searchCodeItem = NSMenuItem(title: "Search Code…", action: #selector(MainWindowController.searchCodeAction(_:)), keyEquivalent: "f")
        searchCodeItem.keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(searchCodeItem)
        goMenu.addItem(withTitle: "File History…", action: #selector(MainWindowController.showHistoryForCurrentFile(_:)), keyEquivalent: "y")
        goMenuItem.submenu = goMenu
        mainMenu.addItem(goMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let toggleSidebarItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(NSSplitViewController.toggleSidebar(_:)),
            keyEquivalent: "s"
        )
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(toggleSidebarItem)
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Reload Page", action: #selector(MainWindowController.reloadPage(_:)), keyEquivalent: "r")
        let refreshItem = NSMenuItem(title: "Refresh Repository", action: #selector(MainWindowController.refreshRepository(_:)), keyEquivalent: "r")
        refreshItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(refreshItem)
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Back", action: #selector(MainWindowController.goBack(_:)), keyEquivalent: "[")
        viewMenu.addItem(withTitle: "Forward", action: #selector(MainWindowController.goForward(_:)), keyEquivalent: "]")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
