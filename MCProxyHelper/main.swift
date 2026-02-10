import Cocoa
import SwiftUI

// MARK: - Helper Entry Point (Background Service)

class ServiceApplication: NSApplication {
    let strongDelegate = ServiceAppDelegate()
    
    override init() {
        super.init()
        self.delegate = strongDelegate
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// Global Log Helper
func helperLog(_ message: String) {
    let logPath = (NSHomeDirectory() as NSString).appendingPathComponent("mcproxy_helper.log")
    let timestamp = Date().description
    let entry = "[\(timestamp)] \(message)\n"
    if let data = entry.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logPath) {
            if let fileHandle = FileHandle(forWritingAtPath: logPath) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath))
        }
    }
    // print(message) // stdout might not be visible in service mode, but harmless
}

// Start Application
autoreleasepool {
    helperLog("[MCProxyHelper] Process started.")
    let app = ServiceApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
}

class ServiceAppDelegate: NSObject, NSApplicationDelegate, NSXPCListenerDelegate {
    private var statusItem: NSStatusItem?
    private var xpcListener: NSXPCListener!
    
    // We keep one server manager instance
    private var serverManager: ServerManager!
    
    // We keep track of connected XPC clients (the Main App)
    private var connectedClients: [NSXPCConnection] = []
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        helperLog("[MCProxyHelper] applicationDidFinishLaunching.")
        
        // 1. Setup Menu Bar Icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: "MCProxy Service")
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Management Window", action: #selector(openUI), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit MCProxy Service", action: #selector(quitAll), keyEquivalent: "q"))
        statusItem?.menu = menu
        
        // 2. Start Core Server Manager
        self.serverManager = ServerManager()
        helperLog("[MCProxyHelper] ServerManager initialized.")
        
        // 3. Setup XPC Listener for Management
        // Note: usage of machServiceName requires "MachServices" entry in launchd plist
        xpcListener = NSXPCListener(machServiceName: "com.alick.MCProxy.Helper")
        xpcListener.delegate = self
        xpcListener.resume()
        helperLog("[MCProxyHelper] XPC Listener started on com.alick.MCProxy.Helper.xpc")
        
        // 4. Hook up ServerManager logs to XPC clients
        ServerManager.onLogAppended = { [weak self] (serverId, log) in
            guard let self = self else { return }
            let serverIdStr = serverId.uuidString
            let typeStr = (log.type == .stderr) ? "stderr" : (log.type == .system ? "system" : "stdout")
            
            var rpcIdData: Data? = nil
            if let id = log.rpcId {
                rpcIdData = try? JSONEncoder().encode(id)
            }
            
            for connection in self.connectedClients {
                let client = connection.remoteObjectProxy as? MCProxyClientProtocol
                client?.logAppended(serverId: serverIdStr, message: log.message, type: typeStr, clientName: log.clientName, rpcIdData: rpcIdData)
            }
        }
        
        // 5. Hook up ServerManager status changes to XPC clients
        self.serverManager.onStatusChange = { [weak self] (serverId, status, port) in
             guard let self = self else { return }
             let serverIdStr = serverId.uuidString
             let statusStr = status.rawValue
             
             for connection in self.connectedClients {
                 let client = connection.remoteObjectProxy as? MCProxyClientProtocol
                 client?.serverStatusChanged(serverId: serverIdStr, status: statusStr, port: port)
             }
        }
        
        // 6. Hook up ServerManager client changes to XPC clients
        ServerManager.onClientsChanged = { [weak self] (serverId, names) in
            guard let self = self else { return }
            let serverIdStr = serverId.uuidString
            
            for connection in self.connectedClients {
                let client = connection.remoteObjectProxy as? MCProxyClientProtocol
                client?.clientsChanged(serverId: serverIdStr, names: names)
            }
        }
        
        // 7. Hook up ServerManager tools changes to XPC clients
        ServerManager.onToolsChanged = { [weak self] (serverId, tools) in
            guard let self = self else { return }
            let serverIdStr = serverId.uuidString
            guard let toolsData = try? JSONEncoder().encode(tools) else { return }
            
            for connection in self.connectedClients {
                let client = connection.remoteObjectProxy as? MCProxyClientProtocol
                client?.toolsChanged(serverId: serverIdStr, toolsData: toolsData)
            }
        }
    }
    
    // MARK: - XPC Listener Delegate
    
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        helperLog("[MCProxyHelper] Accepting new XPC connection.")
        
        // Configure the connection
        let exportedObject = MCProxyServiceDelegate(serverManager: self.serverManager)
        newConnection.exportedInterface = NSXPCInterface(with: MCProxyServiceProtocol.self)
        newConnection.exportedObject = exportedObject
        
        let clientInterface = NSXPCInterface(with: MCProxyClientProtocol.self)
        let allowedClasses = NSSet(array: [NSArray.self, NSString.self]) as! Set<AnyHashable>
        clientInterface.setClasses(allowedClasses, for: #selector(MCProxyClientProtocol.clientsChanged(serverId:names:)), argumentIndex: 1, ofReply: false)
        
        newConnection.remoteObjectInterface = clientInterface
        
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            if let conn = newConnection {
                self?.connectedClients.removeAll { $0 === conn }
                helperLog("[MCProxyHelper] XPC connection invalidated.")
            }
        }
        
        newConnection.interruptionHandler = { [weak self, weak newConnection] in
             if let conn = newConnection {
                self?.connectedClients.removeAll { $0 === conn }
                helperLog("[MCProxyHelper] XPC connection interrupted.")
            }
        }
        
        newConnection.resume()
        connectedClients.append(newConnection)
        
        return true
    }
    
    @objc func openUI() {
        // Find the main app bundle
        var appUrl: URL?
        
        // Try different paths to find the main app
        let bundleUrl = Bundle.main.bundleURL
        
        // Method 1: Try to find by going up from helper location
        // Helper could be in: App.app/Contents/MacOS/ or App.app/Contents/Library/LaunchAgents/
        var parentUrl = bundleUrl
        for _ in 0..<5 { // Go up max 5 levels
            parentUrl = parentUrl.deletingLastPathComponent()
            if parentUrl.pathExtension == "app" {
                appUrl = parentUrl
                break
            }
        }
        
        // Method 2: If not found, try using bundle identifier
        if appUrl == nil {
            if let mainAppUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.alick.MCProxy") {
                appUrl = mainAppUrl
            }
        }
        
        if let url = appUrl {
            helperLog("[MCProxyHelper] Opening main app at: \(url.path)")
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { (runningApp, error) in
                if let error = error {
                    helperLog("[MCProxyHelper] Failed to open main app: \(error)")
                } else {
                    helperLog("[MCProxyHelper] Main app opened successfully")
                }
            }
        } else {
            helperLog("[MCProxyHelper] Could not find main app bundle")
        }
    }
    
    @objc func quitAll() {
        helperLog("[MCProxyHelper] Quitting service. Broadcasting exit to \(connectedClients.count) clients.")
        
        // Signal all UI clients to exit
        for connection in connectedClients {
            let client = connection.remoteObjectProxy as? MCProxyClientProtocol
            client?.requestQuit()
        }
        
        // Wait a brief moment for XPC to flush before helper terminates
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }
}

// MARK: - XPC Service Delegate Implementation

class MCProxyServiceDelegate: NSObject, MCProxyServiceProtocol {
    private let serverManager: ServerManager
    
    init(serverManager: ServerManager) {
        self.serverManager = serverManager
    }
    
    func connect(reply: @escaping (String) -> Void) {
        reply("Connected to MCProxyHelper via XPC")
    }
    
    func updateServerList(_ serversData: Data) {
        helperLog("[MCProxyHelper] Received server list update.")
        if let servers = try? JSONDecoder().decode([StdioServerConfig].self, from: serversData) {
            // Smart update: iterate and update/add/remove
            // Use serverManager methods
            
            // 1. Identify removed servers
            let newIds = Set(servers.map { $0.id })
            let currentIds = Set(self.serverManager.servers.map { $0.id })
            
            for id in currentIds {
                if !newIds.contains(id) {
                    self.serverManager.deleteServer(id: id)
                }
            }
            
            // 2. Add or Update
            for config in servers {
                if currentIds.contains(config.id) {
                    self.serverManager.updateServer(config)
                } else {
                    self.serverManager.addServer(config)
                }
            }
        }
    }
    
    func startServer(uuid: String) {
        if let id = UUID(uuidString: uuid) {
            helperLog("[MCProxyHelper] Start server request: \(uuid)")
            self.serverManager.startServer(id: id)
        }
    }
    
    func stopServer(uuid: String) {
        if let id = UUID(uuidString: uuid) {
            helperLog("[MCProxyHelper] Stop server request: \(uuid)")
            self.serverManager.stopServer(id: id)
        }
    }
    
    func requestStatusSync() {
        helperLog("[MCProxyHelper] Requesting status sync for all servers.")
        for (id, instance) in self.serverManager.instances {
            let port = instance.actualPort
            
            // Push current status to all clients
            // In a more complex app, we might want to target only the requester,
            // but for now, broadcasting is fine and simplest.
            ServerManager.onLogAppended?(id, LogEntry(timestamp: Date(), message: "Status synchronized on connection.", type: .system))
            
            // We need a way to trigger the status callback manually or just emit it
            // The ServerManager has onStatusChange closure.
            self.serverManager.onStatusChange?(id, instance.status, port)
            
            // Also sync clients and tools
            let names = instance.bridge?.activeClients.compactMap { $0.name } ?? []
            ServerManager.onClientsChanged?(id, names)
            
            if !instance.config.tools.isEmpty {
                ServerManager.onToolsChanged?(id, instance.config.tools)
            }
        }
    }
    
    func shutdownService() {
        helperLog("[MCProxyHelper] Explicit shutdown request received via XPC.")
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }
}
