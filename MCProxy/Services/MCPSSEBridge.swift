import Foundation
import Network
import Combine

enum ResponseFormat: Sendable {
    case sse
    case raw
}

struct ConnectedClient: Identifiable {
    let id: UUID
    let address: String
    let format: ResponseFormat
    let name: String?
}

class MCPSSEBridge: ObservableObject {
    @Published var activeClients: [ConnectedClient] = []
    
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var sseClients: [UUID: NWConnection] = [:] // Streaming clients (GET / or Streamable POST)
    private var postConnections: Set<UUID> = [] // Waiting for single response (POST / sync)
    private var connectionBuffers: [UUID: Data] = [:]
    
    private var clientFormats: [UUID: ResponseFormat] = [:]
    private var clientNames: [UUID: String] = [:]
    private var sessionNames: [String: String] = [:] // Persistent names per session ID
    private var sseConnectionBySessionID: [String: UUID] = [:] // sessionId -> active SSE connectionId
    private var sessionLastSeen: [String: Date] = [:] // sessionId -> last activity time
    private var sessionInitialized: [String: Bool] = [:] // sessionId -> has completed handshake
    private var connectionIdToSessionId: [UUID: String] = [:] // physical connection -> logical session
    
    // Request Tracking
    private var pendingRequests: [AnyHashable: UUID] = [:] // JSON-RPC id -> connectionId
    private var idToSessionId: [AnyHashable: String] = [:] // JSON-RPC id -> session ID
    
    // Callbacks
    var onMessageReceived: ((Data, UUID, String?) -> Void)?
    
    private let queue = DispatchQueue(label: "com.mcp.sse-bridge")
    private var currentHost: String = "127.0.0.1"
    private var currentPort: Int = 3001
    private let maxBufferSize = 10 * 1024 * 1024 // 10MB limit
    
    func start(host: String, port: Int) throws {
        self.currentHost = host
        self.currentPort = port
        let parameters = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "MCPSSEBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
        }
        
        listener = try NWListener(using: parameters, on: nwPort)
        
        listener?.stateUpdateHandler = { state in
            print("[MCPSSEBridge] Listener state: \(state)")
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        
        listener?.start(queue: queue)
        print("[MCPSSEBridge] Started native SSE bridge on \(host):\(port)")
    }
    
    func stop() {
        listener?.cancel()
        queue.sync {
            for (_, conn) in connections {
                conn.cancel()
            }
            connections.removeAll()
            sseClients.removeAll()
            postConnections.removeAll()
            clientFormats.removeAll()
            connectionBuffers.removeAll()
        }
        print("[MCPSSEBridge] Stopped native SSE bridge")
    }
    
    func sendEvent(data: String) {
        queue.async {
            // Attempt to route based on JSON-RPC ID tracking
            var targetConnId: UUID? = nil
            var targetSessId: String? = nil
            
            if let jsonData = data.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                if let id = json["id"] as? AnyHashable {
                    targetConnId = self.pendingRequests[id]
                    targetSessId = self.idToSessionId[id]
                    // Cleanup mappings after routing
                    self.pendingRequests.removeValue(forKey: id)
                    self.idToSessionId.removeValue(forKey: id)
                }
            }
            
            // 1. Route to Connection (Sync or Stream)
            if let connId = targetConnId, let conn = self.connections[connId] {
                if self.postConnections.contains(connId) {
                    // Sync Response (FlowDown)
                    print("[MCPSSEBridge] Sending single response to POST connection \(connId)")
                    self.sendSingleResponse(conn, data: data)
                    self.postConnections.remove(connId)
                } else {
                    // Stream Response (Another Client / SSE)
                    print("[MCPSSEBridge] Routing ID-matched response to stream \(connId)")
                    self.sendFormattedEvent(conn, data: data, id: connId)
                }
            } 
            // 2. Route to Session (Standard SSE)
            else if let sessId = targetSessId {
                print("[MCPSSEBridge] Routing ID-matched response to session \(sessId)")
                for (id, conn) in self.sseClients {
                    if id.uuidString.lowercased() == sessId.lowercased() {
                        self.sendFormattedEvent(conn, data: data, id: id)
                        return
                    }
                }
            } 
            // 3. Broadcast (Notifications)
            else {
                let clients = self.sseClients
                if !clients.isEmpty {
                    print("[MCPSSEBridge] Broadcasting to \(clients.count) stream(s)")
                    for (id, conn) in clients {
                        self.sendFormattedEvent(conn, data: data, id: id)
                    }
                }
            }
        }
    }
    
    private func sendFormattedEvent(_ conn: NWConnection, data: String, id: UUID) {
        let format = clientFormats[id] ?? .raw
        var outputData: Data?
        
        switch format {
        case .sse:
            let sseFormatted = "event: message\ndata: \(data)\n\n"
            outputData = sseFormatted.data(using: .utf8)
        case .raw:
            let rawFormatted = data + "\n"
            outputData = rawFormatted.data(using: .utf8)
        }
        
        if let outputData = outputData {
            self.sendToConnection(conn, data: outputData, id: id)
        }
    }
    
    private func sendSingleResponse(_ conn: NWConnection, data: String) {
        guard let bodyData = data.data(using: .utf8) else { return }
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/json",
            "Content-Length: \(bodyData.count)",
            "Access-Control-Allow-Origin: *",
            "Connection: close",
            "\r\n"
        ].joined(separator: "\r\n")
        
        conn.send(content: headers.data(using: .utf8), completion: .contentProcessed({ _ in
            conn.send(content: bodyData, completion: .contentProcessed({ _ in
                conn.cancel()
            }))
        }))
    }
    
    private func sendToConnection(_ conn: NWConnection, data: Data, id: UUID) {
        // Wrap data in HTTP chunk format
        let count = data.count
        let hexCount = String(count, radix: 16)
        var chunkData = Data()
        chunkData.append((hexCount + "\r\n").data(using: .utf8)!)
        chunkData.append(data)
        chunkData.append("\r\n".data(using: .utf8)!)
        
        conn.send(content: chunkData, completion: .contentProcessed({ error in
            if let error = error {
                print("[MCPSSEBridge] [\(id)] Send failed: \(error)")
                self.removeClient(id)
            }
        }))
    }
    
    private func cleanClientName(_ name: String) -> String {
        let lowerName = name.lowercased()
        
        // Prioritize known app names even if they are inside a browser UA
        if lowerName.contains("chatwise") { return "ChatWise" }
        if lowerName.contains("flowdown") { return "FlowDown" }
        if lowerName.contains("claude") { return "Claude" }
        
        // Handle common UA patterns: "FlowDown/572 CFNetwork/..." -> "FlowDown"
        if name.contains("/") {
            let parts = name.split(separator: "/")
            let firstPart = String(parts.first ?? "").trimmingCharacters(in: .whitespaces)
            
            // If it's a browser, keep it as is or simplify
            if firstPart.contains("Mozilla") { 
                // Look for common tokens in the middle
                if lowerName.contains("chrome") { return "Chrome" }
                if lowerName.contains("safari") && !lowerName.contains("chrome") { return "Safari" }
                if lowerName.contains("firefox") { return "Firefox" }
                return "Browser" 
            }
            return firstPart
        }
        
        // Handle bundle IDs: "wiki.qaq.flow" -> "Flow"
        if name.contains(".") && name.split(separator: ".").count >= 2 {
            let parts = name.split(separator: ".")
            let last = String(parts.last ?? "")
            return last.isEmpty ? name : last.capitalized
        }
        
        return name
    }
    
    private func updateActiveClients() {
        var logicalClients: [String: ConnectedClient] = [:] // Keyed by Session ID (sKey)
        
        let allConnectionIds = Array(self.connections.keys)
        print("[MCPSSEBridge] [DEBUG] Total connections: \(allConnectionIds.count)")
        
        for id in allConnectionIds {
            guard let conn = self.connections[id] else { continue }
            let addr = conn.endpoint.debugDescription
            let format = self.clientFormats[id] ?? .raw
            let _ = self.postConnections.contains(id)
            
            // Use the mapped Session ID if available, otherwise fallback to connection ID
            let sKey = self.connectionIdToSessionId[id] ?? id.uuidString.lowercased()
            
            // Name detection priority: 
            // 1. Sticky session name (highly specific, e.g., ChatWise)
            // 2. Explicitly set name for THIS connection (e.g., initial UA)
            var name = self.sessionNames[sKey] ?? self.clientNames[id]
            
            // If the current connection has a name but we have a better session name, favor the session one
            func isGeneric(_ n: String) -> Bool {
                let lower = n.lowercased()
                return lower.contains("browser") || lower.contains("mozilla") || lower.contains("safari") || lower.contains("chrome")
            }
            
            if let n = name, isGeneric(n), let sName = self.sessionNames[sKey], !isGeneric(sName) {
                name = sName
            }
            
            let finalName = name.map { cleanClientName($0) }
            let client = ConnectedClient(id: id, address: addr, format: format, name: finalName)
            
            print("[MCPSSEBridge] [DEBUG]   ID: \(id.uuidString.prefix(4))... sKey: \(sKey.prefix(4))... Name: \(finalName ?? "nil") (\(format))")
            
            // Only merge based on Session ID (sKey). 
            // Do NOT merge based on name, as multiple clients might have the same generic name (e.g. "Browser").
            if let existing = logicalClients[sKey] {
                // If we already have this session, merge/update it.
                // Prefer SSE over POST, and prefer stronger names.
                if existing.format != .sse && format == .sse {
                    logicalClients[sKey] = client
                } else if let n = finalName, let exN = existing.name, isGeneric(exN) && !isGeneric(n) {
                    logicalClients[sKey] = client
                }
            } else {
                logicalClients[sKey] = client
            }
        }
        
        // Add "Recently Active" sessions (Grace period)
        let now = Date()
        for (sKey, lastSeen) in sessionLastSeen {
            let isInitialized = sessionInitialized[sKey] ?? false
            // Extend grace period to 1 hour for initialized clients to support "verify-then-idle" behavior
            let gracePeriod: TimeInterval = isInitialized ? 3600.0 : 5.0
            
            if logicalClients[sKey] == nil && now.timeIntervalSince(lastSeen) < gracePeriod {
                if let n = sessionNames[sKey] {
                    let suffix = isInitialized ? " (Idle)" : ""
                    let finalName = cleanClientName(n) + suffix
                    print("[MCPSSEBridge] [DEBUG]   Idle: \(sKey.prefix(4))... Name: \(finalName)")
                    logicalClients[sKey] = ConnectedClient(
                        id: UUID(uuidString: sKey) ?? UUID(),
                        address: "(inactive)",
                        format: .raw,
                        name: finalName
                    )
                }
            }
        }

        let sortedClients = Array(logicalClients.values).sorted { ($0.name ?? "") < ($1.name ?? "") }
        let nameSummary = sortedClients.map { "\($0.name ?? "unnamed")" }.joined(separator: ", ")
        print("[MCPSSEBridge] [DEBUG] UI List: [\(nameSummary)]")
        
        DispatchQueue.main.async {
            self.activeClients = sortedClients
        }
    }
    
    func clientName(forId id: AnyHashable) -> String? {
        return queue.sync {
            guard let sessId = idToSessionId[id] else { return nil }
            return sessionNames[sessId]
        }
    }
    
    func clientName(forConnectionId id: UUID) -> String? {
        return queue.sync {
            return clientNames[id]
        }
    }
    
    func recordRequest(id: AnyHashable, connectionId: UUID) {
        queue.async {
            self.pendingRequests[id] = connectionId
            if let sessId = self.connectionIdToSessionId[connectionId] {
                self.idToSessionId[id] = sessId
            }
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        let connectionId = UUID()
        connections[connectionId] = connection
        connectionBuffers[connectionId] = Data()
        connection.start(queue: queue)
        receiveNextMessage(connection, connectionId: connectionId)
        updateActiveClients()
    }
    
    private func receiveNextMessage(_ connection: NWConnection, connectionId: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            
            if let data = content, !data.isEmpty {
                self.queue.async {
                    self.connectionBuffers[connectionId]?.append(data)
                    self.processBuffer(connectionId: connectionId)
                }
            }
            
            if isComplete {
                self.removeClient(connectionId)
            } else if let error = error {
                print("[MCPSSEBridge] [\(connectionId)] Connection error: \(error)")
                self.removeClient(connectionId)
            } else {
                self.receiveNextMessage(connection, connectionId: connectionId)
            }
        }
    }
    
    private func processBuffer(connectionId: UUID) {
        guard let data = connectionBuffers[connectionId], !data.isEmpty else { return }
        guard let connection = connections[connectionId] else { return }
        
        // Safety Limit
        if data.count > maxBufferSize {
            print("[MCPSSEBridge] [\(connectionId)] Max buffer size exceeded. Closing connection.")
            removeClient(connectionId)
            return
        }
        
        // SSL Detection
        if data.count >= 3 && data[0] == 0x16 && data[1] == 0x03 {
            print("[MCPSSEBridge] [\(connectionId)] Warning: Binary data detected (looks like HTTPS/TLS).")
            removeClient(connectionId)
            return
        }
        
        // Try to find end of headers
        let headerEndData = "\r\n\r\n".data(using: .utf8)!
        guard let headerEndRange = data.range(of: headerEndData) else {
            if let altRange = data.range(of: "\n\n".data(using: .utf8)!) {
                processBufferWithHeaderEnd(altRange, connectionId: connectionId, connection: connection)
            }
            return 
        }
        
        processBufferWithHeaderEnd(headerEndRange, connectionId: connectionId, connection: connection)
    }

    private func processBufferWithHeaderEnd(_ headerEndRange: Range<Data.Index>, connectionId: UUID, connection: NWConnection) {
        guard let data = connectionBuffers[connectionId] else { return }
        
        let headerData = data[..<headerEndRange.lowerBound]
        guard let headerStr = String(data: headerData, encoding: .utf8) else {
            print("[MCPSSEBridge] [\(connectionId)] Error: Non-UTF8 headers, clearing buffer.")
            connectionBuffers[connectionId] = Data()
            return
        }
        
        var contentLength = 0
        let clPattern = "Content-Length:\\s*(\\d+)"
        if let regex = try? NSRegularExpression(pattern: clPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: headerStr, options: [], range: NSRange(headerStr.startIndex..., in: headerStr)) {
            if let range = Range(match.range(at: 1), in: headerStr) {
                contentLength = Int(headerStr[range]) ?? 0
            }
        }
        
        let headerLength = data.distance(from: data.startIndex, to: headerEndRange.upperBound)
        let totalNeeded = headerLength + contentLength
        
        if data.count >= totalNeeded {
            // Extract body directly
            let bodyData = data.subdata(in: headerEndRange.upperBound..<data.index(data.startIndex, offsetBy: totalNeeded))
            
            handleIncomingData(headerStr, bodyData: bodyData, connection: connection, connectionId: connectionId)
            
            connectionBuffers[connectionId]?.removeFirst(totalNeeded)
            processBuffer(connectionId: connectionId)
        } else {
            if data.count > headerLength {
                print("[MCPSSEBridge] [\(connectionId)] Waiting for body (\(data.count - headerLength)/\(contentLength) bytes)")
            }
        }
    }
    
    private func handleIncomingData(_ headerStr: String, bodyData: Data, connection: NWConnection, connectionId: UUID) {
        let lines = headerStr.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let firstLine = lines.first else { return }
        
        let parts = firstLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return }
        
        let method = parts[0]
        let path = parts[1]
        let cleanPath = path.components(separatedBy: "?").first ?? path
        
        print("[MCPSSEBridge] [\(connectionId)] \(method) \(path) (Body: \(bodyData.count) bytes)")
        
        if method == "GET" && (cleanPath == "/sse" || cleanPath == "/" || cleanPath == "/events") {
            let acceptsSSE = headerStr.lowercased().contains("text/event-stream")
            startHTTPStream(connection, connectionId: connectionId, format: acceptsSSE ? .sse : .raw)
        } else if method == "POST" {
            handlePostMessage(headerStr, bodyData: bodyData, connection: connection, connectionId: connectionId)
        } else if method == "OPTIONS" {
            handleOptions(connection)
        } else {
            print("[MCPSSEBridge] [\(connectionId)] 404 for \(method) \(path)")
            let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in 
                connection.cancel()
            }))
        }
    }
    
    private func startHTTPStream(_ connection: NWConnection, connectionId: UUID, format: ResponseFormat, completion: @escaping () -> Void = {}) {
        let contentType = (format == .sse) ? "text/event-stream" : "application/x-ndjson"
        clientFormats[connectionId] = format
        updateActiveClients() // Update with format
        
        let sessionId = connectionId.uuidString.lowercased()
        connectionIdToSessionId[connectionId] = sessionId
        
        print("[MCPSSEBridge] [\(connectionId)] Establishing HTTP stream (Format: \(format), Session: \(sessionId))")
        
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: \(contentType)",
            "Cache-Control: no-cache",
            "Connection: keep-alive",
            "Transfer-Encoding: chunked",
            "X-Mcp-Session-Id: \(sessionId)",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Headers: *",
            "Access-Control-Expose-Headers: X-Mcp-Session-Id",
            "\r\n"
        ].joined(separator: "\r\n")
        
        self.sseConnectionBySessionID[sessionId] = connectionId
        
        connection.send(content: headers.data(using: .utf8), completion: .contentProcessed({ _ in 
            // If SSE, send endpoint event
            switch format {
            case .sse:
                let endpointEvent = "event: endpoint\ndata: http://\(self.currentHost):\(self.currentPort)/message?sessionId=\(sessionId)\n\n"
                // Manual chunk
                let eventData = endpointEvent.data(using: .utf8)!
                let hexCount = String(eventData.count, radix: 16)
                var chunk = Data()
                chunk.append((hexCount + "\r\n").data(using: .utf8)!)
                chunk.append(eventData)
                chunk.append("\r\n".data(using: .utf8)!)
                
                connection.send(content: chunk, completion: .contentProcessed({ _ in
                    self.queue.asyncAfter(deadline: .now() + 0.1) { completion() }
                }))
            case .raw:
                self.queue.asyncAfter(deadline: .now() + 0.1) { completion() }
            }
        }))
        
        sseClients[connectionId] = connection
        // print("[MCPSSEBridge] [\(connectionId)] HTTP stream established (Format: \(String(describing: format)))")
        sendHeartbeat(to: connectionId)
    }
    
    private func sendHeartbeat(to id: UUID) {
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self, let conn = self.sseClients[id] else { return }
            
            let format = self.clientFormats[id] ?? .raw
            var heartbeatData: Data?
            
            switch format {
            case .sse:
                heartbeatData = ": keepalive\n\n".data(using: .utf8)
            case .raw:
                heartbeatData = "\n".data(using: .utf8)
            }
            
            if let data = heartbeatData {
                self.sendToConnection(conn, data: data, id: id)
            }
            self.sendHeartbeat(to: id)
        }
    }
    
    private func handlePostMessage(_ headerStr: String, bodyData: Data, connection: NWConnection, connectionId: UUID) {
        // Transport & Session Detection
        // Note: Using the First Line from headerStr to find URL params
        let firstLine = headerStr.components(separatedBy: .newlines).first ?? ""
        let sessionIdQuery = firstLine.range(of: "sessionId=([^&\\s]+)", options: .regularExpression).map {
            String(firstLine[$0]).replacingOccurrences(of: "sessionId=", with: "")
        }
        
        let acceptsEventStream = headerStr.lowercased().contains("accept: text/event-stream")
        let isSessionMessage = sessionIdQuery != nil

        // Try to extract name from User-Agent if not already known
        if clientNames[connectionId] == nil {
            let uaPattern = "User-Agent:\\s*([^\\r\\n]+)"
            if let regex = try? NSRegularExpression(pattern: uaPattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: headerStr, options: [], range: NSRange(headerStr.startIndex..., in: headerStr)),
               let range = Range(match.range(at: 1), in: headerStr) {
                let name = String(headerStr[range]).trimmingCharacters(in: .whitespaces)
                clientNames[connectionId] = name
                
                if let sid = sessionIdQuery {
                    let sKey = sid.lowercased()
                    // Only use UA as session name if we don't have a sticky one yet
                    if self.sessionNames[sKey] == nil {
                        print("[MCPSSEBridge] [\(connectionId)] UA fallback for session: \(sid) -> '\(name.prefix(20))...'")
                        sessionNames[sKey] = name
                    }
                    
                    // Also associate name directly with the SSE connection if it exists
                    if let sseId = sseConnectionBySessionID[sKey] {
                        clientNames[sseId] = name
                    }
                }
                
                updateActiveClients()
            }
        }

        if !bodyData.isEmpty {
            var requestId: AnyHashable? = nil
            if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                if let id = json["id"] as? AnyHashable {
                    requestId = id
                }
                
                // Extract client name from MCP initialize request
                if let method = json["method"] as? String, method == "initialize",
                   let params = json["params"] as? [String: Any],
                   let clientInfo = params["clientInfo"] as? [String: Any],
                   let name = clientInfo["name"] as? String {
                    clientNames[connectionId] = name
                    
                    // Determine effective Session Key
                    let sKey = sessionIdQuery.map { $0.lowercased() } ?? connectionIdToSessionId[connectionId] ?? connectionId.uuidString.lowercased()
                    
                    // Ensure mapping exists so recordRequest can link IDs to Session
                    if connectionIdToSessionId[connectionId] == nil {
                        connectionIdToSessionId[connectionId] = sKey
                    }
                    
                    print("[MCPSSEBridge] [\(connectionId)] Detected MCP client name: '\(name)' for session: \(sKey)")
                    sessionNames[sKey] = name
                    sessionLastSeen[sKey] = Date() // Mark as active
                    sessionInitialized[sKey] = true // Mark as fully initialized MCP client
                    
                    // Associate name directly with the SSE connection
                    if let sseId = sseConnectionBySessionID[sKey] {
                        clientNames[sseId] = name
                    }
                    
                    updateActiveClients()
                }
            }
            
            if let sid = sessionIdQuery {
                let sKey = sid.lowercased()
                connectionIdToSessionId[connectionId] = sKey
                sessionLastSeen[sKey] = Date() // Record activity on every message
            }
            
            if isSessionMessage {
                // 1. Standard MCP Session Message: Route response to session, send 202
                if let id = requestId, let sid = sessionIdQuery {
                    idToSessionId[id] = sid
                }
                let _ = requestId.map { String(describing: $0) } ?? "notify"
                // print("[MCPSSEBridge] [\(connectionId)] POST Session Message (id: \(idDesc))")
                
                let response = "HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: 21\r\nConnection: close\r\n\r\n{\"status\":\"accepted\"}"
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in 
                    connection.cancel()
                }))
                self.onMessageReceived?(bodyData, connectionId, self.clientNames[connectionId])
                
            } else if acceptsEventStream {
                // 2. Streamable HTTP (MCP/SSE): Upgrade to stream
                if let id = requestId {
                    pendingRequests[id] = connectionId
                }
                let idDesc = requestId.map { String(describing: $0) } ?? "notify"
                print("[MCPSSEBridge] [\(connectionId)] POST Streamable (id: \(idDesc))")
                
                startHTTPStream(connection, connectionId: connectionId, format: .sse) {
                    self.onMessageReceived?(bodyData, connectionId, self.clientNames[connectionId])
                }
                
            } else {
                // 3. Direct HTTP (FlowDown): Sync Response
                if let id = requestId {
                    print("[MCPSSEBridge] [\(connectionId)] POST Sync (id: \(String(describing: id)))")
                    pendingRequests[id] = connectionId
                    postConnections.insert(connectionId)
                    self.onMessageReceived?(bodyData, connectionId, self.clientNames[connectionId])
                } else {
                    // Notification via Direct HTTP? Just send 202
                    print("[MCPSSEBridge] [\(connectionId)] POST Sync Notification")
                    let response = "HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: 21\r\nConnection: close\r\n\r\n{\"status\":\"accepted\"}"
                    connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in 
                        connection.cancel()
                    }))
                    self.onMessageReceived?(bodyData, connectionId, self.clientNames[connectionId])
                }
            }
        }
    }
    
    private func handleOptions(_ connection: NWConnection) {
        let headers = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: *\r\n\r\n"
        connection.send(content: headers.data(using: .utf8), completion: .contentProcessed({ _ in }))
    }
    
    private func removeClient(_ id: UUID) {
        queue.async {
            // Retrieve mapped session ID before cleanup
            let sKey = self.connectionIdToSessionId[id] ?? id.uuidString.lowercased()
            
            self.connections[id]?.cancel()
            self.connections.removeValue(forKey: id)
            self.sseClients.removeValue(forKey: id)
            
            let _ = self.postConnections.contains(id)
            self.postConnections.remove(id)
            self.clientFormats.removeValue(forKey: id)
            self.clientNames.removeValue(forKey: id)
            self.connectionIdToSessionId.removeValue(forKey: id)
            
            // Only remove session name if it has truly timed out
            // We let updateActiveClients handle the 'active' list visibility,
            // but we keep the mapping in sessionNames for a longer tail (30s)
            // to catch reconnections or lingering updates.
            self.sessionLastSeen[sKey] = Date() // Record closure as last activity
            
            // Periodically clean up sessionNames (tail cleanup)
            let now = Date()
            for (key, lastSeen) in self.sessionLastSeen {
                if now.timeIntervalSince(lastSeen) > 30.0 {
                    self.sessionNames.removeValue(forKey: key)
                    self.sseConnectionBySessionID.removeValue(forKey: key)
                    self.sessionLastSeen.removeValue(forKey: key)
                    self.sessionInitialized.removeValue(forKey: key)
                }
            }
            
            self.connectionBuffers.removeValue(forKey: id)
            self.updateActiveClients()
        }
    }
}
