# MCProxy Promotion Templates

This document contains several templates you can use to promote **MCProxy** on different platforms.

---

## 选项 1：V2EX / 开发者社区 (中文)

**标题：[分享] MCProxy：一个原生 macOS 的 MCP 服务器桥接工具，让 Cursor/Claude 轻松适配 Stdio 工具**

**正文：**
大家好，最近 MCP (Model Context Protocol) 非常火，但很多优秀的工具（如 uvx, npx 安装的工具）都是基于 Stdio 的，在某些需要 HTTP/SSE 通信的场景（比如远程连接、或者某些特定的 IDE 插件）下使用起来不太方便。

所以我写了 **MCProxy** —— 一个纯原生的 macOS 小工具，旨在解决这个痛点。

**核心功能：**

- 🚀 **Stdio 转 SSE**：将任何基于命令行标准输入输出的 MCP 服务器转换为 HTTP/SSE 流。
- 🖥️ **原生体验**：SwiftUI 构建，支持深色模式，运行丝滑。
- 📊 **可视化日志**：内置了非常强大的 JSON 重组渲染，看 MCP 的 Payload 就像看树状图一样清晰。
- ⚙️ **多服务器管理**：可以同时管理多个服务器，支持环境变量配置和工作目录切换。
- 🛡️ **后台运行**：采用主应用+助手进程架构，关闭窗口服务也不会断。

**GitHub:** https://github.com/AlickH/MCProxy
**开源协议:** GPLv3

欢迎大家试用、提 Issue 或者给个 Star ⭐️！

---

## Option 2: Reddit (r/ClaudeAI, r/CursorAI) - English

**Title: [Showcase] MCProxy - Native macOS bridge for Stdio MCP servers (SSE support for Cursor/Claude)**

**Body:**
Hey everyone! One common friction point with MPC (Model Context Protocol) is that while many servers are Stdio-based, some environments or remote clients prefer HTTP/SSE.

I’ve built **MCProxy**, a native macOS app that makes this bridge effortless.

**Why use it?**

- **Bridging the Gap**: Easily use your favorite stdio tools (uvx, npx) with any client that requires an SSE endpoint.
- **Native performance**: Built with SwiftUI for that premium Mac feel.
- **Advanced Debugging**: If you've ever struggled to read raw MCP logs, you'll love our built-in JSON Tree viewer. It makes debugging tools and prompts actually readable.
- **Manager for everything**: Configure environment variables, distinct working directories, and monitor multiple server statuses in one place.

Check it out on GitHub: https://github.com/AlickH/MCProxy

Feedback and contributions are more than welcome!

---

## Option 3: Twitter/X (Bilingual/Punchy)

**Text:**
🚀 Excited to launch **MCProxy**!

A native macOS bridge for #MCP (Model Context Protocol).
Turn any stdio-based tool into a robust HTTP/SSE server for Cursor, Claude, and more.

✅ Native SwiftUI UI
✅ Multi-server manager
✅ Pro JSON Log viewer
✅ Open Source (GPLv3)

Check it out: https://github.com/AlickH/MCProxy

#AI #ModelContextProtocol #SwiftUI #macOS #DevTools

---

## 贴士：推广建议

- **上传一张截图**：在 V2EX 或 Reddit 发帖时，带上仓库里的 `screenshot-main.png` 或 `screenshot-logs.png`。
- **回复积极**：早期用户的问题反馈是迭代的最好动力。
- **发布 Release**：在 GitHub 上创建一个正式的 Release，并附带生成的 `MCProxy.app` 压缩包。
