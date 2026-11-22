# Piik Windows 启动器

在仓库根目录完成 [首次配置](../README.md#首次配置) 后，双击 `Piik-Screen-Share.exe`，或运行 `Start-Piik.ps1`。

## 日常使用

- **开始**：启动 Piik、临时公网隧道和 KOOK 监视器，打开独立 Chrome / Edge。选好画面且公网检查通过后，机器人自动发送当前邀请。
- **停止**：关闭专用浏览器中的房主采集页，移除 KOOK 消息中的链接，关闭后台服务。观众页和其他网页保留。
- **关闭窗口**：等待当前操作并完成停止；清理失败时保留窗口供重试。最小化保持共享。
- **KOOK 用户 ID**：可选；填写后消息显示该用户当前服务器昵称，留空不署名。偏好只保存在本机 `data/kook-user-id.txt`。

新建专用浏览器资料默认私密、无密码。完整观众邀请可免密码加入；仅凭房间号不能加入。选屏弹窗默认勾选浏览器支持的声音选项，仍需用户确认，不会自动开启麦克风。

状态每 2 秒从本地进程和监视器记录更新，不代表所有异地观众都已连接。当前集成使用 WebRTC 直连，不提供 TURN / SFU 媒体中转。

## 编译与便携包

```powershell
# 推荐：相对于 EXE 所在目录查找工作区，可放在任意路径
powershell -ExecutionPolicy Bypass -File launcher/Build.ps1 -Portable

# 私人朋友包：需先配置自己的 Bot Token、频道和全部运行程序
powershell -ExecutionPolicy Bypass -File launcher/Build-Portable.ps1 -NodeExecutable (Get-Command node.exe).Source
```

编译使用 `source/public/favicon.ico`，因此需要先按 [补丁说明](server/LOCAL-PATCH.md) 准备上游源码。未指定 `-Portable` 的本机模式使用源码中固定的 `D:\TOOLS\Piik_Screen_Share` 路径，适合原工作区，其他目录请使用 `-Portable`。

朋友包包含 Node.js、服务、隧道和配置好的共享机器人，**也包含可读取的 Bot Token，只能私下分发**。不包含原机房主身份、浏览器资料、旧房间或消息历史。完整解压后运行，桌面入口应使用快捷方式；详见 [便携版说明](launcher/PORTABLE-README.zh-CN.md)。

## 本地文件

| 路径 | 用途 |
| --- | --- |
| `server/.env` | 从 `.env.example` 复制的本机配置 |
| `server/piik-server.exe` | 含邀请兼容补丁的 Piik v2.8.0 服务 |
| `runtime/runtime/tunnel/cloudflared.exe` | 临时公网隧道 |
| `data/browser-profile/`、`data/rooms.sqlite` | 房主身份、偏好及房间，请保留 |
| `data/public-url.txt`、`data/invite-url.txt` | 当前运行地址和完整邀请，勿公开 |
| `logs/` | 启动器、服务及隧道日志 |
| `source/`、`build/`、`build-tools/` | 本机上游检出、补丁工作区和构建工具，不上传 |
| `releases/` | 生成的私人便携包，不上传 |

临时域名重建后可能变化。监视器读取实际房主页的完整邀请，不使用历史地址。

## 验收

隔离检查，不访问 KOOK：

```powershell
powershell -ExecutionPolicy Bypass -File launcher/Test-LauncherFailures.ps1
powershell -ExecutionPolicy Bypass -File launcher/Test-Shutdown.ps1
```

完整本机联动检查需先结束已有共享：

```powershell
powershell -ExecutionPolicy Bypass -File launcher/Test-Launcher.ps1
powershell -ExecutionPolicy Bypass -File launcher/Test-Launcher.ps1 -CloseDuringStart
powershell -ExecutionPolicy Bypass -File launcher/Test-Launcher.ps1 -CloseWhileRunning
powershell -ExecutionPolicy Bypass -File launcher/Test-Launcher.ps1 -CloseDuringStop
```

`Test-Launcher.ps1 -LivePreview` 使用 `launcher/fixtures/` 的合成画面，向配置的 KOOK 频道发送真实邀请；`Test-Portable.ps1` 解压朋友包并执行同类联动验收。运行前确认目标频道。机器人配置见 [机器人说明](../kook-bot/README.md)。
