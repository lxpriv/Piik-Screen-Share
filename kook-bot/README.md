# KOOK 邀请通知机器人

检测 Piik 房主预览，检查当前公网地址，再把真实观众邀请发送到指定 KOOK 文字频道。使用 Node.js 内置 `fetch` 和 `WebSocket`，无需安装 npm 依赖或 KOOK SDK。

## 配置

1. 在 [KOOK 开发者中心](https://developer.kookapp.cn/app/index) 创建机器人，将机器人邀请到自己的服务器。
2. 将 `config.example.json` 复制为 `config.local.json`，填写 `bot_token`、`guild_name`、`channel_name` 和 `channel_id`。机器人需要查看及发布目标文字频道的权限。
3. 完成 [项目配置](../README.md#首次配置)，通过 `piik/Piik-Screen-Share.exe` 或 `piik/Start-Piik.ps1` 启动整套服务。

`config.local.json` 被 Git 忽略。也可通过 `KOOK_BOT_TOKEN` 环境变量覆盖 Token，仍需本地 JSON 提供频道配置。改变 Token 或频道后重启机器人。

启动器的 KOOK 用户 ID 可选，保存在 `piik/data/kook-user-id.txt`。填写后每次发送或结束消息时查询目标服务器中的当前昵称，留空则不署名，不会自动 @ 用户。

## 消息文案

编辑 `messages.json`，每个字符串为一行，发送或编辑时重新加载：

- `start` 为开播文案，必须保留 `{invite}`。
- `{owner}` 替换为当前服务器昵称。建议单独一行，未配置用户 ID 时该行自动省略。
- `end` 为结束文案，不应包含 `{invite}` 或网址。
- 支持 KMarkdown，如 `**标题**`、`[进入共享]({invite})`。

## 行为

- 每 2 秒检查专用浏览器；只有预览就绪且公网健康检查通过才发送。不会读取或发送房主 Token。
- 发送保留完整 `#v=` 观众凭据的邀请，并提示在系统浏览器打开。
- 最近一条消息以频道、完整邀请和分享者 ID 去重；持续共享不重复发送，同一邀请恢复时编辑原消息。
- 切换域名或邀请时，先移除旧入口再创建新通知。停止共享或关闭房主页面，连续 3 次确认后编辑原消息并移除链接。
- `Stop-Piik.ps1` 先停止采集，等待正在发送的请求保存消息 ID，再结束通知及服务。清理失败会保留状态供重试。
- 网络或 API 错误写入 `data/watch.err.log`。突然断电时无法立即更新远端消息；联网后可再次停止或运行 `node bot.mjs --expire`。

完整邀请持有者可以入房，请设置合适的频道可见范围。Piik 升级后应复核 `browser.mjs` 的页面选择器，当前适配版本为 v2.8.0。

## 单独运行和验证

```powershell
# 模拟请求测试，不发送真实消息
node test.mjs
node test-browser.mjs
node test-watch.mjs

# 以下命令需要已配置的本机服务 / 机器人
powershell -ExecutionPolicy Bypass -File Start-Bot.ps1
node bot.mjs --check-owner  # 只读核对昵称和目标
node bot.mjs --check        # 核对当前邀请，预览发送结果
powershell -ExecutionPolicy Bypass -File Stop-Bot.ps1 -Expire
```

`Stop-Bot.ps1` 只停止自动通知；加 `-Expire` 同时移除最近消息的邀请入口。整套服务请用 `piik/Stop-Piik.ps1` 停止。

## 文件

| 文件 | 用途 |
| --- | --- |
| `bot.mjs` | 目标核对、HTTP 发布、结束编辑及去重 |
| `browser.mjs` | 专用浏览器状态读取、邀请更新和采集页关闭 |
| `watch.mjs` | 后台监视及生命周期联动 |
| `Start-Bot.ps1` / `Stop-Bot.ps1` | 启停脚本 |
| `messages.json` | 消息模板 |
| `config.example.json` | 可公开的空配置模板 |
| `data/` | 本地消息记录、阶段状态及日志，不上传 |

接口参考：[鉴权](https://developer.kookapp.cn/doc/reference)、[频道消息](https://developer.kookapp.cn/doc/http/message)、[频道](https://developer.kookapp.cn/doc/http/channel)、[KMarkdown](https://developer.kookapp.cn/doc/kmarkdown)。
