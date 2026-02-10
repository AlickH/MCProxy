import Foundation
import Combine
#if canImport(AppKit)
import AppKit
#endif

class ServerManager: NSObject, ObservableObject, MCProxyClientProtocol {
    @Published var servers: [StdioServerConfig] = []
    @Published var instances: [UUID: ServerInstance] = [:]
    private var previewInstances: [UUID: ServerInstance] = [:]
    
    // Cross-process log sync
    static var onLogAppended: ((UUID, LogEntry) -> Void)?
    static var onClientsChanged: ((UUID, [String]) -> Void)?
    static var onToolsChanged: ((UUID, [MCPTool]) -> Void)?
    
    private let configKey = "MCProxy.servers"
    private var cancellables = Set<AnyCancellable>()
    
    // Process Mode
    private let isServiceMode: Bool
    
    override init() {
        let processName = ProcessInfo.processInfo.processName
        let isHelper = processName == "MCProxyHelper" || Bundle.main.bundleIdentifier == "com.alick.MCProxy.Helper"
        self.isServiceMode = isHelper || CommandLine.arguments.contains("--service")
        
        super.init()
        
        loadServers()
        
        if isServiceMode {
            print("[ServerManager] Running in SERVICE mode.")
            // Auto-start enabled servers on launch
            for server in servers where server.isEnabled {
                startServer(id: server.id)
            }
        } else {
            print("[ServerManager] Running in UI mode.")
            connectToService()
        }
    }
    
    /// Returns a stable instance for UI preview, creating a dummy one if the server isn't running.
    func instance(for server: StdioServerConfig) -> ServerInstance {
        // 1. Check if we have a running instance from the service
        if let instance = instances[server.id] {
            return instance
        }
        
        // 2. Check or create a preview instance
        if let existing = previewInstances[server.id] {
            // Keep it updated with the latest config
            if existing.config != server {
                existing.config = server
            }
            return existing
        }
        
        let newInstance = ServerInstance(config: server)
        previewInstances[server.id] = newInstance
        return newInstance
    }
    
    // MARK: - XPC Connection (UI Mode)

    private var xpcConnection: NSXPCConnection?

    private func connectToService() {
        let connection = NSXPCConnection(machServiceName: "com.alick.MCProxy.Helper", options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: MCProxyServiceProtocol.self)
        
        let clientInterface = NSXPCInterface(with: MCProxyClientProtocol.self)
        
        // Explicitly set allowed classes for collection types to avoid NSSecureCoding warnings and bad range errors
        let allowedClasses = NSSet(array: [NSArray.self, NSString.self]) as! Set<AnyHashable>
        clientInterface.setClasses(allowedClasses, for: #selector(MCProxyClientProtocol.clientsChanged(serverId:names:)), argumentIndex: 1, ofReply: false)
        
        connection.exportedInterface = clientInterface
        connection.exportedObject = self
        
        connection.resume()
        self.xpcConnection = connection
        
        let service = connection.remoteObjectProxyWithErrorHandler { error in
            print("[ServerManager] create service proxy failed: \(error)")
        } as? MCProxyServiceProtocol
        
        service?.connect { response in
            print("[ServerManager] Connected to service: \(response)")
            // Initial sync: Send current config and request current status
            self.syncConfigToService()
            service?.requestStatusSync()
        }
    }
    
    func quitGlobal() {
        let service = xpcConnection?.remoteObjectProxy as? MCProxyServiceProtocol
        service?.shutdownService()
        
        // Give a small moment for XPC to deliver before killing UI
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }
    
    // MARK: - Config Persistence
    
    func loadServers() {
        if let data = UserDefaults.standard.data(forKey: configKey),
           let decoded = try? JSONDecoder().decode([StdioServerConfig].self, from: data) {
            servers = decoded
        }
    }
    
    func saveServers() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: configKey)
            UserDefaults.standard.synchronize()
            
            if !isServiceMode {
                syncConfigToService()
            }
        }
    }
    
    private func syncConfigToService() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        let service = xpcConnection?.remoteObjectProxy as? MCProxyServiceProtocol
        service?.updateServerList(data)
    }
    
    // MARK: - CRUD
    
    func addServer(_ config: StdioServerConfig) {
        servers.append(config)
        saveServers()
        if isServiceMode && config.isEnabled {
            startServer(id: config.id)
        }
    }
    
    func updateServer(_ config: StdioServerConfig, forceRestart: Bool = false) {
        if let idx = servers.firstIndex(where: { $0.id == config.id }) {
            let oldConfig = servers[idx]
            let hasChanged = oldConfig != config
            
            if !hasChanged && !forceRestart { return }
            
            let wasRunning = instances[config.id]?.status == .running
            let needsRestart = wasRunning && (
                oldConfig.command != config.command ||
                oldConfig.args != config.args ||
                oldConfig.env != config.env ||
                oldConfig.workingDirectory != config.workingDirectory ||
                oldConfig.ssePort != config.ssePort
            )
            
            // In Service mode, handle lifecycle
            if isServiceMode {
                if needsRestart || (wasRunning && !config.isEnabled) {
                    stopServer(id: config.id)
                }
            }
            
            // Merge tools: If the new config has 0 tools but the existing one has some,
            // we assume the UI (which just loaded from disk) is overwriting with empty.
            // We favor the existing tools if they are present.
            var finalConfig = config
            if finalConfig.tools.isEmpty && !oldConfig.tools.isEmpty {
                print("[ServerManager] updateServer: Preserving \(oldConfig.tools.count) existing tools for \(config.name)")
                finalConfig.tools = oldConfig.tools
            }
            
            servers[idx] = finalConfig
            instances[config.id]?.config = finalConfig // Sync current instance
            print("[ServerManager] Updated server \(finalConfig.name) (Tools: \(finalConfig.tools.count))")
            saveServers()
            
            if isServiceMode && finalConfig.isEnabled && (needsRestart || !wasRunning) {
                // If it was already running and didn't need restart, we just updated the config object.
                // But usually we'd only get here if something changed.
                if !wasRunning || needsRestart {
                    startServer(id: config.id)
                }
            }
        }
    }
    
    func deleteServer(id: UUID) {
        if isServiceMode {
            stopServer(id: id)
        }
        servers.removeAll { $0.id == id }
        instances.removeValue(forKey: id)
        saveServers()
    }
    
    func toggleServer(id: UUID) {
        if let idx = servers.firstIndex(where: { $0.id == id }) {
            servers[idx].isEnabled.toggle()
            let isEnabled = servers[idx].isEnabled
            saveServers()
            
            if isServiceMode {
                if isEnabled {
                    startServer(id: id)
                } else {
                    stopServer(id: id)
                }
            } else {
                // Send explicit command if simply syncing config isn't enough (it should be)
                // syncConfigToService covers it.
            }
        }
    }
    
    // MARK: - Client Protocol (Callbacks from Service)
    
    func logAppended(serverId: String, message: String, type: String, clientName: String?, rpcIdData: Data?) {
        guard let uuid = UUID(uuidString: serverId) else { return }
        
        var rpcId: AnyHashable? = nil
        if let data = rpcIdData {
            // Try to decode common ID types
            if let str = try? JSONDecoder().decode(String.self, from: data) {
                rpcId = str
            } else if let int = try? JSONDecoder().decode(Int.self, from: data) {
                rpcId = int
            } else if let double = try? JSONDecoder().decode(Double.self, from: data) {
                rpcId = double
            }
        }
        
        DispatchQueue.main.async {
            // Ensure instance exists in UI
            if self.instances[uuid] == nil {
                if let config = self.servers.first(where: { $0.id == uuid }) {
                    self.instances[uuid] = ServerInstance(config: config)
                }
            }
            
            let logType: LogType = (type == "stderr") ? .stderr : (type == "system" ? .system : .stdout)
            self.instances[uuid]?.appendLog(message, type: logType, clientName: clientName, rpcId: rpcId)
        }
    }
    
    func serverStatusChanged(serverId: String, status: String, port: Int) {
        guard let uuid = UUID(uuidString: serverId) else { return }
        
        DispatchQueue.main.async {
             if self.instances[uuid] == nil {
                if let config = self.servers.first(where: { $0.id == uuid }) {
                    self.instances[uuid] = ServerInstance(config: config)
                }
            }
            
            if let newStatus = ServerStatus(rawValue: status) {
                self.instances[uuid]?.status = newStatus
            }
            self.instances[uuid]?.actualPort = port
        }
    }
    
    func requestQuit() {
        print("[ServerManager] [XPC] Received remote quit request from service.")
        DispatchQueue.main.async {
            // Force terminate immediately without saving state or prompts
            exit(0)
        }
    }
    
    func clientsChanged(serverId: String, names: [String]) {
        guard let uuid = UUID(uuidString: serverId) else { return }
        
        DispatchQueue.main.async {
            if self.instances[uuid] == nil {
                if let config = self.servers.first(where: { $0.id == uuid }) {
                    self.instances[uuid] = ServerInstance(config: config)
                }
            }
            
            // Map names back to ConnectedClient objects for the UI
            DispatchQueue.main.async {
                let currentClients = self.instances[uuid]?.activeClients ?? []
                let currentNames = currentClients.compactMap { $0.name }
                
                // Anti-flicker logic:
                // If the new list is empty but we just had named clients, suppress the update.
                // The Helper's grace period (5s) handles real disconnects eventually.
                if names.isEmpty && !currentNames.isEmpty {
                    print("[ServerManager] [XPC] Flicker suppressed for \(serverId). (Prev: \(currentNames.count), New: 0)")
                    return
                }
                
                // Stability logic: If names are exactly the same, don't recreate the list (avoids UUID churn)
                if names.sorted() == currentNames.sorted() && !names.isEmpty {
                    return
                }
                
                print("[ServerManager] [XPC] [DEBUG] Clients updated for \(serverId): [\(names.joined(separator: ", "))]")
                
                // We create a fresh list of clients from the names.
                // To maintain stability, we TRY to reuse matching names from the current list,
                // but we don't block adding duplicates if the names list has them.
                var newClients: [ConnectedClient] = []
                var remainingCurrent = currentClients
                var reusedCount = 0
                var createdCount = 0
                
                for name in names {
                    if let idx = remainingCurrent.firstIndex(where: { $0.name == name }) {
                        // Reuse existing to preserve ID (stability)
                        newClients.append(remainingCurrent.remove(at: idx))
                        reusedCount += 1
                    } else {
                        // Create new
                        newClients.append(ConnectedClient(id: UUID(), address: "", format: .sse, name: name))
                        createdCount += 1
                    }
                }
                
                print("[ServerManager] [XPC] [DEBUG]   Result: \(newClients.count) clients (\(reusedCount) reused, \(createdCount) new)")
                self.instances[uuid]?.activeClients = newClients
            }
        }
    }
    
    func toolsChanged(serverId: String, toolsData: Data) {
        guard let uuid = UUID(uuidString: serverId) else { return }
        guard let tools = try? JSONDecoder().decode([MCPTool].self, from: toolsData) else { return }
        
        DispatchQueue.main.async {
            // Update instance
            if let instance = self.instances[uuid] {
                var newConfig = instance.config
                newConfig.tools = tools
                instance.config = newConfig
            }
            // Update the source config in the servers list to ensure saves/edits preserve it
            if let index = self.servers.firstIndex(where: { $0.id == uuid }) {
                self.servers[index].tools = tools
            }
        }
    }

    // MARK: - Start / Stop (Service Logic)
    
    func startServer(id: UUID) {
        guard isServiceMode else {
            // In UI mode, sync config triggers Helper to conform.
            let service = xpcConnection?.remoteObjectProxy as? MCProxyServiceProtocol
            service?.startServer(uuid: id.uuidString)
            return
        }
        
        guard let config = servers.first(where: { $0.id == id }),
              config.isEnabled else { return }
        // ... (rest of local startServer logic remains same)
        let instance = ServerInstance(config: config)
        instance.status = .starting
        instances[id] = instance
        
        // Notify clients of status change
        notifyStatusChange(id: id, status: .starting, port: 0)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.launchStdioToSSE(instance: instance)
        }
    }
    
    func stopServer(id: UUID) {
        guard isServiceMode else {
            let service = xpcConnection?.remoteObjectProxy as? MCProxyServiceProtocol
            service?.stopServer(uuid: id.uuidString)
            return
        }
        guard let instance = instances[id] else { return }
        instance.sseTask?.cancel()
        instance.stdioProcess?.terminate()
        instance.stdioProcess = nil
        instance.bridge?.stop()
        instance.bridge = nil
        
        DispatchQueue.main.async {
            instance.status = .stopped
            instance.actualPort = 0
            self.notifyStatusChange(id: id, status: .stopped, port: 0)
        }
    }
    
    func restartServer(id: UUID) {
        stopServer(id: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startServer(id: id)
        }
    }
    
    // Notify clients (XPC) if running as service
    // We need a way to reference client connections.
    // Simplifying: ServerManager in Service Mode acts as the implementation for the XPC calls.
    // The XPC Delegate will forward calls here.
    // But how do we push updates BACK to client?
    // We need to store the client connection in the Service Delegate and call it.
    // For now, let's add a closure hook.
    
    var onStatusChange: ((UUID, ServerStatus, Int) -> Void)?
    
    private func notifyStatusChange(id: UUID, status: ServerStatus, port: Int) {
        onStatusChange?(id, status, port)
    }

    // MARK: - Core Logic (Service Mode Only)
    
    private func launchStdioToSSE(instance: ServerInstance) {
        let config = instance.config
        
        let notifyLog: (String, LogType, String?, AnyHashable?) -> Void = { msg, type, clientName, rpcId in
            instance.appendLog(msg, type: type, clientName: clientName, rpcId: rpcId)
            // Hook for XPC push
             ServerManager.onLogAppended?(instance.id, LogEntry(timestamp: Date(), message: msg, type: type, clientName: clientName, rpcId: rpcId))
        }
        
        notifyLog("Initializing server: \(config.name)", .system, nil, nil)
        
        let port = config.ssePort > 0 ? config.ssePort : findAvailablePort()
        
        if port < 1024 {
            DispatchQueue.main.async {
                instance.status = .error
                instance.errorMessage = "Port \(port) is restricted."
                instance.appendLog("Port \(port) is restricted", type: .stderr)
                self.notifyStatusChange(id: instance.id, status: .error, port: 0)
            }
            return
        }
        
        DispatchQueue.main.async {
            instance.actualPort = port
            self.notifyStatusChange(id: instance.id, status: .starting, port: port)
        }
        
        let components: ProcessComponents
        do {
            components = try ProcessRunner.createProcess(config: config)
        } catch {
            DispatchQueue.main.async {
                instance.status = .error
                instance.errorMessage = "Failed to create process: \(error.localizedDescription)"
                instance.appendLog("Failed to create process: \(error.localizedDescription)", type: .stderr)
                self.notifyStatusChange(id: instance.id, status: .error, port: 0)
            }
            return
        }
        
        let process = components.process
        let stdinPipe = components.stdin
        let stdoutPipe = components.stdout
        let stderrPipe = components.stderr
        
        instance.stdioProcess = process
        if let execPath = process.executableURL?.path {
            instance.appendLog("Starting process: \(execPath)", type: .system)
        }
        
        do {
            try process.run()
            instance.appendLog("Process started with PID: \(process.processIdentifier)", type: .system)
        } catch {
            DispatchQueue.main.async {
                instance.status = .error
                instance.errorMessage = "Failed to start process: \(error.localizedDescription)"
                instance.appendLog("Failed to start process: \(error.localizedDescription)", type: .stderr)
                self.notifyStatusChange(id: instance.id, status: .error, port: 0)
            }
            return
        }
        
        let bridge = MCPSSEBridge()
        instance.bridge = bridge
        
        // Push client changes via XPC
        instance.clientCancellable = bridge.$activeClients
            .dropFirst()
            .sink { clients in
                let names = clients.compactMap { $0.name }
                print("[ServerManager] [Helper] Active clients changed for \(config.name): \(names.count) named clients out of \(clients.count) total.")
                ServerManager.onClientsChanged?(instance.id, names)
            }
        
        bridge.onMessageReceived = { data, connectionId, clientName in
            var rpcId: AnyHashable? = nil
            // Try to record request ID for response tracking
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = json["id"] as? AnyHashable {
                rpcId = id
                bridge.recordRequest(id: id, connectionId: connectionId)
            }
            
            if let str = String(data: data, encoding: .utf8) {
                notifyLog(">>> CLIENT REQUEST:\n\(str)", .system, clientName, rpcId)
            }
            try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
            if data.last != UInt8(ascii: "\n") {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: "\n".data(using: .utf8)!)
            }
        }
        
        do {
            try bridge.start(host: config.sseHost, port: port)
            instance.appendLog("Bridge started on \(config.sseHost):\(port)", type: .system)
        } catch {
            DispatchQueue.main.async {
                instance.status = .error
                instance.appendLog("Failed to start bridge: \(error.localizedDescription)", type: .stderr)
                self.notifyStatusChange(id: instance.id, status: .error, port: 0)
            }
            return
        }

        var stdoutBuffer = Data()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            
            stdoutBuffer.append(data)
            
            // Proper line-by-line parsing with buffer for fragmented data
            while let newlineRange = stdoutBuffer.range(of: Data("\n".utf8)) {
                let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newlineRange.lowerBound)
                stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<newlineRange.upperBound)
                
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                let cleanLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanLine.isEmpty else { continue }
                
                // 3. Sniff for MCP messages
                var identifiedClient: String? = nil
                var rpcId: AnyHashable? = nil
                
                if let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    let idVal = json["id"]
                    let idStr = idVal.map { "\($0)" } ?? ""
                    let idInt = idVal as? Int
                    
                    // Capture ID
                    if let id = idVal as? AnyHashable {
                        rpcId = id
                        // Client Tagging: Attempt to resolve sender name via JSON-RPC ID
                        identifiedClient = bridge.clientName(forId: id)
                    }
                    
                    // A. Handshake result detected?
                    // We check for both our internal IDs and common numeric ones
                    if idStr == "mcproxy-internal-init" || idInt == 1 {
                        if let result = json["result"] as? [String: Any], result["protocolVersion"] != nil {
                            // Internal discovery: trigger tools/list
                            let listTools: [String: Any] = [
                                "jsonrpc": "2.0",
                                "id": (idInt != nil) ? 2 : "mcproxy-internal-list",
                                "method": "tools/list",
                                "params": [:]
                            ]
                            if let listData = try? JSONSerialization.data(withJSONObject: listTools) {
                                var finalData = listData
                                finalData.append("\n".data(using: .utf8)!)
                                try? stdinPipe.fileHandleForWriting.write(contentsOf: finalData)
                            }
                        }
                    }
                    
                    // B. Tools list detected?
                    if let result = json["result"] as? [String: Any],
                       let tools = result["tools"] as? [[String: Any]] {
                        // We accept tool lists from our internal IDs OR common numeric IDs
                        let isInternalResponse = (idStr == "mcproxy-internal-list" || idInt == 2)
                        
                        let mcpTools = tools.enumerated().compactMap { (index, t) -> MCPTool? in
                            guard let name = t["name"] as? String else { return nil }
                            let desc = t["description"] as? String ?? ""
                            
                            var schemaMap: [String: String] = [:]
                            if let inputSchema = t["inputSchema"] as? [String: Any],
                               let properties = inputSchema["properties"] as? [String: Any] {
                                for (key, val) in properties {
                                    if let valObj = val as? [String: Any],
                                       let type = valObj["type"] as? String {
                                        schemaMap[key] = type
                                    } else {
                                        schemaMap[key] = "any"
                                    }
                                }
                            }
                            return MCPTool(id: "\(instance.id.uuidString)-\(name)-\(index)", name: name, description: desc, inputSchema: schemaMap)
                        }
                        
                        if !mcpTools.isEmpty {
                            print("[Tool Discovery] \(instance.config.name) -> Discovered \(mcpTools.count) tools (Internal: \(isInternalResponse))")
                            DispatchQueue.main.async {
                                var newConfig = instance.config
                                newConfig.tools = mcpTools
                                instance.config = newConfig
                                ServerManager.onToolsChanged?(instance.id, mcpTools)
                                self.updateServer(newConfig) 
                            }
                        }
                    }
                }
                
                // 1. Log and notify (with identified client name)
                notifyLog("<<< SERVER RESPONSE:\n\(cleanLine)", .stdout, identifiedClient, rpcId)
                
                // 2. Forward to SSE bridge
                bridge.sendEvent(data: cleanLine)
            }
        }
        
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) {
                notifyLog(str, .stderr, nil, nil)
            }
        }
        
        DispatchQueue.main.async { 
            instance.status = .running 
            self.notifyStatusChange(id: instance.id, status: .running, port: port)
        }
        
        // --- Automatic Tool Discovery ---
        // If tools are empty, trigger a non-blocking internal handshake AFTER a small delay
        // to ensure the process is fully ready for input.
        if instance.config.tools.isEmpty {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                guard instance.status == .running else { return }
                
                instance.appendLog("Auto-discovering tools...", type: .system)
                let initMsg: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": 1, // Use numeric ID to match validation logic "stimulation"
                    "method": "initialize",
                    "params": [
                        "protocolVersion": "2024-11-05",
                        "capabilities": [:],
                        "clientInfo": ["name": "MCProxy-Auto", "version": "1.0.0"]
                    ]
                ]
                if let initData = try? JSONSerialization.data(withJSONObject: initMsg) {
                    var finalData = initData
                    finalData.append("\n".data(using: .utf8)!)
                    try? stdinPipe.fileHandleForWriting.write(contentsOf: finalData)
                }
            }
        }
        // --------------------------------
        
        process.terminationHandler = { proc in
            instance.appendLog("Process terminated with code \(proc.terminationStatus)", type: .system)
            DispatchQueue.main.async { 
                instance.status = .stopped 
                self.notifyStatusChange(id: instance.id, status: .stopped, port: 0)
            }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            instance.bridge?.stop()
            instance.bridge = nil
        }
    }
    
    func validateConfig(_ config: StdioServerConfig) async throws -> [MCPTool] {
        let components: ProcessComponents
        do {
            components = try ProcessRunner.createProcess(config: config)
        } catch {
            throw error
        }
        
        let process = components.process
        let stdinPipe = components.stdin
        let stdoutPipe = components.stdout
        let stderrPipe = components.stderr
        
        return try await withCheckedThrowingContinuation { continuation in
            var outputBuffer = Data()
            var toolsDiscovered: [MCPTool]?
            var hasFinished = false
            
            let cleanup = {
                if !hasFinished {
                    hasFinished = true
                    process.terminate()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                }
            }
            
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                outputBuffer.append(data)
                
                while let str = String(data: outputBuffer, encoding: .utf8), let newlineIndex = str.firstIndex(of: "\n") {
                    let line = String(str[..<newlineIndex]).trimmingCharacters(in: .whitespaces)
                    if let range = str.range(of: "\n") {
                        outputBuffer.removeFirst(str.distance(from: str.startIndex, to: range.upperBound))
                    }
                    
                    guard let lineData = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
                    
                    // 1. Check for Initialized
                    if let result = json["result"] as? [String: Any],
                       json["id"] as? Int == 1 {
                        // Send tools/list
                        let listTools: [String: Any] = [
                            "jsonrpc": "2.0",
                            "id": 2,
                            "method": "tools/list",
                            "params": [:]
                        ]
                        if let listData = try? JSONSerialization.data(withJSONObject: listTools) {
                            var finalData = listData
                            finalData.append("\n".data(using: .utf8)!)
                            try? stdinPipe.fileHandleForWriting.write(contentsOf: finalData)
                        }
                    }
                    
                    // 2. Check for Tools
                    if let result = json["result"] as? [String: Any],
                       let tools = result["tools"] as? [[String: Any]],
                       json["id"] as? Int == 2 {
                        toolsDiscovered = tools.enumerated().compactMap { (index, t) in
                            guard let name = t["name"] as? String else { return nil }
                            let desc = t["description"] as? String ?? ""
                            
                            var schemaMap: [String: String] = [:]
                            if let inputSchema = t["inputSchema"] as? [String: Any],
                               let properties = inputSchema["properties"] as? [String: Any] {
                                for (key, val) in properties {
                                    if let valObj = val as? [String: Any],
                                       let type = valObj["type"] as? String {
                                        schemaMap[key] = type
                                    } else {
                                        schemaMap[key] = "any"
                                    }
                                }
                            }
                            
                            return MCPTool(id: "\(config.id.uuidString)-\(name)-\(index)", name: name, description: desc, inputSchema: schemaMap)
                        }
                        cleanup()
                        continuation.resume(returning: toolsDiscovered ?? [])
                    }
                }
            }
            
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let str = String(data: data, encoding: .utf8) {
                    // print("[Validation Stderr] \(str)") // Silencing noisy validation logs
                }
            }
            
            do {
                try process.run()
                
                // Send initialize
                let initialize: [String: Any] = [
                  "jsonrpc": "2.0",
                  "id": 1,
                  "method": "initialize",
                  "params": [
                    "protocolVersion": "2024-11-05",
                    "capabilities": [:],
                    "clientInfo": ["name": "MCProxy", "version": "1.0.0"]
                  ]
                ]
                let initData = try JSONSerialization.data(withJSONObject: initialize)
                var finalData = initData
                finalData.append("\n".data(using: .utf8)!)
                try stdinPipe.fileHandleForWriting.write(contentsOf: finalData)
                
                // Timeout
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if !hasFinished {
                        cleanup()
                        continuation.resume(throwing: NSError(domain: "ServerManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Validation timed out after 5s"]))
                    }
                }
            } catch {
                cleanup()
                continuation.resume(throwing: error)
            }
        }
    }
    
    private func findAvailablePort() -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketFD >= 0 else { return 8080 }
        defer { close(socketFD) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY
        var addrCopy = addr
        _ = withUnsafePointer(to: &addrCopy) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        var boundAddr = sockaddr_in()
        _ = withUnsafeMutablePointer(to: &boundAddr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &addrLen) } }
        return Int(UInt16(bigEndian: boundAddr.sin_port))
    }
}

// MARK: - XPC Protocol Definitions

/// Protocol for the Service (Helper)
@objc protocol MCProxyServiceProtocol {
    /// Ping/Connect
    func connect(reply: @escaping (String) -> Void)
    
    /// Update list of servers to manage (sent from UI to Helper)
    /// - Parameter serversData: JSON encoded [StdioServerConfig]
    func updateServerList(_ serversData: Data)
    
    /// Start a specific server by UUID
    func startServer(uuid: String)
    
    /// Stop a specific server by UUID
    func stopServer(uuid: String)
    
    /// Request current status for all servers (to sync UI)
    func requestStatusSync()
    
    /// Shut down the service (explicit quit)
    func shutdownService()
}

/// Protocol for the Client (Main App) - Callbacks
@objc protocol MCProxyClientProtocol {
    /// Log received from a managed server
    func logAppended(serverId: String, message: String, type: String, clientName: String?, rpcIdData: Data?)
    
    /// Server status changed
    func serverStatusChanged(serverId: String, status: String, port: Int)
    
    /// List of connected MCP clients changed
    func clientsChanged(serverId: String, names: [String])
    
    /// Available tools list changed
    /// - Parameter toolsData: JSON encoded [MCPTool]
    func toolsChanged(serverId: String, toolsData: Data)
    
    /// Request the UI process to terminate
    func requestQuit()
}

// MARK: - Process Runner Helper

struct ProcessComponents {
    let process: Process
    let stdin: Pipe
    let stdout: Pipe
    let stderr: Pipe
}

class ProcessRunner {
    static func resolveCommandPath(_ command: String) -> URL? {
        if command.hasPrefix("/") || command.hasPrefix(".") {
            let url = URL(fileURLWithPath: (command as NSString).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        let commonPaths = ["/usr/local/bin", "/usr/bin", "/bin", "/opt/homebrew/bin"]
        for path in commonPaths {
            let fullPath = (path as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: fullPath) { return URL(fileURLWithPath: fullPath) }
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }
    
    static func createProcess(config: StdioServerConfig) throws -> ProcessComponents {
        guard let executableURL = resolveCommandPath(config.command) else {
            throw NSError(domain: "ProcessRunner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Command not found: \(config.command)"])
        }
        
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        
        process.executableURL = executableURL
        process.arguments = config.args
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        var environment = ProcessInfo.processInfo.environment
        let commonPaths = ["/usr/local/bin", "/usr/bin", "/bin", "/opt/homebrew/bin"]
        let currentPath = environment["PATH"] ?? ""
        environment["PATH"] = (commonPaths + [currentPath]).joined(separator: ":")
        for (k, v) in config.env { environment[k] = v }
        process.environment = environment
        
        if let cwd = config.workingDirectory, !cwd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
        }
        
        return ProcessComponents(process: process, stdin: stdinPipe, stdout: stdoutPipe, stderr: stderrPipe)
    }
}


