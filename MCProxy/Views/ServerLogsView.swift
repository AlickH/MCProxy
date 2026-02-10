import SwiftUI

struct ServerLogsView: View {
    @ObservedObject var instance: ServerInstance
    @EnvironmentObject var serverManager: ServerManager
    
    var body: some View {
        VStack(spacing: 0) {
            // Tools Section
            if !instance.config.tools.isEmpty {
                let _ = print("[UI] ServerLogsView: Displaying \(instance.config.tools.count) tools for \(instance.config.name)")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(instance.config.tools) { tool in
                            ToolCard(tool: tool, config: instance.config, serverManager: serverManager)
                        }
                    }
                    .padding()
                }
                .divider(at: .bottom)
            }
            
            // Clients Section
            if !instance.activeClients.isEmpty {
                HStack(alignment: .center, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.2.fill")
                            .frame(width: 18)
                        Text("Active Clients:")
                    }
                    .font(.headline)
                    .foregroundColor(.primary)
                    .padding(.leading, 12)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .center, spacing: 10) {
                            ForEach(instance.activeClients) { client in
                                ClientBadge(client: client)
                            }
                        }
                    }
                }
                .frame(height: 50) // More breathing room, stable height
                .divider(at: .bottom)
            }

            // Header
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle.fill")
                        .frame(width: 18)
                    Text("Logs: \(instance.config.name)")
                }
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.leading, 12)
                
                Spacer()
                
                Button(action: {
                    // Clear logs functionality could be added here
                    instance.logs.removeAll()
                }) {
                    Image(systemName: "trash")
                }
                .help("Clear Logs")
                .padding(.trailing, 12)
            }
            .frame(height: 50)
            
            Divider()
            
            // Log List
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(instance.logItems) { item in
                            switch item {
                            case .pair(let pair):
                                LogPairRow(pair: pair)
                                    .id(pair.id)
                            case .single(let entry):
                                LogEntryRow(entry: entry)
                                    .id(entry.id)
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: instance.logItems.count) { _ in
                    if let last = instance.logItems.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

struct LogEntryView: View {
    let entry: LogEntry
    
    private var parsedInfo: (isTraffic: Bool, label: String, color: Color) {
        if entry.message.hasPrefix(">>> CLIENT REQUEST:\n") {
            return (true, "REQUEST", .green)
        } else if entry.message.hasPrefix("<<< SERVER RESPONSE:\n") {
            return (true, "RESPONSE", .blue)
        }
        return (false, "", .clear)
    }
    
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    
    private var displayContent: AttributedString {
        guard let attr = entry.highlightedMessage else { return AttributedString(entry.message) }
        
        if parsedInfo.isTraffic {
            // Drop the first line (prefix)
            if let range = attr.range(of: "\n") {
                return AttributedString(attr[range.upperBound...])
            }
        }
        return attr
    }

    private var isNotification: Bool {
        return entry.message.contains("notifications/initialized")
    }
    
    var body: some View {
        let info = parsedInfo
        
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .center) {
                Text(entry.timestamp, formatter: Self.dateFormatter)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if let client = entry.clientName {
                    Text(client)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.8))
                        .padding(.trailing, 4)
                }
                
                if isNotification {
                     Text("NOTIFICATION")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.7))
                        .cornerRadius(4)
                } else if info.isTraffic {
                    Text(info.label)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(info.color.opacity(0.8))
                        .cornerRadius(4)
                } else {
                    Text(entry.type == .stdout ? "OUT" : (entry.type == .stderr ? "ERR" : "SYS"))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(colorForType(entry.type))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(colorForType(entry.type).opacity(0.1))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(Color.primary.opacity(0.05)),
                alignment: .bottom
            )
            
            // Content
            // Content
            if isNotification {
                Text("Initialized (JSON-RPC 2.0)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                    .padding(12)
            } else {
                Text(displayContent)
                    .font(.system(size: 12, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(12)
            }        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 1, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
        .padding(.vertical, 4)
    }
    
    private func colorForType(_ type: LogType) -> Color {
        switch type {
        case .stdout: return .primary
        case .stderr: return .red
        case .system: return .blue
        }
    }
}

struct LogEntryRow: View {
    let entry: LogEntry
    
    var body: some View {
        LogEntryView(entry: entry)
    }
}

struct LogPairRow: View {
    @ObservedObject var pair: LogPair
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Request Header
            HStack(alignment: .center) {
                Text(pair.request.timestamp, formatter: LogEntryView.dateFormatter)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if let client = pair.request.clientName {
                    Text(client)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.8))
                        .padding(.trailing, 4)
                }
                
                Text("REQUEST")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.7))
                    .cornerRadius(4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            
            Divider()
            
            // Request Content
            JSONLogView(entry: pair.request, isRequest: true)
            
            Divider()
            
            // Response Section
            if let response = pair.response {
                // Response Header
                HStack {
                    Text("RESPONSE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.7))
                        .cornerRadius(4)
                    
                    Spacer()
                    
                    Text(response.timestamp, formatter: LogEntryView.dateFormatter)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.03))
                
                Divider()
                
                // Response Content
                JSONLogView(entry: response, isRequest: false)
            } else {
                // Pending
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                    Text("Waiting for response...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(12)
                .background(Color.secondary.opacity(0.01))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 1, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
        .padding(.vertical, 4)
    }
}

struct JSONLogView: View {
    let entry: LogEntry
    let isRequest: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let payload = entry.jsonPayload {
                // Specialized Views based on Content
                if isRequest, let method = payload.data["method"] as? String {
                    StructuredRequestView(method: method, params: payload.data["params"] as? [String: Any])
                } else if !isRequest,
                          let result = payload.data["result"] as? [String: Any],
                          let tools = result["tools"] as? [[String: Any]] {
                    ToolListResponseView(tools: tools)
                } else {
                    // Generic JSON Tree View for other responses
                    JSONTreeView(rootNodes: payload.rootNodes)
                }
            } else {
                FallbackContentView(entry: entry, isRequest: isRequest)
            }
        }
    }
}

struct JSONTreeView: View {
    let rootNodes: [JSONNode]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header Row
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer().frame(width: 24)
                    Text("Key")
                    Spacer()
                }
                .frame(width: 200, alignment: .leading)
                
                Divider()
                
                Text("Type")
                    .frame(width: 80, alignment: .leading)
                    .padding(.leading, 8)
                
                Divider()
                
                Text("Value")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.secondary)
            .frame(height: 24)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            
            Divider()
            
            // Content
            VStack(spacing: 0) {
                ForEach(rootNodes) { node in
                    JSONNodeRow(node: node, level: 0)
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
    }
}

struct JSONNodeRow: View {
    let node: JSONNode
    let level: Int
    @State private var isExpanded: Bool = true
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Key Column
                HStack(spacing: 4) {
                    // Indent
                    Color.clear.frame(width: CGFloat(level * 16), height: 1)
                    
                    if let children = node.children, !children.isEmpty {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 12, height: 12)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.1)) {
                                    isExpanded.toggle()
                                }
                            }
                    } else {
                        Spacer().frame(width: 12)
                    }
                    
                    Text(node.key)
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.leading, 8)
                .frame(width: 200, alignment: .leading) // Frame after padding to include it in width
                
                Divider()
                
                // Type Column
                Text(node.type)
                    .frame(width: 80, alignment: .leading)
                    .foregroundColor(.secondary)
                    .padding(.leading, 8)
                
                Divider()
                
                // Value Column
                Text(node.value)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 8)
            }
            .frame(height: 22)
            .background(Color.clear)
            
            Divider().opacity(0.5)
            
            if isExpanded, let children = node.children {
                ForEach(children) { child in
                    JSONNodeRow(node: child, level: level + 1)
                }
            }
        }
    }
}

struct FallbackContentView: View {
    let entry: LogEntry
    let isRequest: Bool
    
    var body: some View {
        let prefix = isRequest ? ">>> CLIENT REQUEST:\n" : "<<< SERVER RESPONSE:\n"
        let content: AttributedString
        
        if let attr = entry.highlightedMessage,
           let range = attr.range(of: "\n"),
           entry.message.hasPrefix(prefix) {
            content = AttributedString(attr[range.upperBound...])
        } else {
            content = AttributedString(entry.message)
        }
        
        return Text(content)
            .font(.system(size: 12, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(12)
    }
}

struct StructuredRequestView: View {
    let method: String
    let params: [String: Any]?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Method:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(method)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
            }
            .padding(12)
            
            if let params = params, !params.isEmpty {
                Divider()
                // Use Table view for params
                let payload = JSONPayload(params)
                JSONTreeView(rootNodes: payload.rootNodes)
            }
        }
    }
}

struct ToolListResponseView: View {
    let tools: [[String: Any]]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Available Tools (\(tools.count))")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(0..<tools.count, id: \.self) { index in
                        let tool = tools[index]
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tool["name"] as? String ?? "Unknown")
                                .font(.headline)
                                .lineLimit(1)
                            Text(tool["description"] as? String ?? "")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                                .frame(height: 45, alignment: .topLeading)
                        }
                        .padding(10)
                        .frame(width: 200, height: 100)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.1)))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }
}

struct ClientBadge: View {
    let client: ConnectedClient
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: client.format == .sse ? "dot.radiowaves.left.and.right" : "bolt.horizontal.fill")
                .font(.system(size: 10))
                .frame(width: 14) // Stable icon column
            
            VStack(alignment: .leading, spacing: 0) {
                if let name = client.name {
                    Text(name)
                        .font(.system(size: 11, weight: .bold))
                }
                if !client.address.isEmpty {
                    Text(client.address)
                        .font(.system(size: 8, design: .monospaced))
                        .opacity(0.6)
                } else if client.name == nil {
                    Text("Local Connection")
                        .font(.system(size: 8))
                        .opacity(0.6)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.blue.opacity(0.08))
                .overlay(Capsule().stroke(Color.blue.opacity(0.15), lineWidth: 1))
        )
        .foregroundColor(.blue)
        .help(client.name ?? client.address)
    }
}

struct ToolCard: View {
    let tool: MCPTool
    let config: StdioServerConfig
    @ObservedObject var serverManager: ServerManager
    
    @State private var showingSchema = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tool.name)
                .font(.headline)
                .lineLimit(1)
            
            Text(tool.description)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .frame(height: 32, alignment: .topLeading)
            
            Button("...View Input Schema") {
                showingSchema.toggle()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.blue)
            .popover(isPresented: $showingSchema) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Input Schema").font(.headline)
                    Divider()
                    ForEach(tool.inputSchema.sorted(by: { $0.key < $1.key }), id: \.key) { key, type in
                        HStack {
                            Text(key).fontWeight(.semibold)
                            Text(": \(type)").foregroundColor(.secondary)
                        }
                        .font(.caption)
                    }
                }
                .padding()
                .frame(minWidth: 200)
            }
            
            Toggle(isOn: isEnabledBinding) {
                Text("Enable")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
        }
        .padding(12)
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }
    
    private var isEnabledBinding: Binding<Bool> {
        Binding(
            get: { !config.disabledTools.contains(tool.name) },
            set: { enabled in
                var updatedConfig = config
                if enabled {
                    updatedConfig.disabledTools.remove(tool.name)
                } else {
                    updatedConfig.disabledTools.insert(tool.name)
                }
                serverManager.updateServer(updatedConfig)
            }
        )
    }
}

extension View {
    func divider(at edge: Edge) -> some View {
        VStack(spacing: 0) {
            if edge == .top { Divider() }
            self
            if edge == .bottom { Divider() }
        }
    }
}
