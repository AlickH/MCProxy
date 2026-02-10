# Release Notes - v1.0.0 (Initial Release)

[English](#english) | [简体中文](#简体中文)

---

## English

We are excited to announce the initial release of **MCProxy**, a lightweight and powerful macOS tool for bridging Stdio-based Model Context Protocol (MCP) servers with HTTP/SSE clients.

### Key Features

- **Stdio to SSE Bridge**: Converts MCP server standard I/O into HTTP/SSE streams, enabling compatibility with clients like Cursor and Claude Desktop.
- **Background Helper Service**: Managed lifecycle through a dedicated helper process (`MCProxyHelper`) for persistence and performance.
- **Multi-Server Management**: Add, configure, and monitor multiple MCP servers simultaneously.
- **Native macOS Experience**:
  - Full Support for Dark Mode.
  - Status Bar (Menu Bar) integration with a custom `hammer.fill` icon.
  - System-native SwiftUI interface.
- **Advanced Logging**: Real-time log monitoring with structured JSON tree visualization for complex MCP payloads.
- **Bilingual Support**: Comprehensive localization for English and Simplified Chinese.
- **Safety & Stability**: Built with Swift 6 strict concurrency checks to ensure thread safety.

### Improvements & Bug Fixes

- Resolved various Swift 6 concurrency warnings related to shared state.
- Fixed localization gaps in JSON log tables and type labels.
- Optimized XPC communication between the main app and the helper service.
- Integrated GPL v3.0 license viewer directly into the app.

---

## 简体中文

我们非常高兴地宣布 **MCProxy** 的首个正式版本 v1.0.0 发布。这是一个专门为 macOS 设计的轻量级工具，旨在将基于 Stdio 的 MCP 服务器桥接至 HTTP/SSE 客户端。

### 核心功能

- **Stdio 到 SSE 桥接**：将 MCP 服务器的标准输入输出转换为 HTTP/SSE 流，轻松适配 Cursor 和 Claude Desktop 等客户端。
- **后台助手服务**：通过专门的 `MCProxyHelper` 进程管理服务器生命周期，确保稳定高效地后台运行。
- **多服务器管理**：同时添加、配置并监控多个不同的 MCP 服务器。
- **原生 macOS 体验**：
  - 完整支持深色模式 (Dark Mode)。
  - 菜单栏（状态栏）图标集成（`hammer.fill`）。
  - 纯原生 SwiftUI 界面设计。
- **高级日志系统**：实时收集日志，支持对复杂的 MCP 负载进行结构化 JSON 树状视图展示。
- **全方位双语支持**：界面完整支持中英文切换。
- **高性能与安全性**：基于 Swift 6 严格并发检查构建，确保卓越的性能与线程安全。

### 优化与修复

- 解决了多个与 Swift 6 并发相关的非隔离警告。
- 修复了日志表格中 JSON 节点类型（如 Dictionary, Array）及表头的汉化缺失问题。
- 对主程序与 Helper 助手进程间的 XPC 通讯进行了优化。
- 在应用内部集成了 GPL v3.0 开源协议查看器。
