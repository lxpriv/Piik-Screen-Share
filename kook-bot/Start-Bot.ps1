$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\piik\launcher\Runtime.ps1"
$config = Get-Content -LiteralPath "$PSScriptRoot\config.local.json" -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $config.bot_token -and -not $env:KOOK_BOT_TOKEN) {
    Write-Warning 'Bot Token is missing. Fill kook-bot\config.local.json, then run Start-Bot.ps1.'
    return
}
$watchFile = "$PSScriptRoot\watch.mjs"
$pidFile = "$PSScriptRoot\data\watch.pid"
if (Test-Path -LiteralPath $pidFile) {
    $running = Get-CimInstance Win32_Process -Filter "ProcessId = $([int](Get-Content -LiteralPath $pidFile))"
    if ($running -and $running.CommandLine.Contains($watchFile)) {
        Write-Host 'KOOK invitation watcher is already running.'
        return
    }
}
New-Item -ItemType Directory -Path "$PSScriptRoot\data" -Force | Out-Null
Remove-Item -LiteralPath "$PSScriptRoot\data\stop-request.txt","$PSScriptRoot\data\activity.txt" -ErrorAction SilentlyContinue
$node = (Get-Command $piikNodeCommand -ErrorAction Stop).Source
$watch = Start-Process -FilePath $node -ArgumentList ('"{0}"' -f $watchFile) -WindowStyle Hidden -WorkingDirectory $PSScriptRoot -RedirectStandardOutput "$PSScriptRoot\data\watch.out.log" -RedirectStandardError "$PSScriptRoot\data\watch.err.log" -PassThru
$watch.Id | Set-Content -LiteralPath $pidFile
Write-Host 'KOOK watcher started. It sends only after a live preview and public health check.'
Write-Host "Logs: $PSScriptRoot\data\watch.err.log"
