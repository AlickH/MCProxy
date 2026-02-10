import SwiftUI

struct ServerDetailView: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var manager: ServerManager
    
    @State var config: StdioServerConfig
    var isNew: Bool
    
    @State private var newEnvKey: String = ""
    @State private var newEnvValue: String = ""
    @State private var newArg: String = ""
    
    // Validation states
    @State private var isValidating = false
    @State private var validationSuccess = false
    @State private var validationError: String?
    @State private var mcpTools: [MCPTool] = []
    @State private var showingToolsPopover = false
    @State private var validationProcess: Process?
    @State private var validationOutput: String = ""
    
    // Port warning states
    @State private var showingPortAlert = false
    @State private var portWarningMessage = ""
    
    var body: some View {
        Form {
            generalSection
            commandSection
            argumentsSection
            environmentSection
            sseSection
            validationSection
        }
        .formStyle(.grouped)
        .alert("Restricted Port", isPresented: $showingPortAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(portWarningMessage)
        }
        .toolbar {
            toolbarContent
        }
        .onDisappear {
            stopValidation()
        }
    }
    
    // MARK: - Sections
    
    private var generalSection: some View {
        Section {
            HStack {
                Text("Name")
                    .frame(width: 100, alignment: .leading)
                TextField("Server Name", text: $config.name)
                    .textFieldStyle(.roundedBorder)
            }
            
            Toggle(isOn: $config.isEnabled) {
                HStack {
                    Image(systemName: "power")
                        .foregroundColor(config.isEnabled ? .green : .gray)
                    Text("Enabled")
                }
            }
            .toggleStyle(.switch)
        } header: {
            Label("General", systemImage: "gearshape")
                .font(.headline)
        }
    }
    
    private var commandSection: some View {
        Section {
            HStack {
                Text("Command")
                    .frame(width: 100, alignment: .leading)
                TextField("e.g. uvx, npx", text: $config.command)
                    .textFieldStyle(.roundedBorder)
            }
            
            HStack {
                Text("Working Dir")
                    .frame(width: 100, alignment: .leading)
                TextField("Optional", text: Binding(
                    get: { config.workingDirectory ?? "" },
                    set: { config.workingDirectory = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
        } header: {
            Label("Command", systemImage: "terminal")
                .font(.headline)
        }
    }
    
    private var argumentsSection: some View {
        Section {
            if config.args.isEmpty {
                emptyArgumentsView
            } else {
                ForEach(Array(config.args.enumerated()), id: \.offset) { index, arg in
                    argumentRow(index: index, arg: arg)
                }
            }
            
            addArgumentRow
        } header: {
            Label("Arguments", systemImage: "list.bullet")
                .font(.headline)
        }
    }
    
    private var environmentSection: some View {
        Section {
            if config.env.isEmpty {
                emptyEnvironmentView
            } else {
                ForEach(config.env.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    environmentRow(key: key, value: value)
                }
            }
            
            addEnvironmentRow
        } header: {
            Label("Environment Variables", systemImage: "variable")
                .font(.headline)
        }
    }
    
    private var sseSection: some View {
        Section {
            HStack {
                Text("Host")
                    .frame(width: 100, alignment: .leading)
                TextField("127.0.0.1", text: $config.sseHost)
                    .textFieldStyle(.roundedBorder)
            }
            
            HStack {
                Text("Port")
                    .frame(width: 100, alignment: .leading)
                TextField("0 for random", value: $config.ssePort, formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
            }
            
            if config.ssePort > 0 && config.ssePort < 1024 {
                HStack {
                    Spacer().frame(width: 104)
                    Text("⚠️ Ports < 1024 are restricted on macOS")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        } header: {
            Label("Streamable HTTP Configuration", systemImage: "network")
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
                .disabled(isValidating || config.name.isEmpty || config.command.isEmpty)
                .popover(isPresented: $showingToolsPopover) {
                    toolsPopover
                }
                
                // Stop Button (only show when validating)
                if isValidating {
                    Button("Stop") {
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
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding(.top, 8)
            }
            
            // Validation Output (for debugging)
            if isValidating && !validationOutput.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server Output:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(validationOutput)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(5)
                }
                .padding(.top, 8)
            }
        } header: {
            Label("Validation", systemImage: "checkmark.shield")
                .font(.headline)
        }
    }
    
    // MARK: - Empty States
    
    private var emptyArgumentsView: some View {
        HStack {
            Image(systemName: "list.bullet.rectangle")
                .foregroundColor(.secondary)
            Text("No arguments added")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding(.vertical, 8)
    }
    
    private var emptyEnvironmentView: some View {
        HStack {
            Image(systemName: "variable")
                .foregroundColor(.secondary)
            Text("No environment variables added")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding(.vertical, 8)
    }
    
    // MARK: - Row Components
    
    private func argumentRow(index: Int, arg: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.right.circle.fill")
                .foregroundColor(.blue)
                .font(.caption)
            
            TextField("Argument", text: Binding(
                get: { config.args[index] },
                set: { config.args[index] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            
            Spacer()
            
            Button(action: { config.args.remove(at: index) }) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .transition(.opacity.combined(with: .scale))
    }
    
    private func environmentRow(key: String, value: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(key)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Text("=")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(width: 80, alignment: .leading)
            
            TextField("Value", text: Binding(
                get: { config.env[key] ?? "" },
                set: { config.env[key] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            
            Spacer()
            
            Button(action: { config.env.removeValue(forKey: key) }) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .transition(.opacity.combined(with: .scale))
    }
    
    // MARK: - Add Rows
    
    private var addArgumentRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
            
            TextField("New argument", text: $newArg)
                .textFieldStyle(.roundedBorder)
                .onSubmit { addArg() }
            
            Button(action: addArg) {
                Text("Add")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .buttonStyle(.bordered)
            .disabled(newArg.isEmpty)
        }
        .padding(.top, 8)
    }
    
    private var addEnvironmentRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
            
            TextField("Key", text: $newEnvKey)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
            
            Text("=")
                .foregroundColor(.secondary)
            
            TextField("Value", text: $newEnvValue)
                .textFieldStyle(.roundedBorder)
            
            Button(action: addEnv) {
                Text("Add")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .buttonStyle(.bordered)
            .disabled(newEnvKey.isEmpty)
        }
        .padding(.top, 8)
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
            Button("Cancel") {
                presentationMode.wrappedValue.dismiss()
            }
        }
        
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .disabled(config.name.isEmpty || config.command.isEmpty)
        }
    }
    
    // MARK: - Actions
    
    private func addArg() {
        guard !newArg.isEmpty else { return }
        withAnimation(.spring()) {
            config.args.append(newArg)
            newArg = ""
        }
    }
    
    private func addEnv() {
        guard !newEnvKey.isEmpty else { return }
        withAnimation(.spring()) {
            config.env[newEnvKey] = newEnvValue
            newEnvKey = ""
            newEnvValue = ""
        }
    }
    
    private func validateServer() {
        withAnimation {
            isValidating = true
            validationSuccess = false
            validationError = nil
            mcpTools = []
            validationOutput = ""
        }
        
                Task {
            do {
                let tools = try await manager.validateConfig(config)
                await MainActor.run {
                    withAnimation {
                        self.isValidating = false
                        self.validationSuccess = true
                        self.mcpTools = tools
                        self.config.tools = tools // Store tools in config
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
                        self.validationError = "Validation failed: \(error.localizedDescription)"
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
            validationError = "Validation stopped"
        }
    }

    private func isPortAvailable(_ port: Int) -> Bool {
        guard port > 0 else { return true }
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
        if config.ssePort > 0 && config.ssePort < 1024 {
            portWarningMessage = "Port \(config.ssePort) is a system-restricted port on macOS (0-1023). Please use a port above 1024 or use 0 for an automatic port."
            showingPortAlert = true
            return
        }

        if config.ssePort > 0 && !isPortAvailable(config.ssePort) {
            let isCurrentPort = !isNew && manager.instances[config.id]?.status == .running
            if !isCurrentPort {
                portWarningMessage = "Port \(config.ssePort) is already in use by another application. Please choose a different port."
                showingPortAlert = true
                return
            }
        }
        
        withAnimation {
            if isNew {
                manager.addServer(config)
            } else {
                manager.updateServer(config)
            }
            presentationMode.wrappedValue.dismiss()
        }
    }
}
