using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

internal static class Launcher
{
#if PORTABLE
    internal static readonly string Workspace = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(typeof(Launcher).Assembly.Location), ".."));
#else
    internal const string Workspace = @"D:\TOOLS\Piik_Screen_Share";
#endif
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindow(string className, string title);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);

    [STAThread]
    private static void Main()
    {
#if PORTABLE
        if (!File.Exists(Path.Combine(Workspace, @"piik\Start-Piik.ps1")) || !Directory.Exists(Path.Combine(Workspace, "kook-bot")))
        {
            MessageBox.Show("请先完整解压，再运行 piik 文件夹中的启动器。桌面请创建快捷方式，不要单独复制 EXE。", "Piik 屏幕共享");
            return;
        }
#endif
        bool first;
        using (var instance = new Mutex(true, @"Local\PiikScreenShareLauncher", out first))
        {
            if (!first)
            {
                var window = FindWindow(null, "Piik 屏幕共享");
                if (window != IntPtr.Zero) { ShowWindow(window, 9); SetForegroundWindow(window); }
                return;
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new ShareWindow());
        }
    }
}

internal sealed class ShareWindow : Form
{
    private readonly Button start = new Button();
    private readonly Button stop = new Button();
    private readonly Label status = new Label();
    private readonly Label hint = new Label();
    private readonly TextBox ownerId = new TextBox();
    private readonly ProgressBar progress = new ProgressBar();
    private readonly System.Windows.Forms.Timer monitor = new System.Windows.Forms.Timer { Interval = 2000 };
    private Task<bool> operation;
    private bool busy;
    private bool closing;
    private bool allowClose;
    private bool cleanupNeeded;
    private string failure;

    internal ShareWindow()
    {
        Text = "Piik 屏幕共享";
        ClientSize = new Size(512, 332);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.White;
        Font = new Font("Microsoft YaHei UI", 9F);
        AutoScaleMode = AutoScaleMode.Font;
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

        var title = new Label { Text = "Piik 屏幕共享", Location = new Point(24, 20), Size = new Size(464, 38), Font = new Font(Font.FontFamily, 18F, FontStyle.Bold) };
        hint.Location = new Point(24, 66);
        hint.Size = new Size(464, 42);
        hint.ForeColor = Color.FromArgb(90, 98, 112);
        var ownerLabel = new Label { Text = "KOOK ID（可选）", Location = new Point(24, 117), Size = new Size(112, 25) };
        ownerId.Name = "ownerIdInput";
        ownerId.Location = new Point(144, 113);
        ownerId.Size = new Size(344, 25);
        ownerId.MaxLength = 32;
        ownerId.TabIndex = 0;
        try { ownerId.Text = File.ReadAllText(OwnerIdFile).Trim(); } catch { }
        ownerId.TextChanged += delegate { if (!busy && !closing) { failure = null; RefreshState(); } };
        status.Name = "statusLabel";
        status.Location = new Point(24, 155);
        status.Size = new Size(464, 42);
        progress.Location = new Point(24, 205);
        progress.Size = new Size(464, 4);
        progress.Style = ProgressBarStyle.Marquee;
        progress.MarqueeAnimationSpeed = 30;
        progress.Visible = false;

        start.Name = "startButton";
        start.Text = "开始";
        start.Location = new Point(24, 223);
        start.TabIndex = 1;
        start.Size = new Size(224, 44);
        start.BackColor = Color.FromArgb(43, 100, 226);
        start.ForeColor = Color.White;
        start.FlatStyle = FlatStyle.Flat;
        start.FlatAppearance.BorderSize = 0;
        start.Click += async delegate { if (start.Enabled && !busy && !closing) { operation = ChangeAsync(true); await operation; } };

        stop.Name = "stopButton";
        stop.Text = "停止";
        stop.Location = new Point(264, 223);
        stop.TabIndex = 2;
        stop.Size = new Size(224, 44);
        stop.BackColor = Color.FromArgb(238, 241, 247);
        stop.FlatStyle = FlatStyle.Flat;
        stop.FlatAppearance.BorderSize = 0;
        stop.Click += async delegate { if (stop.Enabled && !busy && !closing) { operation = ChangeAsync(false); await operation; } };
        var footer = new Label { Text = "ID 会自动记住；留空则消息不显示分享者。\n关闭窗口会结束共享；最小化保持共享。", Location = new Point(24, 284), Size = new Size(464, 36), ForeColor = Color.FromArgb(116, 124, 138), Font = new Font(Font.FontFamily, 8.5F) };
        Controls.AddRange(new Control[] { title, hint, ownerLabel, ownerId, status, progress, start, stop, footer });
        RefreshState();
        monitor.Tick += delegate { RefreshState(); };
        monitor.Start();
        FormClosing += ClosingWindow;
        FormClosed += delegate { monitor.Dispose(); };
    }

    private string OwnerIdFile { get { return Path.Combine(Launcher.Workspace, @"piik\data\kook-user-id.txt"); } }
    private bool OwnerIdValid { get { return string.IsNullOrWhiteSpace(ownerId.Text) || System.Text.RegularExpressions.Regex.IsMatch(ownerId.Text.Trim(), @"^[0-9]{1,32}$"); } }

    private bool SaveOwnerId()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(OwnerIdFile));
            File.WriteAllText(OwnerIdFile, ownerId.Text.Trim(), new UTF8Encoding(false));
            return true;
        }
        catch (Exception error)
        {
            failure = "● 无法保存用户 ID，请检查文件夹写入权限";
            RefreshState();
            MessageBox.Show(this, error.Message, "Piik 配置保存失败", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }
    }

    private bool ServicesRunning()
    {
        return HasProcess("server", @"piik\server\piik-server.exe") && HasProcess("tunnel", @"piik\runtime\runtime\tunnel\cloudflared.exe");
    }

    private bool HasTrackedResources()
    {
        // PID files also cover partial starts and crashed services awaiting cleanup.
        return File.Exists(Path.Combine(Launcher.Workspace, @"piik\data\server.pid"))
            || File.Exists(Path.Combine(Launcher.Workspace, @"piik\data\tunnel.pid"))
            || File.Exists(Path.Combine(Launcher.Workspace, @"kook-bot\data\watch.pid"));
    }

    private string BotActivity()
    {
        try
        {
            int id = int.Parse(File.ReadAllText(Path.Combine(Launcher.Workspace, @"kook-bot\data\watch.pid")).Trim());
            using (var process = Process.GetProcessById(id))
                if (process.HasExited || process.ProcessName != "node") return "offline";
            var lines = File.ReadAllLines(Path.Combine(Launcher.Workspace, @"kook-bot\data\activity.txt"));
            return lines.Length >= 2 && lines[0] == id.ToString() ? lines[1] : "checking";
        }
        catch { return "offline"; }
    }

    private void RefreshState()
    {
        if (busy || closing) return;
        cleanupNeeded |= HasTrackedResources();
        bool running = ServicesRunning();
        string activity = running ? BotActivity() : "offline";
        bool bot = activity != "offline" && activity != "error";
        string runningStatus = "● 服务已启动，正在检查共享状态";
        switch (activity)
        {
            case "waiting": runningStatus = "● 等待你在浏览器中开始分享"; break;
            case "preparing": runningStatus = "● 正在准备共享画面"; break;
            case "inviting": runningStatus = "● 共享已开始，正在生成邀请"; break;
            case "publishing": runningStatus = "● 共享已开始，正在发送 KOOK 邀请"; break;
            case "sharing": runningStatus = "● 正在共享 · KOOK 邀请已发送"; break;
            case "ending": runningStatus = "● 共享已结束，正在移除邀请"; break;
            case "no-invite": runningStatus = "● 正在共享，但当前邀请已被撤销"; break;
            case "browser-error": runningStatus = "● 无法读取共享状态，请检查专用浏览器"; break;
            case "offline": case "error": runningStatus = "● 服务运行中，KOOK 通知异常"; break;
        }
        bool warning = failure != null || (cleanupNeeded && (!running || !bot || activity == "no-invite" || activity == "browser-error"));
        status.ForeColor = warning ? Color.FromArgb(180, 44, 44) : !cleanupNeeded ? Color.FromArgb(90, 98, 112) : activity == "sharing" ? Color.FromArgb(30, 126, 80) : Color.FromArgb(43, 100, 226);
        status.Text = failure ?? (running ? runningStatus : cleanupNeeded ? "● 连接已中断，请先停止清理" : "● 未启动");
        if (failure == null && !cleanupNeeded && !OwnerIdValid) status.Text = "● 用户 ID 请填写纯数字，或留空";
        hint.Text = failure != null ? "可查看刚才的错误提示或 piik\\logs\\launcher.log。\n" + (cleanupNeeded ? "请先点击“停止”完成清理，再重新开始。" : "可以点击“开始”重试。")
            : running && activity == "no-invite" ? "邀请已撤销，旧链接无法加入。\n请在浏览器中生成新邀请，或停止后重新开始。"
            : running && activity == "browser-error" ? "共享可能仍在继续，请检查专用浏览器。\n需要结束时点击“停止”。"
            : running && activity == "waiting" ? "在自动打开的浏览器中选择共享画面。\n若已关闭浏览器，请先停止，再重新开始。"
            : running && bot ? "在浏览器中选择、暂停或切换共享画面。\n点击“停止”结束共享并移除频道中的邀请链接。"
            : cleanupNeeded ? "请点击“停止”完成清理后重新开始。\n清理完成前不会重复启动后台服务。"
            : !OwnerIdValid ? "KOOK 设置 → 高级设置 → 开启开发者模式。\n右键自己的头像复制 ID，或清空输入框。"
            : string.IsNullOrWhiteSpace(ownerId.Text) ? "点击“开始”打开共享页面。\n未填写 ID：频道消息不显示分享者信息。"
            : "点击“开始”打开共享页面。\n选屏时默认勾选声音，可按需取消。";
        RefreshButtons();
    }

    private bool HasProcess(string name, string relativeExecutable)
    {
        try
        {
            int id = int.Parse(File.ReadAllText(Path.Combine(Launcher.Workspace, @"piik\data", name + ".pid")).Trim());
            using (var process = Process.GetProcessById(id))
                return !process.HasExited && string.Equals(process.MainModule.FileName, Path.Combine(Launcher.Workspace, relativeExecutable), StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    private void RefreshButtons()
    {
        start.Enabled = !busy && !closing && !cleanupNeeded && OwnerIdValid;
        stop.Enabled = !busy && !closing && cleanupNeeded;
        ownerId.Enabled = !busy && !closing && !cleanupNeeded;
        progress.Visible = busy || closing;
        UseWaitCursor = busy || closing;
        start.BackColor = start.Enabled ? Color.FromArgb(43, 100, 226) : Color.FromArgb(225, 229, 237);
        start.ForeColor = start.Enabled ? Color.White : Color.FromArgb(155, 162, 175);
        stop.BackColor = stop.Enabled ? Color.FromArgb(238, 241, 247) : Color.FromArgb(247, 248, 250);
        stop.ForeColor = stop.Enabled ? Color.FromArgb(40, 50, 70) : Color.FromArgb(155, 162, 175);
    }

    private async Task<bool> ChangeAsync(bool starting)
    {
        if (busy || (starting && (closing || cleanupNeeded || !OwnerIdValid)) || (!starting && !cleanupNeeded)) return false;
        if (starting && !SaveOwnerId()) return false;
        busy = true;
        cleanupNeeded = true;
        failure = null;
        status.ForeColor = Color.FromArgb(70, 82, 108);
        status.Text = starting ? "● 正在启动，请稍候…" : "● 正在停止并更新邀请…";
        hint.Text = starting ? "正在连接公网入口并启动共享服务。\n就绪后会自动打开浏览器，请稍候。" : "正在结束浏览器采集、更新频道消息并关闭服务。\n请等待完成后再重新开始。";
        RefreshButtons();
        try
        {
            var result = await Task.Run(() => RunScript(starting ? "Start-Piik.ps1" : "Stop-Piik.ps1"));
            if (result.Success && (starting ? !ServicesRunning() : HasTrackedResources()))
                result = new ScriptResult { Success = false, Detail = "脚本已退出，但后台服务状态不符合预期。请查看日志并重试停止清理。" };
            if (starting && !result.Success)
            {
                status.Text = "● 启动失败，正在清理…";
                var cleanup = await Task.Run(() => RunScript("Stop-Piik.ps1"));
                cleanupNeeded = !cleanup.Success || HasTrackedResources();
                if (!cleanup.Success) result.Detail += "\n\n清理未完成：" + cleanup.Detail;
            }
            if (!starting) cleanupNeeded = !result.Success;
            if (!result.Success) failure = starting ? (cleanupNeeded ? "● 启动失败，请先停止清理" : "● 启动失败，可以重试") : "● 停止未完成，请重试停止";
            if (!result.Success && !closing)
                MessageBox.Show(this, result.Detail + "\n\n日志：piik\\logs\\launcher.log", "Piik 操作失败", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return result.Success;
        }
        finally { busy = false; RefreshButtons(); RefreshState(); }
    }

    private async void ClosingWindow(object sender, FormClosingEventArgs args)
    {
        if (allowClose) return;
        args.Cancel = true;
        if (closing) return;
        closing = true;
        RefreshButtons();
        status.Text = busy ? "● 正在等待当前操作完成，随后自动停止…" : "● 正在关闭，请稍候…";
        if (operation != null) await operation;
        if (cleanupNeeded || HasTrackedResources())
        {
            cleanupNeeded = true;
            operation = ChangeAsync(false);
            if (!await operation)
            {
                closing = false;
                RefreshState();
                MessageBox.Show(this, "关闭脚本执行失败，窗口暂不退出。请重试“停止”，或查看 piik\\logs\\launcher.log。", "尚未完成停止", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
        }
        if (OwnerIdValid && !SaveOwnerId()) { closing = false; RefreshState(); return; }
        allowClose = true;
        Close();
    }

    private sealed class ScriptResult
    {
        internal bool Success;
        internal string Detail;
    }

    private static ScriptResult RunScript(string name)
    {
        try
        {
            string script = Path.Combine(Launcher.Workspace, "piik", name);
            if (!File.Exists(script)) throw new FileNotFoundException("找不到工作区中的脚本，请保留原工作区位置。", script);
            string actionLog = Path.Combine(Launcher.Workspace, @"piik\logs\launcher-action.log");
            Directory.CreateDirectory(Path.GetDirectoryName(actionLog));
            // Detached Chrome processes can inherit stdout pipes. Capture to a file so their lifetime cannot block the UI.
            string quotedLog = "'" + actionLog.Replace("'", "''") + "'";
            string command = "try { & '" + script.Replace("'", "''") + "' *> " + quotedLog + "; if (-not $?) { exit 1 } } catch { $_ | Out-String | Add-Content -LiteralPath " + quotedLog + " -Encoding Unicode; exit 1 }";
            var info = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"" + command + "\"",
                WorkingDirectory = Path.Combine(Launcher.Workspace, "piik"),
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using (var process = Process.Start(info))
            {
                process.WaitForExit();
                string detail = File.Exists(actionLog) ? File.ReadAllText(actionLog).Trim() : "";
                string log = Path.Combine(Launcher.Workspace, @"piik\logs\launcher.log");
                Directory.CreateDirectory(Path.GetDirectoryName(log));
                File.AppendAllText(log, DateTimeOffset.Now.ToString("u") + " " + name + " exit=" + process.ExitCode + "\n" + detail + "\n\n", new UTF8Encoding(false));
                return new ScriptResult { Success = process.ExitCode == 0, Detail = detail.Length > 1800 ? detail.Substring(detail.Length - 1800) : detail };
            }
        }
        catch (Exception error) { return new ScriptResult { Success = false, Detail = error.Message }; }
    }
}
