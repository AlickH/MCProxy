# MCProxy

[English](#english) | [简体中文](#简体中文)

---

## English

MCProxy is a lightweight macOS tool designed to bridge the gap between Stdio-based Model Context Protocol (MCP) servers and applications that prefer HTTP/SSE (Server-Sent Events) communication.

### Features

- **Stdio to SSE Bridge**: Seamlessly convert standard I/O communication into HTTP/SSE streams.
- **Multi-Server Support**: Manage and monitor multiple MCP servers simultaneously.
- **Modern UI**: A native Swift UI with dark mode support, real-time logging, and structured JSON visualization.
- **Helper Service**: Runs as a background helper for persistent server management.
- **Bilingual Support**: Full interface support for English and Simplified Chinese.
- **Swift 6 Concurrency**: Built with strict concurrency checks for high performance and stability.

### Architecture

MCProxy follows a modular architecture:

- **Main App**: Handles the user interface and management logic.
- **Helper Process**: Manages the lifecycle of stdio servers and handles the high-performance XPC communication.
- **SSE Bridge**: Implements the native Swift SSE server for client connections.

### Installation

1. Clone the repository.
2. Open `MCProxy.xcodeproj` in Xcode 15+.
3. Build and run the `MCProxy` scheme.

### Usage

1. Add your Stdio-based MCP server in the "Add Server" panel.
2. Start the server.
3. Connect your client (e.g., Claude Desktop, Cursor) to the provided local HTTP address.

### License

This project is licensed under the **GNU General Public License v3.0**. See the [LICENSE](LICENSE) file for details.

---

## 简体中文

MCProxy 是一款轻量级的 macOS 工具，旨在为基于 Stdio 的模型上下文协议 (MCP) 服务器与偏好 HTTP/SSE（服务发送事件）通信的应用之间建立桥梁。

### 功能特性

- **Stdio 到 SSE 桥接**：无缝将标准输入输出通信转换为 HTTP/SSE 流。
- **多服务器支持**：同时管理和监控多个 MCP 服务器。
- **现代化界面**：原生 SwiftUI 开发，支持深色模式、实时日志和结构化 JSON 视图。
- **后台助手服务**：作为后台 Helper 运行，实现持久的服务器管理。
- **双语支持**：界面全面支持中英文双语。
- **Swift 6 并发**：遵循严格的并发检查，确保高性能与稳定性。

### 架构设计

MCProxy 采用模块化架构：

- **主应用**：处理用户界面与管理逻辑。
- **助手进程**：管理 Stdio 服务器的生命周期，并处理高性能的 XPC 通讯。
- **SSE 桥接器**：通过原生 Swift 实现 SSE 服务供客户端连接。

### 安装指南

1. 克隆仓库。
2. 在 Xcode 15+ 中打开 `MCProxy.xcodeproj`。
3. 编译并运行 `MCProxy` 方案。

### 使用说明

1. 在“添加服务器”面板中添加基于 Stdio 的 MCP 服务器。
2. 启动服务器。
3. 将您的客户端（如 Claude Desktop, Cursor）连接到提供的本地 HTTP 地址。

### 开源协议

本项目采用 **GNU General Public License v3.0** 开源协议。详情请参阅 [LICENSE](LICENSE) 文件。
