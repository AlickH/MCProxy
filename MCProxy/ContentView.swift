//
//  ContentView.swift
//  MCProxy
//
//  Created by A. Lick on 2026-02-09 13:10.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var serverManager: ServerManager
    @State private var showingAddServer = false
    @State private var editingServer: StdioServerConfig?
    @State private var selectedServerID: UUID?
    @State private var lastServerCount = 0
    @State private var showingLicense = false
    
    var body: some View {
        NavigationSplitView {
            serverList
                .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            serverDetail
        }
        .sheet(isPresented: $showingAddServer) {
            ServerEditView(manager: serverManager)
                .frame(minWidth: 500, minHeight: 600)
        }
        .sheet(item: $editingServer) { server in
            ServerEditView(manager: serverManager, editingConfig: server)
                .frame(minWidth: 500, minHeight: 600)
        }
        .sheet(isPresented: $showingLicense) {
            LicenseView()
        }
    }
    
    // MARK: - Server List
    
    private var serverList: some View {
        List {
            if serverManager.servers.isEmpty {
                emptyState
            } else {
                ForEach(serverManager.servers) { server in
                    ServerRow(server: server, isSelected: selectedServerID == server.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            editingServer = server
                        }
                        .onTapGesture {
                            selectedServerID = server.id
                        }
                        .contextMenu {
                            Button {
                                let host = server.sseHost
                                let port = serverManager.instances[server.id]?.actualPort ?? server.ssePort
                                let url = "http://\(host):\(port)/sse"
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(url, forType: .string)
                            } label: {
                                Label("Copy HTTP Link", systemImage: "doc.on.doc")
                            }
                            
                            Divider()
                            
                            Button {
                                editingServer = server
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            
                            Button(role: .destructive) {
                                if let index = serverManager.servers.firstIndex(where: { $0.id == server.id }) {
                                    deleteServers(offsets: IndexSet(integer: index))
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onDelete(perform: deleteServers)
            }
        }
        .listStyle(.sidebar)
        .scrollIndicators(.hidden)
        .navigationTitle("MCProxy")
        .onAppear {
            lastServerCount = serverManager.servers.count
        }
        .onChange(of: serverManager.servers) { newServers in
            // If a new server was added, select it
            if newServers.count > lastServerCount {
                if let lastAdded = newServers.last {
                    selectedServerID = lastAdded.id
                }
            }
            lastServerCount = newServers.count
        }
    }
    
    // MARK: - Server Detail
    
    private var serverDetail: some View {
        Group {
            if let id = selectedServerID, let server = serverManager.servers.first(where: { $0.id == id }) {
                // Use a stable instance (either from runtime or preview cache)
                let instance = serverManager.instance(for: server)
                
                let _ = print("[UI] Rendering detail for \(server.name) (ID: \(server.id), Tools: \(server.tools.count))")
                ServerLogsView(instance: instance)
            } else {
                emptyDetailState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(
            selectedServerID != nil ? 
            (serverManager.servers.first(where: { $0.id == selectedServerID })?.name ?? "MCProxy") : 
            "MCProxy"
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showingAddServer = true }) {
                    Label("Add Server", systemImage: "plus")
                }
                .help("Add New Server")
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showingLicense = true }) {
                    Image(systemName: "info.circle")
                }
                .help("Show License")
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    serverManager.quitGlobal()
                } label: {
                    Label("Quit", systemImage: "power")
                        .foregroundColor(.red)
                }
                .help("Quit Application and Stop All Services")
            }
        }
    }
    
    // MARK: - Empty States
    
    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "server.rack")
                .font(.system(size: 60))
                .foregroundColor(.secondary.opacity(0.5))
            
            VStack(spacing: 8) {
                Text("No Servers")
                    .font(.headline)
                Text("Add your first server to get started")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Button(action: { showingAddServer = true }) {
                Label("Add Server", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowSeparator(.hidden)
    }
    
    private var emptyDetailState: some View {
        VStack(spacing: 20) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 50))
                .foregroundColor(.secondary.opacity(0.5))
            
            VStack(spacing: 8) {
                Text("Select a Server")
                    .font(.headline)
                Text("Choose a server from the list to view details")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Actions
    
    private func deleteServers(offsets: IndexSet) {
        for index in offsets {
            let server = serverManager.servers[index]
            serverManager.deleteServer(id: server.id)
        }
    }
}

// MARK: - Server Row

struct ServerRow: View {
    let server: StdioServerConfig
    let isSelected: Bool
    @EnvironmentObject private var serverManager: ServerManager
    
    var body: some View {
        HStack(spacing: 10) {
            // Server Icon
            if let instance = serverManager.instances[server.id] {
                ServerIconView(instance: instance)
                    .frame(width: 40, height: 40)
            } else {
                DefaultServerIcon(isEnabled: server.isEnabled)
                    .frame(width: 40, height: 40)
            }
            
            // Server Info
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    // Status Badge (Observing Instance)
                    if let instance = serverManager.instances[server.id] {
                        ServerStatusBadge(instance: instance)
                    } else {
                        DefaultStatusBadge(isEnabled: server.isEnabled)
                    }
                    
                    // Port (Observing Instance)
                    if let instance = serverManager.instances[server.id] {
                        ServerPortView(instance: instance)
                    }
                }
                
                // Command
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                    Text(server.command)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .opacity(0.8)
            }
            
            Spacer()
            
            // Status and Actions
            Toggle("", isOn: Binding(
                get: { server.isEnabled },
                set: { _ in toggleServer() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.blue.opacity(0.12) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Actions
    
    private func toggleServer() {
        withAnimation(.easeInOut(duration: 0.2)) {
            serverManager.toggleServer(id: server.id)
        }
    }
}

// MARK: - Subviews for Observation

struct ServerIconView: View {
    @ObservedObject var instance: ServerInstance
    
    var body: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.15))
            
            Image(systemName: "server.rack")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(statusColor)
        }
    }
    
    private var statusColor: Color {
        switch instance.status {
        case .running: return .green
        case .starting: return .orange
        case .error: return .red
        case .stopped: return .gray
        }
    }
}

struct DefaultServerIcon: View {
    let isEnabled: Bool
    var body: some View {
        ZStack {
            Circle()
                .fill((isEnabled ? Color.blue : Color.gray).opacity(0.15))
            Image(systemName: "server.rack")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(isEnabled ? .blue : .gray)
        }
    }
}

struct ServerStatusBadge: View {
    @ObservedObject var instance: ServerInstance
    
    var body: some View {
        Text(LocalizedStringKey(instance.status.rawValue.uppercased()))
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.12))
            .foregroundColor(statusColor)
            .cornerRadius(4)
    }
    
    private var statusColor: Color {
        switch instance.status {
        case .running: return .green
        case .starting: return .orange
        case .error: return .red
        case .stopped: return .gray
        }
    }
}

struct DefaultStatusBadge: View {
    let isEnabled: Bool
    var body: some View {
        Text(LocalizedStringKey(isEnabled ? "ENABLED" : "DISABLED"))
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((isEnabled ? Color.blue : Color.gray).opacity(0.12))
            .foregroundColor(isEnabled ? .blue : .gray)
            .cornerRadius(4)
    }
}

struct ServerPortView: View {
    @ObservedObject var instance: ServerInstance
    
    var body: some View {
        if instance.actualPort > 0 {
            HStack(spacing: 4) {
                Image(systemName: "network")
                    .font(.system(size: 10))
                Text("\(instance.actualPort)")
            }
            .foregroundColor(.blue)
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(ServerManager())
        .frame(width: 1200, height: 800)
}