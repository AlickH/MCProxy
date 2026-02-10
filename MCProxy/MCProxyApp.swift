import SwiftUI

// This file is now secondary as the app entry point is moved to main.swift
// We keep the App struct definitions here for organizational purposes if needed,
// but for the current manual launch logic in main.swift, we use UIAppDelegate.

struct MCProxyUIApp: App {
    @StateObject private var serverManager = ServerManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(serverManager)
        }
    }
}
