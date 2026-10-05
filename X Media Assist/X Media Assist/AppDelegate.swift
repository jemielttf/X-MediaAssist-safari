//
//  AppDelegate.swift
//  X Media Assist
//
//  Created by jemielttf on 2026/09/21.
//

import Cocoa
import ServiceManagement

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let preferences = AppPreferences()
    private var statusItem: NSStatusItem?
    // Retain the storyboard controller so closing and reopening uses one window.
    private var mainWindowController: NSWindowController?
    private var dockMenuItem: NSMenuItem!
    private var loginMenuItem: NSMenuItem!
    private var approvalMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainWindowController = NSApp.windows.first { $0.contentViewController is ViewController }?.windowController
        configureStatusItem()
        applyDockVisibility()
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.eventID == kAEOpenApplication,
           event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            mainWindowController?.window?.orderOut(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = Bundle.main.url(forResource: "X-Media-Assist_toolbar-icon", withExtension: "svg")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: "X Media Assist")
        icon?.size = NSSize(width: 22, height: 22)
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.toolTip = "X Media Assist"
        item.button?.setAccessibilityLabel("X Media Assist")

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(makeMenuItem(AppLocalization.string("menu_open"), action: #selector(showMainWindow)))
        menu.addItem(.separator())
        dockMenuItem = makeMenuItem(AppLocalization.string("menu_hide_dock"), action: #selector(toggleDockVisibility))
        menu.addItem(dockMenuItem)
        loginMenuItem = makeMenuItem(AppLocalization.string("menu_launch_at_login"), action: #selector(toggleLaunchAtLogin))
        menu.addItem(loginMenuItem)
        approvalMenuItem = makeMenuItem(AppLocalization.string("menu_login_settings"), action: #selector(openLoginSettings))
        menu.addItem(approvalMenuItem)
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(AppLocalization.string("menu_quit"), action: #selector(quitApplication)))
        item.menu = menu
        statusItem = item
        updateMenu()
    }

    private func makeMenuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) { updateMenu() }

    private func updateMenu() {
        dockMenuItem.state = NSApp.activationPolicy() == .accessory ? .on : .off
        let status = preferences.loginItemStatus
        loginMenuItem.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
        loginMenuItem.title = status == .requiresApproval ? AppLocalization.string("menu_login_pending") : AppLocalization.string("menu_launch_at_login")
        approvalMenuItem.isHidden = status != .requiresApproval
    }

    @objc private func showMainWindow() {
        if mainWindowController == nil {
            mainWindowController = NSStoryboard(name: "Main", bundle: nil).instantiateInitialController() as? NSWindowController
        }
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func applyDockVisibility() {
        if !NSApp.setActivationPolicy(preferences.hidesDockIcon ? .accessory : .regular) {
            NSLog("X Media Assist could not apply the saved Dock visibility setting.")
        }
        updateMenu()
    }

    @objc private func toggleDockVisibility() {
        let hidden = NSApp.activationPolicy() != .accessory
        let applied = preferences.setHidesDockIcon(hidden) {
            NSApp.setActivationPolicy($0 ? .accessory : .regular)
        }
        if !applied {
            let alert = NSAlert()
            alert.messageText = AppLocalization.string("dock_error")
            alert.addButton(withTitle: "OK")
            NSApp.activate()
            alert.runModal()
        }
        updateMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        let status = preferences.loginItemStatus
        do {
            try preferences.setLaunchAtLogin(status != .enabled && status != .requiresApproval)
        } catch {
            let alert = NSAlert()
            alert.messageText = AppLocalization.string("login_error")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            NSApp.activate()
            alert.runModal()
        }
        updateMenu()
    }

    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func quitApplication() { NSApp.terminate(nil) }
}
