import Cocoa
import SwiftUI
import ServiceManagement
import Foundation

// MARK: - UI Entry Point (Main Process)

autoreleasepool {
    print("[MCProxy] Starting UI Process...")
    
    // 1. Ensure background helper service is running
    ServiceLauncher.ensureServiceIsRunning()
    
    // 2. Run as Regular App (Dock + Window)
    let app = NSApplication.shared
    let delegate = UIAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    
    // 3. Setup Menu Bar
    let mainMenu = NSMenu()
    
    // App Menu
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenuItem.submenu = appMenu
    appMenu.addItem(withTitle: "About MCProxy", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(withTitle: "Preferences...", action: nil, keyEquivalent: ",")
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(withTitle: "Hide MCProxy", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(hideOthers)
    appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(withTitle: "Quit MCProxy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    
    // Edit Menu (Critical for Copy/Paste)
    let editMenuItem = NSMenuItem()
    mainMenu.addItem(editMenuItem)
    let editMenu = NSMenu(title: "Edit")
    editMenuItem.submenu = editMenu
    editMenu.addItem(withTitle: "Undo", action: Selector("undo:"), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector("redo:"), keyEquivalent: "Z")
    editMenu.addItem(NSMenuItem.separator())
    editMenu.addItem(withTitle: "Cut", action: Selector("cut:"), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: Selector("copy:"), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: Selector("paste:"), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: Selector("selectAll:"), keyEquivalent: "a")
    
    // Window Menu
    let windowMenuItem = NSMenuItem()
    mainMenu.addItem(windowMenuItem)
    let windowMenu = NSMenu(title: "Window")
    windowMenuItem.submenu = windowMenu
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
    windowMenu.addItem(NSMenuItem.separator())
    windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    
    // Help Menu
    let helpMenuItem = NSMenuItem()
    mainMenu.addItem(helpMenuItem)
    let helpMenu = NSMenu(title: "Help")
    helpMenuItem.submenu = helpMenu
    helpMenu.addItem(withTitle: "MCProxy Help", action: nil, keyEquivalent: "?")

    app.mainMenu = mainMenu
    
    app.run()
}

// MARK: - Delegates

class UIAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        createWindow()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true // Exit app when window is closed (simplest approach)
    }
    
    private func createWindow() {
        let serverManager = ServerManager()
        let contentView = ContentView().environmentObject(serverManager)
        
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window?.center()
        window?.title = "MCProxy"
        window?.contentView = NSHostingView(rootView: contentView)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Service Launcher

class ServiceLauncher {
    static func ensureServiceIsRunning() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.agent(plistName: "com.alick.MCProxy.Helper.plist")
            print("[MCProxy] Helper service status: \(service.status)")
            
            // First, try to check if helper is actually running via XPC
            let isRunning = checkIfHelperIsRunning()
            
            if isRunning {
                print("[MCProxy] Helper process is already running. No action needed.")
                return
            }
            
            // Helper is not running, need to start it
            print("[MCProxy] Helper process not detected. Starting...")
            
            switch service.status {
            case .enabled:
                // Service is enabled but not running, re-register to start it
                print("[MCProxy] Service enabled but not running. Re-registering to start...")
                do {
                    try service.unregister()
                    try service.register()
                    print("[MCProxy] Helper service restarted successfully.")
                } catch {
                    print("[MCProxy] Failed to restart service: \(error)")
                }
                
            case .notRegistered, .notFound:
                print("[MCProxy] Service not registered. Registering...")
                do {
                    try service.register()
                    print("[MCProxy] Helper service registered successfully.")
                } catch {
                    print("[MCProxy] Failed to register service: \(error)")
                }
                
            case .requiresApproval:
                print("[MCProxy] Service requires approval in Settings -> General -> Login Items.")
                SMAppService.openSystemSettingsLoginItems()
                print("[MCProxy] Opened System Settings for approval.")
                
            @unknown default:
                print("[MCProxy] Unknown service status: \(service.status)")
            }
        } else {
            // Fallback to manual launch if on older macOS
            let helperUrl = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MCProxyHelper")
            let task = Process()
            task.executableURL = helperUrl
            try? task.run()
        }
    }
    
    private static func checkIfHelperIsRunning() -> Bool {
        // Check if MCProxyHelper process is running using pgrep (faster, no blocking)
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-x", "MCProxyHelper"]
        
        do {
            try task.run()
            // pgrep returns 0 if process found, non-zero if not found
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            print("[MCProxy] Failed to check helper process: \(error)")
            return false
        }
    }
}
