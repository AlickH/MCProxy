import SwiftUI
import Foundation

struct ServerEditView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var manager: ServerManager
    
    var editingConfig: StdioServerConfig?
    
    @State private var name: String = ""
    @State private var command: String = ""
    @State private var argsString: String = ""
    @State private var workingDirectory: String = ""
    @State private var ssePort: String = "0"
    @State private var sseHost: String = "127.0.0.1"
    @State private var authToken: String = ""
    
    // Structured Env Vars
    struct EnvVar: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }
    @State private var envVars: [EnvVar] = []
    @State private var selectedEnvID: UUID?
    
    // Validation states
    @State private var isValidating = false
    @State private var validationSuccess = false
    @State private var validationError: String?
    @State private var mcpTools: [MCPTool] = []
    @State private var showingToolsPopover = false
    @State private var validationProcess: Process?
    @State private var installSuggestion: String?
    @State private var showingPasteError = false
    @State private var pasteErrorMessage = ""
    
    // Port warning states
    @State private var showingPortAlert = false
    @State private var portWarningMessage = ""
    
    var body: some View {
        Form {
            basicInfoSection
            environmentSection
            sseSection
            validationSection
        }
        .formStyle(.grouped)
        .alert(String(localized: "Restricted Port"), isPresented: $showingPortAlert) {
            Button(LocalizedStringKey("OK"), role: .cancel) { }
        } message: {
            Text(portWarningMessage)
        }
        .alert(String(localized: "Invalid JSON"), isPresented: $showingPasteError) {
            Button(LocalizedStringKey("OK"), role: .cancel) { }
        } message: {
            Text(pasteErrorMessage)
        }
        .toolbar {
            toolbarContent
        }
        .onAppear {
            loadConfig()
        }
        .onDisappear {
            // Clean up validation process when view disappears
            stopValidation()
        }
    }
    
    // MARK: - Sections
    
    private var basicInfoSection: some View {
        Section {
            HStack {
                Label("Name", systemImage: "textformat")
                    .frame(width: 120, alignment: .leading)
                TextField("Server name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            
            HStack {
                Label("Command", systemImage: "terminal")
                    .frame(width: 120, alignment: .leading)
                TextField("e.g. uvx, npx", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
            }
            
            HStack {
                Label("Arguments", systemImage: "list.bullet")
                    .frame(width: 120, alignment: .leading)
                TextField("space separated", text: $argsString)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
            }
        } header: {
            Label("Basic Info", systemImage: "info.circle")
                .font(.headline)
        }
    }
    
    private var environmentSection: some View {
        Section {
            HStack {
                Label("Working Dir", systemImage: "folder")
                    .frame(width: 120, alignment: .leading)
                TextField("Optional", text: $workingDirectory)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
            }
            
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Label("Environment Variables", systemImage: "equal.square")
                }
                .font(.body)
                .foregroundColor(.primary)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.top, 4)
                
                // Table Editor
                VStack(spacing: 0) {
                    // Header
                    HStack(spacing: 0) {
                        Text("Key")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                        
                        Divider()
                            .frame(height: 16)
                            .padding(.horizontal, 4)
                        
                        Text("Value")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .frame(height: 28)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    
                    Divider()
                    
                    // List
                    if envVars.isEmpty {
                        Text("No Environment Variables")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .frame(height: 60)
                            .background(Color(nsColor: .textBackgroundColor))
                    } else {
                        VStack(spacing: 0) {
                            ForEach($envVars) { $variable in
                                EnvVarRow(
                                    key: $variable.key,
                                    value: $variable.value,
                                    id: variable.id,
                                    selectedID: $selectedEnvID
                                )
                                
                                if variable.id != envVars.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                    }
                    
                    Divider()
                    
                    // Footer
                    HStack(spacing: 0) {
                        Button(action: {
                            withAnimation {
                                let newVar = EnvVar(key: "", value: "")
                                envVars.append(newVar)
                                selectedEnvID = newVar.id
                            }
                        }) {
                            ZStack {
                                Color.clear
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .frame(width: 32, height: 24)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        
                        Divider()
                            .frame(height: 16)
                        
                        Button(action: {
                            if let id = selectedEnvID {
                                withAnimation {
                                    envVars.removeAll { $0.id == id }
                                    selectedEnvID = envVars.last?.id
                                }
                            } else if !envVars.isEmpty {
                                withAnimation {
                                    _ = envVars.removeLast()
                                }
                            }
                        }) {
                            ZStack {
                                Color.clear
                                Image(systemName: "minus")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .frame(width: 32, height: 24)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(envVars.isEmpty)
                        
                        Divider()
                            .frame(height: 16)
                        
                        Text("\(envVars.count) items")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.leading, 8)
                        
                        Spacer()
                    }
                    .frame(height: 24)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.vertical, 4)
        } header: {
            Label("Environment & Directory", systemImage: "gearshape")
                .font(.headline)
        }
    }
    
    private var sseSection: some View {
        Section {
            HStack {
                Label("Host", systemImage: "network")
                    .frame(width: 120, alignment: .leading)
                TextField("127.0.0.1", text: $sseHost)
                    .textFieldStyle(.roundedBorder)
            }
            
            HStack {
                Label("Port", systemImage: "number")
                    .frame(width: 120, alignment: .leading)
                TextField("0 for random", text: $ssePort)
                    .textFieldStyle(.roundedBorder)
            }
            
            HStack {
                Label("Auth Token", systemImage: "key.fill")
                    .frame(width: 120, alignment: .leading)
                
                TextField("Optional Bearer Token", text: $authToken)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                
                Button(action: generateRandomToken) {
                    Image(systemName: "arrow.clockwise")
                        .help("Generate random token")
                }
                .buttonStyle(.bordered)
            }
            
            let portValue = Int(ssePort) ?? 0
            if portValue > 0 && portValue < 1024 {
                HStack {
                    Spacer().frame(width: 124)
                    Text("⚠️ Ports < 1024 are restricted on macOS")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        } header: {
            Label("Streamable HTTP Settings", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)
        }
    }
    
    private var validationSection: some View {
        Section {
            HStack(spacing: 12) {
                // Validate Button
                Button(action: validateServer) {
                    HStack(spacing: 8) {
                        if isValidating {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: validationSuccess ? "checkmark.circle.fill" : "play.circle.fill")
                                .foregroundColor(validationSuccess ? .green : .blue)
                        }
                        
                        Text(isValidating ? "Validating..." : "Validate Connection")
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isValidating || name.isEmpty || command.isEmpty)
                .popover(isPresented: $showingToolsPopover) {
                    toolsPopover
                }
                
                // Stop Button (only show when validating)
                if isValidating {
                    Button(LocalizedStringKey("Stop")) {
                        stopValidation()
                    }
                    .buttonStyle(.bordered)
                }
                
                // Info Button (only show when validated successfully)
                if validationSuccess && !mcpTools.isEmpty {
                    Button {
                        showingToolsPopover.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(mcpTools.count) Tools")
                                .font(.caption)
                                .fontWeight(.medium)
                            Image(systemName: "info.circle.fill")
                                .font(.caption)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.15))
                        )
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Validation Error Message
            if let error = validationError {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    
                    if let suggestion = installSuggestion {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "lightbulb.fill")
                                    .foregroundColor(.orange)
                                Text("Suggestion:")
                                    .font(.caption.bold())
                                    .foregroundColor(.orange)
                            }
                            
                            Text(suggestion)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(4)
                            
                            if !suggestion.contains("http") {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(suggestion, forType: .string)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.on.doc")
                                        Text("Copy Install Command")
                                    }
                                    .font(.caption2)
                                }
                                .buttonStyle(.link)
                                .padding(.leading, 2)
                            }
                        }
                        .padding(.top, 4)
                        .padding(.leading, 22)
                    }
                }
                .padding(.top, 8)
            }
        } header: {
            Label("Validation", systemImage: "checkmark.shield")
                .font(.headline)
        }
    }
    
    // MARK: - Tools Popover
    
    private var toolsPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(mcpTools) { tool in
                        toolRow(tool: tool)
                        if tool.id != mcpTools.last?.id {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
            }
            .frame(maxHeight: 400)
        }
        .frame(width: 400)
    }
    
    private func toolRow(tool: MCPTool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Tool Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(toolColor(for: tool).opacity(0.15))
                    .frame(width: 36, height: 36)
                
                Image(systemName: toolIcon(for: tool))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(toolColor(for: tool))
            }
            
            // Tool Info
            VStack(alignment: .leading, spacing: 4) {
                Text(tool.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                if !tool.description.isEmpty {
                    Text(tool.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                // Tool Parameters
                if !tool.inputSchema.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet")
                            .font(.caption2)
                        Text("\(tool.inputSchema.count) parameter(s)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture {
            // Could add copy to clipboard or other actions here
        }
    }
    
    // MARK: - Helper Methods
    
    private func toolIcon(for tool: MCPTool) -> String {
        let name = tool.name.lowercased()
        if name.contains("search") || name.contains("find") {
            return "magnifyingglass"
        } else if name.contains("file") || name.contains("read") || name.contains("write") {
            return "doc.text"
        } else if name.contains("create") || name.contains("add") {
            return "plus"
        } else if name.contains("delete") || name.contains("remove") {
            return "trash"
        } else if name.contains("execute") || name.contains("run") {
            return "play"
        } else if name.contains("get") || name.contains("fetch") {
            return "arrow.down"
        } else if name.contains("send") || name.contains("post") {
            return "arrow.up"
        } else {
            return "wrench.and.screwdriver"
        }
    }
    
    private func toolColor(for tool: MCPTool) -> Color {
        let name = tool.name.lowercased()
        if name.contains("search") || name.contains("find") {
            return .blue
        } else if name.contains("file") || name.contains("read") || name.contains("write") {
            return .green
        } else if name.contains("create") || name.contains("add") {
            return .purple
        } else if name.contains("delete") || name.contains("remove") {
            return .red
        } else if name.contains("execute") || name.contains("run") {
            return .orange
        } else {
            return .gray
        }
    }
    
    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(LocalizedStringKey("Cancel")) {
                dismiss()
            }
        }
        
        ToolbarItem(placement: .automatic) {
            Button(action: pasteFromClipboard) {
                Label("Parse MCP JSON", systemImage: "doc.on.clipboard")
            }
            .help("Parse MCP JSON from clipboard")
        }
        
        ToolbarItem(placement: .confirmationAction) {
            Button(LocalizedStringKey("Save")) {
                save()
            }
            .buttonStyle(.borderedProminent)
            .disabled(name.isEmpty || command.isEmpty)
        }
    }
    
    // MARK: - Actions
    
    private func loadConfig() {
        guard let config = editingConfig else { return }
        name = config.name
        command = config.command
        argsString = config.args.joined(separator: " ")
        workingDirectory = config.workingDirectory ?? ""
        ssePort = "\(config.ssePort)"
        sseHost = config.sseHost
        authToken = config.authToken ?? ""
        envVars = config.env.map { EnvVar(key: $0.key, value: $0.value) }.sorted(by: { $0.key < $1.key })
        mcpTools = config.tools
        if !mcpTools.isEmpty {
            validationSuccess = true
        }
    }
    
    private func validateServer() {
        withAnimation {
            isValidating = true
            validationSuccess = false
            validationError = nil
            installSuggestion = nil
            mcpTools = []
        }
        
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalWorkingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let args = argsString.split(separator: " ").map(String.init)
        
        var env: [String: String] = [:]
        for variable in envVars {
            let key = variable.key.trimmingCharacters(in: .whitespaces)
            let value = variable.value.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                env[key] = value
            }
        }
        
        let config = StdioServerConfig(
            id: UUID(),
            name: finalName,
            command: finalCommand,
            args: args,
            env: env,
            workingDirectory: finalWorkingDirectory.isEmpty ? nil : finalWorkingDirectory,
            isEnabled: true,
            ssePort: Int(ssePort) ?? 0,
            sseHost: sseHost,
            authToken: authToken
        )
        
        Task {
            do {
                let tools = try await manager.validateConfig(config)
                await MainActor.run {
                    withAnimation {
                        self.isValidating = false
                        self.validationSuccess = true
                        self.mcpTools = tools
                        // We don't save to config here yet, it happens on Save button
                        if !tools.isEmpty {
                            // Small delay to ensure layout is updated before popover shows
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                self.showingToolsPopover = true
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation {
                        self.isValidating = false
                        let nsError = error as NSError
                        self.validationError = String(localized: "Validation failed: \(error.localizedDescription)")
                        self.installSuggestion = nsError.userInfo["MCProxy.suggestion"] as? String
                    }
                }
            }
        }
    }
    
    private func stopValidation() {
        // Validation is now handled via async Tasks in manager, 
        // they are automatically cleaned up via defer in validateConfig
        withAnimation {
            isValidating = false
            validationError = String(localized: "Validation stopped")
        }
    }
    
    private func isPortAvailable(_ port: Int) -> Bool {
        guard port > 0 else { return true } // 0 is always "available" as OS will pick one
        
        let socketFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        if socketFD < 0 { return false }
        defer { close(socketFD) }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = INADDR_ANY
        
        var addrCopy = addr
        let result = withUnsafePointer(to: &addrCopy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private func save() {
        let portInt = Int(ssePort) ?? 0
        if portInt > 0 && portInt < 1024 {
            portWarningMessage = String(localized: "Port \(portInt) is a system-restricted port on macOS (0-1023). Please use a port above 1024 or use 0 for an automatic port.")
            showingPortAlert = true
            return
        }
        
        if portInt > 0 && !isPortAvailable(portInt) {
            // Check if it's the port currently being used by THIS server (if editing)
            let isCurrentPort = editingConfig?.ssePort == portInt && manager.instances[editingConfig?.id ?? UUID()]?.status == .running
            
            if !isCurrentPort {
                portWarningMessage = String(localized: "Port \(portInt) is already in use by another application. Please choose a different port.")
                showingPortAlert = true
                return
            }
        }

        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalWorkingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let args = argsString.split(separator: " ").map(String.init)
        
        var env: [String: String] = [:]
        for variable in envVars {
            let key = variable.key.trimmingCharacters(in: .whitespaces)
            let value = variable.value.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                env[key] = value
            }
        }
        
        let config = StdioServerConfig(
            id: editingConfig?.id ?? UUID(),
            name: finalName,
            command: finalCommand,
            args: args,
            env: env,
            workingDirectory: finalWorkingDirectory.isEmpty ? nil : finalWorkingDirectory,
            isEnabled: editingConfig?.isEnabled ?? true,
            ssePort: Int(ssePort) ?? 0,
            sseHost: sseHost,
            authToken: authToken,
            tools: mcpTools, // Save discovered tools
            disabledTools: editingConfig?.disabledTools ?? []
        )
        
        withAnimation {
            if editingConfig != nil {
                manager.updateServer(config)
            } else {
                manager.addServer(config)
            }
            dismiss()
        }
    }
    
    private func generateRandomToken() {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if result == errSecSuccess {
            // Use URL-safe base64 encoding and remove padding for a cleaner token
            authToken = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }
    
    private func pasteFromClipboard() {
        guard let clipboardString = NSPasteboard.general.string(forType: .string) else {
            pasteErrorMessage = String(localized: "Clipboard is empty")
            showingPasteError = true
            return
        }
        
        guard let jsonData = clipboardString.data(using: .utf8) else {
            pasteErrorMessage = String(localized: "Invalid text encoding")
            showingPasteError = true
            return
        }
        
        do {
            // Parse MCP JSON format: { "mcpServers" or "servers": { "name": { "command": "...", "args": [...] } } }
            if let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                // Try "mcpServers" first (Cursor/vscode format), then "servers"
                let serversKey = root.keys.contains("mcpServers") ? "mcpServers" : "servers"
                guard let servers = root[serversKey] as? [String: [String: Any]],
                      let firstServer = servers.first else {
                    let expectedFormat = "{ \"mcpServers\": { \"name\": { \"command\": \"...\", \"args\": [...] } } }"
                    pasteErrorMessage = String(localized: "JSON format not recognized. Expected: \(expectedFormat)")
                    showingPasteError = true
                    return
                }
                
                let serverName = firstServer.key
                let serverConfig = firstServer.value
                
                // Extract command
                if let cmd = serverConfig["command"] as? String {
                    command = cmd
                }
                
                // Extract args
                if let argsArray = serverConfig["args"] as? [String] {
                    argsString = argsArray.joined(separator: " ")
                }
                
                // Extract env variables
                if let envDict = serverConfig["env"] as? [String: String] {
                    envVars = envDict.map { EnvVar(key: $0.key, value: $0.value) }
                }
                
                // Set name (use server key as name if not already set)
                if name.isEmpty {
                    name = serverName
                }
            }
        } catch {
            pasteErrorMessage = String(localized: "Failed to parse JSON: \(error.localizedDescription)")
            showingPasteError = true
        }
    }
}
struct EnvVarTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    
    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.isBordered = false
        textField.backgroundColor = .clear
        textField.font = font
        textField.alignment = .left
        textField.isEditable = true
        textField.isSelectable = true
        // Single line mode
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingTail
        textField.placeholderString = placeholder
        textField.delegate = context.coordinator
        return textField
    }
    
    func updateNSView(_ textField: NSTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: EnvVarTextField
        
        init(_ parent: EnvVarTextField) {
            self.parent = parent
        }
        
        func controlTextDidChange(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                parent.text = textField.stringValue
            }
        }
    }
}

struct EnvVarRow: View {
    @Binding var key: String
    @Binding var value: String
    let id: UUID
    @Binding var selectedID: UUID?
    
    var body: some View {
        HStack(spacing: 0) {
            EnvVarTextField(text: $key, placeholder: "Key", font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(selectedID == id ? Color.blue.opacity(0.05) : Color.clear)
            
            Divider()
                .padding(.vertical, 4)
            
            EnvVarTextField(text: $value, placeholder: "Value", font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(selectedID == id ? Color.blue.opacity(0.05) : Color.clear)
        }
        .frame(height: 28)
        .simultaneousGesture(TapGesture().onEnded {
            selectedID = id
        })
    }
}
