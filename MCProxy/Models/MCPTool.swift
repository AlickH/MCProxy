import Foundation

// MARK: - MCP Tool Model

struct MCPTool: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let description: String
    let inputSchema: [String: String]
}