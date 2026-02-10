import Foundation
import Combine
import SwiftUI

struct StdioServerConfig: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var command: String
    var args: [String]
    var env: [String: String]
    var workingDirectory: String?
    var isEnabled: Bool
    var ssePort: Int
    var sseHost: String
    var tools: [MCPTool] = []
    var disabledTools: Set<String> = []
    
    init(
        id: UUID = UUID(),
        name: String = "",
        command: String = "",
        args: [String] = [],
        env: [String: String] = [:],
        workingDirectory: String? = nil,
        isEnabled: Bool = true,
        ssePort: Int = 0,
        sseHost: String = "127.0.0.1",
        tools: [MCPTool] = [],
        disabledTools: Set<String> = []
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.workingDirectory = workingDirectory
        self.isEnabled = isEnabled
        self.ssePort = ssePort
        self.sseHost = sseHost
        self.tools = tools
        self.disabledTools = disabledTools
    }
}

enum ServerStatus: String, Codable {
    case stopped = "Stopped"
    case starting = "Starting"
    case running = "Running"
    case error = "Error"
}

class ServerInstance: ObservableObject, Identifiable {
    @Published var config: StdioServerConfig
    var id: UUID { config.id }
    
    @Published var status: ServerStatus = .stopped
    @Published var errorMessage: String?
    @Published var actualPort: Int = 0
    @Published var logs: [LogEntry] = [] // Keep for raw history if needed, or remove? Let's keep for now.
    @Published var logItems: [LogItem] = [] // For UI
    @Published var activeClients: [ConnectedClient] = []
    
    var stdioProcess: Process?
    var bridge: MCPSSEBridge?
    var sseTask: Task<Void, Never>?
    var clientCancellable: AnyCancellable?
    
    private let logQueue = DispatchQueue(label: "com.mcproxy.log-processing", qos: .userInitiated)
    private var pendingPairs: [String: LogPair] = [:]
    
    init(config: StdioServerConfig) {
        self.config = config
    }
    
    var maxLogCount: Int = 1000
    
    func appendLog(_ message: String, type: LogType, clientName: String? = nil, rpcId: AnyHashable? = nil, rawData: Data? = nil) {
        let rpcIdString = rpcId.map { "\($0)" }
        
        logQueue.async { [weak self] in
            guard let self = self else { return }
            let displayMessage = self.formatLogMessage(message)
            
            // Try to parse JSON for structured view
            var jsonPayload: JSONPayload? = nil
            
            // 1. Try raw data first (Most reliable)
            if let data = rawData,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                jsonPayload = JSONPayload(json)
            } 
            // 2. Fallback to extraction from message string
            else if let start = message.firstIndex(of: "{"),
                    let end = message.lastIndex(of: "}") {
                let jsonStr = String(message[start...end])
                if let data = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    jsonPayload = JSONPayload(json)
                }
            }
            
            let finalJson = jsonPayload
            
            Task { @MainActor in
                let entry = LogEntry(
                    timestamp: Date(),
                    message: displayMessage, // Use displayMessage for basic viewing
                    type: type,
                    clientName: clientName,
                    rpcId: rpcIdString,
                    jsonPayload: finalJson
                )
                
                // Add to raw logs
                self.logs.append(entry)
                if self.logs.count > self.maxLogCount {
                    self.logs.removeFirst(self.logs.count - self.maxLogCount)
                }
                
                // Process LogItem pairing/single display
                if type == .system, let id = rpcIdString, message.contains("CLIENT REQUEST") {
                    // Start new pair
                    let pair = LogPair(request: entry)
                    self.pendingPairs[id] = pair
                    self.logItems.append(.pair(pair))
                } else if type == .stdout, let id = rpcIdString, message.contains("SERVER RESPONSE") {
                    // Match existing pair
                    if let pair = self.pendingPairs[id] {
                        pair.response = entry
                        self.pendingPairs.removeValue(forKey: id)
                    } else {
                        // Orphan response or simple stdout
                        self.logItems.append(.single(entry))
                    }
                } else {
                    // System message, stderr, or simple stdout without paired RPC ID
                    self.logItems.append(.single(entry))
                }
                
                if self.logItems.count > self.maxLogCount {
                    self.logItems.removeFirst(self.logItems.count - self.maxLogCount)
                }
            }
        }
    }
    
    private func colorForType(_ type: LogType) -> Color {
        switch type {
        case .stdout: return .primary
        case .stderr: return .red
        case .system: return .blue
        }
    }
    
    private func formatLogMessage(_ message: String) -> String {
        // 1. Initial cleanup of the raw string
        let processed = message
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\/", with: "/")
        
        // 2. Find JSON content
        let trimmed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let startIdx = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let endIdx = trimmed.lastIndex(where: { $0 == "}" || $0 == "]" }),
              startIdx < endIdx else {
            return processed
        }
        
        let jsonCandidate = String(trimmed[startIdx...endIdx])
        
        // 3. Parse and Pretty Print with .withoutEscapingSlashes
        guard let data = jsonCandidate.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return processed
        }
        
        // We use JSONSerialization to pretty print, specifically avoiding escaping slashes
        var options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        if #available(macOS 10.15, *) {
            options.insert(.withoutEscapingSlashes)
        }
        
        guard let prettyData = try? JSONSerialization.data(withJSONObject: json, options: options),
              var prettyString = String(data: prettyData, encoding: .utf8) else {
            return processed
        }
        
        // 4. Secondary processing: Unescape intentional newlines INSIDE the JSON values
        // Note: JSONSerialization will escape newlines inside strings. We want to unescape them
        // so the UI can render them as actual line breaks for readability.
        prettyString = prettyString.replacingOccurrences(of: "\\n", with: "\n")
        prettyString = prettyString.replacingOccurrences(of: "\\\"", with: "\"")
        
        // 5. Reconstruct the message if it had surrounding text
        let prefix = String(trimmed[..<startIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(trimmed[trimmed.index(after: endIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        
        var result = ""
        if !prefix.isEmpty { result += prefix + "\n" }
        result += prettyString
        if !suffix.isEmpty { result += "\n" + suffix }
        
        return result
    }
}

struct JSONNode: Identifiable, Equatable {
    let id = UUID()
    let key: String
    let type: String
    let value: String
    let children: [JSONNode]?
    
    static func == (lhs: JSONNode, rhs: JSONNode) -> Bool {
        lhs.id == rhs.id
    }
}

class JSONPayload {
    let data: [String: Any]
    let rootNodes: [JSONNode]
    
    init(_ data: [String: Any]) {
        self.data = data
        self.rootNodes = JSONPayload.createNodes(from: data)
    }
    
    private static func createNodes(from data: Any, key: String? = nil) -> [JSONNode] {
        if let dict = data as? [String: Any] {
            return dict.keys.sorted().map { k in
                createNode(key: k, value: dict[k]!)
            }
        }
        return []
    }
    
    private static func createNode(key: String, value: Any) -> JSONNode {
        if let dict = value as? [String: Any] {
            let children = dict.keys.sorted().map { k in
                createNode(key: k, value: dict[k]!)
            }
            return JSONNode(key: key, type: "Dictionary", value: "\(dict.count) items", children: children)
        } else if let array = value as? [Any] {
            let children = array.enumerated().map { (index, item) in
                createNode(key: String(index), value: item)
            }
            return JSONNode(key: key, type: "Array", value: "\(array.count) items", children: children)
        } else {
            // Leaf
            let type: String
            let valStr: String
            
            if value is String { type = "String" }
            else if let num = value as? NSNumber {
                if CFBooleanGetTypeID() == CFGetTypeID(num) { type = "Boolean" }
                else { type = "Number" }
            }
            else if value is NSNull { type = "Null" }
            else { type = "Unknown" }
            
            valStr = "\(value)"
            return JSONNode(key: key, type: type, value: valStr, children: nil)
        }
    }
}

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let type: LogType
    var clientName: String? = nil
    var rpcId: String? = nil
    var jsonPayload: JSONPayload? = nil
    
    static func == (lhs: LogEntry, rhs: LogEntry) -> Bool {
        return lhs.id == rhs.id &&
               lhs.timestamp == rhs.timestamp &&
               lhs.message == rhs.message &&
               lhs.type == rhs.type &&
               lhs.clientName == rhs.clientName &&
               lhs.rpcId == rhs.rpcId
    }
}

enum LogItem: Identifiable {
    case pair(LogPair)
    case single(LogEntry)
    
    var id: UUID {
        switch self {
        case .pair(let p): return p.id
        case .single(let e): return e.id
        }
    }
}

class LogPair: Identifiable, ObservableObject {
    let id = UUID()
    let request: LogEntry
    @Published var response: LogEntry?
    
    init(request: LogEntry) {
        self.request = request
    }
}

enum LogType {
    case stdout
    case stderr
    case system
}
