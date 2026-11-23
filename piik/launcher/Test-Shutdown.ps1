$ErrorActionPreference = 'Stop'
$workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$testRoot = Join-Path $workspace ('piik\data\shutdown-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$testRoot\piik\data","$testRoot\piik\launcher","$testRoot\kook-bot\data" -Force | Out-Null
Copy-Item -LiteralPath "$PSScriptRoot\Runtime.ps1" -Destination "$testRoot\piik\launcher\Runtime.ps1"
Copy-Item -LiteralPath "$workspace\piik\Stop-Piik.ps1" -Destination "$testRoot\piik\Stop-Piik.ps1"
Copy-Item -LiteralPath "$workspace\kook-bot\Stop-Bot.ps1" -Destination "$testRoot\kook-bot\Stop-Bot.ps1"
# Isolate network/capture failures. All PID files and scripts belong to this disposable workspace.
function node.exe {
    $global:shutdownTestNodeCalls++
    $global:LASTEXITCODE = if ($args[0] -like '*Stop-Browser.mjs') { $global:shutdownTestCaptureExit } else { $global:shutdownTestNotificationExit }
}
try {
    foreach ($scenario in @(@(0,0), @(1,0), @(0,1), @(1,1))) {
        $global:shutdownTestCaptureExit = $scenario[0]
        $global:shutdownTestNotificationExit = $scenario[1]
        $global:shutdownTestNodeCalls = 0
        # A reused PID must never cause shutdown to kill an unrelated process (this test shell).
        $PID | Set-Content -LiteralPath "$testRoot\piik\data\server.pid"
        'corrupted-pid' | Set-Content -LiteralPath "$testRoot\piik\data\tunnel.pid"
        'corrupted-pid' | Set-Content -LiteralPath "$testRoot\kook-bot\data\watch.pid"
        $failure = $null
        try { & "$testRoot\piik\Stop-Piik.ps1" | Out-Null } catch { $failure = $_.Exception.Message }
        if ($global:shutdownTestNodeCalls -ne 2) { throw 'Shutdown skipped capture or notification cleanup.' }
        if (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.pid' -Recurse).Count) { throw 'Shutdown left stale PID files.' }
        if ($global:shutdownTestCaptureExit -and -not $failure) { throw 'Failed capture cleanup was reported as success.' }
        if (-not $global:shutdownTestCaptureExit -and $failure) { throw $failure }
        if ($global:shutdownTestCaptureExit -and $failure -notlike '*capture page*') { throw 'Capture failure was hidden.' }
    }
    Write-Output 'PASS: shutdown completes remaining cleanup on capture/KOOK failures; stale/reused PIDs are safe.'
} finally {
    Remove-Item Function:\node.exe
    Remove-Variable -Name shutdownTestNodeCalls,shutdownTestCaptureExit,shutdownTestNotificationExit -Scope Global
    $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
    $allowedRoot = [IO.Path]::GetFullPath((Join-Path $workspace 'piik\data')) + '\'
    if (-not $resolvedTestRoot.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test cleanup path escaped workspace.' }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
