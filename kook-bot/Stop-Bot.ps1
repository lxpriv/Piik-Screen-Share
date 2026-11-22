param([switch]$Expire)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\piik\launcher\Runtime.ps1"
$pidFile = "$PSScriptRoot\data\watch.pid"
if (Test-Path -LiteralPath $pidFile) {
    $watchId = 0
    if ([int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$watchId) -and $watchId -gt 0) {
        $running = Get-CimInstance Win32_Process -Filter "ProcessId = $watchId"
        if ($running -and $running.CommandLine -and $running.CommandLine.Contains("$PSScriptRoot\watch.mjs")) {
            # Let an in-flight send save its message ID before expiring it; force-killing can leave an untracked live link.
            Set-Content -LiteralPath "$PSScriptRoot\data\stop-request.txt" -Value $watchId -Encoding ascii
            $watchProcess = Get-Process -Id $watchId -ErrorAction SilentlyContinue
            if ($watchProcess -and -not $watchProcess.WaitForExit(60000)) { throw 'KOOK watcher is still completing a request. Sharing shutdown will continue; retry Stop shortly.' }
        }
    }
    Remove-Item -LiteralPath $pidFile
}
if ($Expire) {
    & $piikNodeCommand "$PSScriptRoot\bot.mjs" --expire
    if ($LASTEXITCODE -ne 0) { throw 'Could not mark the KOOK invitation ended. Retry Stop after restoring connectivity.' }
}
Write-Host 'KOOK invitation watcher stopped.'
