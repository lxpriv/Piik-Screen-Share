param([switch]$CloseDuringStart, [switch]$InterruptTunnel, [switch]$LivePreview, [switch]$CloseWhileRunning, [switch]$CloseDuringStop, [string]$OwnerUserId, [switch]$Anonymous, [switch]$CloseBrowserFirst)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$PSScriptRoot\Runtime.ps1"
$localPort = Get-PiikLocalPort
$localOrigin = "http://localhost:$localPort"
$localOrigins = @($localOrigin, "http://127.0.0.1:$localPort")
$exe = Join-Path $workspace 'piik\Piik-Screen-Share.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw 'Launcher EXE does not exist yet.' }
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class LauncherTestWindows {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string title);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr window);
    public static IntPtr FindButton(IntPtr parent, string title) { return FindWindowEx(parent, IntPtr.Zero, null, title); }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int size);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")] static extern IntPtr ReadText(IntPtr window, uint message, IntPtr size, StringBuilder text);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")] public static extern IntPtr SetText(IntPtr window, uint message, IntPtr wparam, string text);
    public static string Text(IntPtr window) { var text = new StringBuilder(128); ReadText(window, 0xD, (IntPtr)text.Capacity, text); return text.ToString(); }
    public static IntPtr OwnerInput(IntPtr parent) {
        for (var child=FindWindowEx(parent,IntPtr.Zero,null,null); child!=IntPtr.Zero; child=FindWindowEx(parent,child,null,null)) {
            var name = new StringBuilder(256); GetClassName(child,name,name.Capacity);
            if (name.ToString().Contains("EDIT")) return child;
        }
        return IntPtr.Zero;
    }
}
'@

function Find-Control($window, $id) {
    $caption = if ($id -eq 'startButton') { ([char]0x5F00).ToString() + [char]0x59CB } else { ([char]0x505C).ToString() + [char]0x6B62 }
    return [LauncherTestWindows]::FindButton($window, $caption)
}
function Invoke-Control($window, $id) {
    $control = Find-Control $window $id
    if ($control -eq [IntPtr]::Zero) { throw "Control not found: $id" }
    [LauncherTestWindows]::SendMessage($control, 0xF5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
}
function Wait-Until($condition, $seconds, $message) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $condition) { return }
        Start-Sleep -Milliseconds 200
    }
    throw $message
}
function Piik-IsRunning {
    foreach ($name in 'server','tunnel') {
        $file = Join-Path $workspace "piik\data\$name.pid"
        if (Test-Path -LiteralPath $file) {
            $recordedId = [int](Get-Content -LiteralPath $file)
            if (Get-Process -Id $recordedId -ErrorAction SilentlyContinue) { return $true }
        }
    }
    return $false
}
if (Piik-IsRunning) { throw 'Stop the existing Piik session before running this integration check.' }
$app = Start-Process -FilePath $exe -PassThru
try {
    Wait-Until { $app.Refresh(); $app.MainWindowHandle -ne [IntPtr]::Zero } 10 'Launcher window did not open.'
    $window = $app.MainWindowHandle
    $ownerInput = [LauncherTestWindows]::OwnerInput($window)
    if ($ownerInput -eq [IntPtr]::Zero) { throw 'KOOK account input is missing.' }
    if ($Anonymous) { [LauncherTestWindows]::SetText($ownerInput, 0xC, [IntPtr]::Zero, '') | Out-Null }
    if ([string]::IsNullOrWhiteSpace([LauncherTestWindows]::Text($ownerInput))) {
        if (-not [LauncherTestWindows]::IsWindowEnabled((Find-Control $window 'startButton'))) { throw 'An empty ID must allow anonymous sharing.' }
        [LauncherTestWindows]::SetText($ownerInput, 0xC, [IntPtr]::Zero, 'invalid-id') | Out-Null
        if ([LauncherTestWindows]::IsWindowEnabled((Find-Control $window 'startButton'))) { throw 'Invalid user IDs must not enable Start.' }
        $binding = if ($Anonymous) { '' } else { $OwnerUserId }
        [LauncherTestWindows]::SetText($ownerInput, 0xC, [IntPtr]::Zero, $binding) | Out-Null
    }
    $expectedBinding = [LauncherTestWindows]::Text($ownerInput).Trim()
    if (-not [LauncherTestWindows]::IsWindowEnabled((Find-Control $window 'startButton'))) { throw 'Start should be enabled when services are stopped.' }
    if ([LauncherTestWindows]::IsWindowEnabled((Find-Control $window 'stopButton'))) { throw 'Stop should be disabled when services are stopped.' }
    Invoke-Control $window 'stopButton'
    if (Piik-IsRunning) { throw 'Disabled Stop changed the idle state.' }
    Invoke-Control $window 'startButton'
    if ([LauncherTestWindows]::IsWindowEnabled((Find-Control $window 'startButton')) -or [LauncherTestWindows]::IsWindowEnabled((Find-Control $window 'stopButton'))) { throw 'Both buttons must be disabled during startup.' }
    Invoke-Control $window 'startButton'
    if ($CloseDuringStart) {
        Start-Sleep -Milliseconds 300
        [LauncherTestWindows]::PostMessage($window, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        Wait-Until { $app.Refresh(); $app.HasExited } 90 'Closing during startup did not finish.'
    } else {
        Wait-Until { (Piik-IsRunning) -and [LauncherTestWindows]::IsWindowEnabled((Find-Control $window 'stopButton')) } 75 'Start did not reach a usable running state.'
        if (-not (Piik-IsRunning)) { throw 'Start button did not start the services.' }
        if ([LauncherTestWindows]::IsWindowEnabled((Find-Control $window 'startButton'))) { throw 'Start should be disabled while services are running.' }
        if ([LauncherTestWindows]::IsWindowEnabled($ownerInput)) { throw 'Account binding must not change while sharing services run.' }
        $duplicate = Start-Process -FilePath $exe -PassThru
        if (-not $duplicate.WaitForExit(5000)) { throw 'Opening again should focus the existing window without a blocking prompt.' }
        if ($LivePreview) {
            & node.exe (Join-Path $PSScriptRoot 'fixtures\cdp.mjs') $localOrigin (Join-Path $PSScriptRoot 'fixtures\start-test-preview.js') | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not prepare synthetic preview.' }
            & node.exe (Join-Path $PSScriptRoot 'fixtures\cdp.mjs') $localOrigin (Join-Path $PSScriptRoot 'fixtures\choose-test-preview.js') | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not start synthetic preview.' }
            Wait-Until { [LauncherTestWindows]::FindButton($window, '● 正在共享 · KOOK 邀请已发送') -ne [IntPtr]::Zero } 60 'Launcher did not confirm live preview and KOOK publication.'
        }
        if ($CloseBrowserFirst) {
            & node.exe (Join-Path $PSScriptRoot 'fixtures\close-test-browser.mjs')
            if ($LASTEXITCODE -ne 0) { throw 'Could not close the test browser first.' }
        }
        if ($InterruptTunnel) {
            $tunnelId = [int](Get-Content -LiteralPath (Join-Path $workspace 'piik\data\tunnel.pid'))
            $tunnelProcess = Get-Process -Id $tunnelId
            if ($tunnelProcess.Path -ne (Join-Path $workspace 'piik\runtime\runtime\tunnel\cloudflared.exe')) { throw 'Unexpected tunnel process; refusing fault injection.' }
            Stop-Process -Id $tunnelId -ErrorAction Stop
            Wait-Until { [LauncherTestWindows]::FindButton($window, '● 连接已中断，请先停止清理') -ne [IntPtr]::Zero } 10 'Launcher did not notice the interrupted tunnel.'
            if ([LauncherTestWindows]::IsWindowEnabled((Find-Control $window 'startButton')) -or -not [LauncherTestWindows]::IsWindowEnabled((Find-Control $window 'stopButton'))) { throw 'Interrupted services must allow only cleanup.' }
        }
        if ($CloseWhileRunning) {
            [LauncherTestWindows]::PostMessage($window, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            Wait-Until { $app.Refresh(); $app.HasExited } 90 'Closing while running did not clean up.'
        } else {
        Invoke-Control $window 'stopButton'
        if ([LauncherTestWindows]::IsWindowEnabled((Find-Control $window 'startButton')) -or [LauncherTestWindows]::IsWindowEnabled((Find-Control $window 'stopButton'))) { throw 'Both buttons must be disabled during shutdown.' }
        Invoke-Control $window 'stopButton'
        if ($CloseDuringStop) {
            [LauncherTestWindows]::PostMessage($window, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            Wait-Until { $app.Refresh(); $app.HasExited } 90 'Closing during shutdown did not finish.'
        } else {
        Wait-Until { [LauncherTestWindows]::IsWindowEnabled((Find-Control $window 'startButton')) } 40 'Stop did not finish.'
        if (Piik-IsRunning) { throw 'Stop left a Piik process running.' }
        if ([LauncherTestWindows]::IsWindowEnabled((Find-Control $window 'stopButton'))) { throw 'Stop should be disabled after successful shutdown.' }
        [LauncherTestWindows]::PostMessage($window, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        Wait-Until { $app.Refresh(); $app.HasExited } 10 'Window did not close after Stop.'
        }
        }
    }
    if (Piik-IsRunning) { throw 'Closing left a Piik service running.' }
    if (Test-Path -LiteralPath (Join-Path $workspace 'kook-bot\data\watch.pid')) { throw 'Closing left the bot watcher running.' }
    try {
        $targets = Invoke-RestMethod http://127.0.0.1:9227/json/list -TimeoutSec 3
        $hosts = @($targets | Where-Object { $url = [Uri]$_.url; $_.type -eq 'page' -and $localOrigins -contains $url.GetLeftPart([UriPartial]::Authority) -and $url.AbsolutePath -eq '/' })
        if ($hosts.Count) { throw 'Closing left a Piik Host page able to keep capturing.' }
    } catch {
        if ($_.Exception.Message -like '*Host page*') { throw }
        # A closed dedicated Chrome process also ends all its capture pages.
    }
    if (-not $CloseDuringStart) {
        $app = Start-Process -FilePath $exe -PassThru
        Wait-Until { $app.Refresh(); $app.MainWindowHandle -ne [IntPtr]::Zero } 10 'Reopened launcher did not appear.'
        Wait-Until { [LauncherTestWindows]::OwnerInput($app.MainWindowHandle) -ne [IntPtr]::Zero } 5 'Reopened account field did not appear.'
        $inputAgain = [LauncherTestWindows]::OwnerInput($app.MainWindowHandle)
        Wait-Until { [LauncherTestWindows]::Text($inputAgain) -eq $expectedBinding } 5 'Launcher did not restore the previous ID.'
        if ($expectedBinding) { [LauncherTestWindows]::SetText($inputAgain, 0xC, [IntPtr]::Zero, '') | Out-Null }
        [LauncherTestWindows]::PostMessage($app.MainWindowHandle, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        Wait-Until { $app.Refresh(); $app.HasExited } 10 'Idle reopened launcher did not close.'
        if ($expectedBinding) {
            $app = Start-Process -FilePath $exe -PassThru
            Wait-Until { $app.Refresh(); $app.MainWindowHandle -ne [IntPtr]::Zero } 10 'Launcher did not reopen after clearing ID.'
            Wait-Until { [LauncherTestWindows]::OwnerInput($app.MainWindowHandle) -ne [IntPtr]::Zero } 5 'Cleared account field did not appear.'
            $inputAgain = [LauncherTestWindows]::OwnerInput($app.MainWindowHandle)
            if ([LauncherTestWindows]::Text($inputAgain) -ne '') { throw 'Clearing the ID was not remembered.' }
            [LauncherTestWindows]::SetText($inputAgain, 0xC, [IntPtr]::Zero, $expectedBinding) | Out-Null
            [LauncherTestWindows]::PostMessage($app.MainWindowHandle, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            Wait-Until { $app.Refresh(); $app.HasExited } 10 'Preference check did not close.'
        }
    }
    Write-Output "PASS: ID recall/clearing, button guards, single instance and cleanup (Anonymous=$Anonymous, CloseDuringStart=$CloseDuringStart, InterruptTunnel=$InterruptTunnel, LivePreview=$LivePreview, CloseWhileRunning=$CloseWhileRunning, CloseDuringStop=$CloseDuringStop)"
} finally {
    if (-not $app.HasExited) { Stop-Process -Id $app.Id -ErrorAction SilentlyContinue }
    if (Piik-IsRunning) { & (Join-Path $workspace 'piik\Stop-Piik.ps1') }
}
