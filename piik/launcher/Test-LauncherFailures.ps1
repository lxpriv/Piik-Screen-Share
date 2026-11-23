$ErrorActionPreference = 'Stop'
$workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$testRoot = Join-Path $workspace ('piik\data\launcher-failure-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$testRoot\piik\data" -Force | Out-Null
'12345678' | Set-Content -LiteralPath "$testRoot\piik\data\kook-user-id.txt" -Encoding ascii
$source = (Get-Content -LiteralPath "$PSScriptRoot\Launcher.cs" -Raw).Replace($workspace, $testRoot).Replace('Local\PiikScreenShareLauncher', ('Local\PiikFailureTest' + [guid]::NewGuid().ToString('N')))
[IO.File]::WriteAllText("$testRoot\Launcher.cs", $source, (New-Object Text.UTF8Encoding($false)))
"throw 'Simulated startup failure.'" | Set-Content -LiteralPath "$testRoot\piik\Start-Piik.ps1" -Encoding ascii
@'
if (Test-Path -LiteralPath "$PSScriptRoot\fail-stop") { throw 'Simulated cleanup failure.' }
if (Test-Path -LiteralPath "$PSScriptRoot\notification-pending") { Write-Warning 'KOOK_END_PENDING: Simulated notification failure.' }
Remove-Item -LiteralPath "$PSScriptRoot\data\server.pid" -ErrorAction SilentlyContinue
Write-Output 'Cleaned up.'
'@ | Set-Content -LiteralPath "$testRoot\piik\Stop-Piik.ps1" -Encoding ascii
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $compiler /nologo /target:winexe /codepage:65001 /reference:System.Windows.Forms.dll /reference:System.Drawing.dll "/out:$testRoot\LauncherFailure.exe" "$testRoot\Launcher.cs"
if ($LASTEXITCODE -ne 0) { throw 'Failure-check launcher compilation failed.' }
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class FailureCheckWindows {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindow(string className, string title);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string title);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    public static IntPtr Button(IntPtr window, string text) { return FindWindowEx(window, IntPtr.Zero, null, text); }
    public static IntPtr Dialog(string title) { return FindWindow("#32770", title); }
    public static IntPtr Confirm(IntPtr dialog) { return FindWindowEx(dialog, IntPtr.Zero, "Button", null); }
}
'@
function Wait-For($condition, $message) {
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if (& $condition) { return }
        Start-Sleep -Milliseconds 100
    }
    throw $message
}
function Click($button) {
    if ($button -eq [IntPtr]::Zero) { throw 'Test button missing.' }
    [FailureCheckWindows]::SendMessage($button, 0xF5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
}
function Dismiss($title) {
    Wait-For { [FailureCheckWindows]::Dialog($title) -ne [IntPtr]::Zero } "Expected error dialog: $title"
    Wait-For { [FailureCheckWindows]::Confirm([FailureCheckWindows]::Dialog($title)) -ne [IntPtr]::Zero } 'Error dialog button did not appear.'
    Click ([FailureCheckWindows]::Confirm([FailureCheckWindows]::Dialog($title)))
}
$app = $null
try {
    foreach ($scenario in 'startup-cleaned','startup-dirty','close-dirty','close-notification-pending') {
        Remove-Item -LiteralPath "$testRoot\piik\fail-stop" -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$testRoot\piik\notification-pending" -ErrorAction SilentlyContinue
        if ($scenario -in 'startup-dirty','close-dirty') { 'fail' | Set-Content -LiteralPath "$testRoot\piik\fail-stop" }
        if ($scenario -like 'close-*') { 'stale-pid' | Set-Content -LiteralPath "$testRoot\piik\data\server.pid" }
        if ($scenario -eq 'close-notification-pending') { 'pending' | Set-Content -LiteralPath "$testRoot\piik\notification-pending" }
        $app = Start-Process -FilePath "$testRoot\LauncherFailure.exe" -PassThru
        Wait-For { $app.Refresh(); $app.MainWindowHandle -ne [IntPtr]::Zero } 'Failure-check window did not open.'
        $window = $app.MainWindowHandle
        $start = [FailureCheckWindows]::Button($window, '开始')
        $stop = [FailureCheckWindows]::Button($window, '停止')
        if ($scenario -eq 'close-notification-pending') {
            [FailureCheckWindows]::PostMessage($window, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            if (-not $app.WaitForExit(10000)) { throw 'Notification failure must not prevent a locally cleaned launcher from exiting.' }
            continue
        }
        if ($scenario -eq 'close-dirty') {
            [FailureCheckWindows]::PostMessage($window, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            Dismiss '尚未完成停止'
        } else {
            Click $start
            Dismiss 'Piik 操作失败'
        }
        if ($scenario -eq 'startup-cleaned') {
            Wait-For { [FailureCheckWindows]::IsWindowEnabled($start) -and -not [FailureCheckWindows]::IsWindowEnabled($stop) } 'Cleaned startup failure must allow retrying Start only.'
        } else {
            Wait-For { -not [FailureCheckWindows]::IsWindowEnabled($start) -and [FailureCheckWindows]::IsWindowEnabled($stop) } 'Unfinished cleanup must allow Stop only.'
            $app.Refresh()
            if ($app.HasExited) { throw 'Window exited despite unfinished cleanup.' }
            Remove-Item -LiteralPath "$testRoot\piik\fail-stop"
            Click $stop
            Wait-For { [FailureCheckWindows]::IsWindowEnabled($start) -and -not [FailureCheckWindows]::IsWindowEnabled($stop) } 'Retrying Stop did not restore idle controls.'
        }
        [FailureCheckWindows]::PostMessage($window, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        if (-not $app.WaitForExit(5000)) { throw 'Idle window did not close immediately.' }
    }
    Write-Output 'PASS: startup failure, failed cleanup, failed close and successful Stop retry keep the correct controls.'
} finally {
    if ($app -and -not $app.HasExited) { Stop-Process -Id $app.Id }
    $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
    $allowedRoot = [IO.Path]::GetFullPath((Join-Path $workspace 'piik\data')) + '\'
    if (-not $resolvedTestRoot.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test cleanup path escaped workspace.' }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
