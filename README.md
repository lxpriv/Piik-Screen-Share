# Piik Screen Share + KOOK

Windows 屏幕共享启动器，基于 [Piik](https://github.com/TNTcraftHIM/Piik)，联动 KOOK 机器人自动发送和收回观看入口。

- Windows Forms 窗口一键启动、停止；关闭窗口会清理后台服务。
- 自动启动本地 Piik、Cloudflare 临时隧道和专用 Chrome / Edge。
- 检测到共享预览和公网服务就绪后，向指定 KOOK 文字频道发送完整邀请；结束后移除消息中的链接。
- 支持可选分享者昵称、自定义消息和私下分发的便携包。
- 本机端口统一读取配置，新配置默认 `17887`；启动前检测端口占用或 Windows 保留，服务异常退出时显示具体原因。
- 提前关闭浏览器后仍可正常停止；KOOK 结束消息更新失败时保留待重试记录，本地共享可正常关闭。

## 目录

| 路径 | 内容 |
| --- | --- |
| `piik/launcher/` | C# 启动器、编译脚本与验收脚本 |
| `piik/Start-Piik.ps1`、`Stop-Piik.ps1` | 服务和浏览器生命周期 |
| `piik/patches/` | 针对 Piik v2.8.0 的邀请跳转兼容补丁 |
| `piik/server/.env.example` | 服务端配置模板 |
| `kook-bot/` | 无第三方 npm 依赖的通知机器人和测试 |

本仓库保存集成代码，不重复收录 Piik 上游源码、下载的程序、构建缓存或私人运行数据。

## 首次配置

需要 Windows 10/11 x64、Chrome 或 Edge、带内置 `fetch` 和 `WebSocket` 的 Node.js 22.17 或更新版本，以及 Windows 自带的 .NET Framework 编译器。构建 Piik 服务端另需 Git、Node.js 24 和 Go 1.27.4（按固定上游提交要求）。

1. 克隆本仓库，在仓库根目录操作，保持 `piik` 与 `kook-bot` 并列。
2. 按 [服务端补丁说明](piik/server/LOCAL-PATCH.md) 取得固定版本的 Piik 源码、应用补丁并生成 `piik/server/piik-server.exe`。
3. 从 [cloudflared 官方发布页](https://github.com/cloudflare/cloudflared/releases) 获取 Windows amd64 程序，放到 `piik/runtime/runtime/tunnel/cloudflared.exe`。重新分发时同时保留其许可证和第三方声明。
4. 复制两个本地配置文件，并填写自己的 KOOK Bot Token、服务器名称、文字频道名称及频道 ID：

   ```powershell
   Copy-Item piik/server/.env.example piik/server/.env
   Copy-Item kook-bot/config.example.json kook-bot/config.local.json
   ```

   机器人需要加入目标服务器，并拥有目标文字频道的查看和发布消息权限。
5. 编译使用相对目录的启动器：

   ```powershell
   powershell -ExecutionPolicy Bypass -File piik/launcher/Build.ps1 -Portable
   ```

6. 双击 `piik/Piik-Screen-Share.exe`，点击“开始”，在专用浏览器中选择屏幕、窗口或标签页。也可直接运行 `piik/Start-Piik.ps1`，结束时运行 `piik/Stop-Piik.ps1`。

机器人配置和消息定制见 [kook-bot/README.md](kook-bot/README.md)；启动器与便携包说明见 [piik/README.md](piik/README.md)。

## 验证

以下检查使用模拟请求或隔离工作区，不会向 KOOK 发送消息：

```powershell
node kook-bot/test.mjs
node kook-bot/test-browser.mjs
node kook-bot/test-watch.mjs
powershell -ExecutionPolicy Bypass -File piik/launcher/Test-Shutdown.ps1
powershell -ExecutionPolicy Bypass -File piik/launcher/Test-ClosedBrowser.ps1
powershell -ExecutionPolicy Bypass -File piik/launcher/Test-LauncherFailures.ps1
```

完整联动验收需配置本地服务和机器人；`Test-Launcher.ps1 -LivePreview` 与 `Test-Portable.ps1` 会向配置的 KOOK 频道发送真实测试消息。

## 运行数据与分发

Bot Token、`.env`、浏览器资料、房间数据库、邀请、日志和生成的 ZIP 均被 Git 忽略。本地浏览器资料及数据库用于保留房主身份和房间，不应随意删除。

`Build-Portable.ps1` 生成的朋友包**包含本地 Bot Token，只能私下交给信任的人，不可作为公开 GitHub Release 上传**。公开仓库只有配置模板。

观看采用 WebRTC 直连，临时公网隧道提供网页和信令入口；当前集成不提供 TURN / SFU 媒体中转，跨网络播放取决于双方网络。每次重建隧道后域名可能变化，完整邀请持有者可以入房。

Piik 上游采用 MIT 许可证，原始声明保留在 [piik/server/LICENSE](piik/server/LICENSE)。本项目为独立的 Windows 与 KOOK 集成，不是 Piik 官方发行版。
