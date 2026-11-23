$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
. "$PSScriptRoot\launcher\Runtime.ps1"
$browser = Get-PiikBrowser
$localPort = Get-PiikLocalPort
$localOrigin = "http://127.0.0.1:$localPort"
$browserOrigin = "http://localhost:$localPort"
foreach ($requiredPath in @("$PSScriptRoot\server\piik-server.exe", "$PSScriptRoot\runtime\runtime\tunnel\cloudflared.exe")) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "Required program is missing: $requiredPath" }
}
Get-Command $piikNodeCommand -ErrorAction Stop | Out-Null
& $piikNodeCommand "$PSScriptRoot\..\kook-bot\bot.mjs" --check-owner
if ($LASTEXITCODE -ne 0) { throw 'KOOK member lookup failed. Check the bound user ID and network.' }
$browserArguments = @('--remote-debugging-address=127.0.0.1','--remote-debugging-port=9227',('--user-data-dir="{0}\data\browser-profile"' -f $PSScriptRoot),'--system-audio-capture-default_checked','--no-first-run','--no-default-browser-check',$browserOrigin)
if (Test-Path -LiteralPath 'data/server.pid') {
    $serverId = [int](Get-Content -LiteralPath 'data/server.pid')
    $existing = Get-Process -Id $serverId -ErrorAction SilentlyContinue
    if ($existing -and $existing.Path -eq "$PSScriptRoot\server\piik-server.exe") {
        Start-Process -FilePath $browser -ArgumentList $browserArguments
        & $piikNodeCommand "$PSScriptRoot\launcher\Initialize-Browser.mjs"
        if ($LASTEXITCODE -ne 0) { throw 'Browser setup failed. See the launcher log.' }
        & "$PSScriptRoot\..\kook-bot\Start-Bot.ps1"
        Write-Host "Piik is already running: $(Get-Content -LiteralPath data/public-url.txt)"
        exit
    }
}
New-Item -ItemType Directory -Path logs,data -Force | Out-Null
$probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $localPort)
try { $probe.Start() } catch { throw "Local port $localPort is unavailable or reserved by Windows. Change PORT in piik/server/.env. $($_.Exception.GetBaseException().Message)" } finally { $probe.Stop() }
Set-Content -LiteralPath data/tunnel.yml -Value "url: $localOrigin" -Encoding ascii
$tunnel = Start-Process "$PSScriptRoot\runtime\runtime\tunnel\cloudflared.exe" -ArgumentList 'tunnel','--config',('"{0}\data\tunnel.yml"' -f $PSScriptRoot),'--no-autoupdate','--protocol','http2','--url',$localOrigin -WindowStyle Hidden -RedirectStandardOutput "$PSScriptRoot\logs\tunnel.out.log" -RedirectStandardError "$PSScriptRoot\logs\tunnel.err.log" -PassThru
$tunnel.Id | Set-Content -LiteralPath data/tunnel.pid
try {
    $deadline = (Get-Date).AddSeconds(45)
    do {
        Start-Sleep -Milliseconds 500
        if ($tunnel.HasExited) { throw 'Tunnel exited. See logs/tunnel.err.log.' }
        $tunnelLog = Get-Content -LiteralPath logs/tunnel.err.log -Raw
        $origin = [regex]::Match($tunnelLog, 'https://[a-z0-9-]+\.trycloudflare\.com').Value
    } until (($origin -and $tunnelLog.Contains('Registered tunnel connection')) -or (Get-Date) -gt $deadline)
    if (-not $origin -or -not $tunnelLog.Contains('Registered tunnel connection')) { throw 'Tunnel timed out. See logs/tunnel.err.log.' }
    $config = Get-Content -LiteralPath server/.env
    $config = $config -replace '^PUBLIC_BASE_URL=.*', "PUBLIC_BASE_URL=$origin"
    $config = $config -replace '^ALLOWED_ORIGINS=.*', "ALLOWED_ORIGINS=$origin,$browserOrigin,$localOrigin"
    $config = $config -replace '^ROOM_DATABASE_PATH=.*', "ROOM_DATABASE_PATH=$($PSScriptRoot.Replace('\','/'))/data/rooms.sqlite"
    [IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'server\.env'), $config, (New-Object Text.UTF8Encoding($false)))
    Push-Location server
    try { & .\piik-server.exe --check-config; if ($LASTEXITCODE -ne 0) { throw 'Invalid Piik configuration' } } finally { Pop-Location }
    $server = Start-Process "$PSScriptRoot\server\piik-server.exe" -WorkingDirectory "$PSScriptRoot\server" -WindowStyle Hidden -RedirectStandardOutput "$PSScriptRoot\logs\server.out.log" -RedirectStandardError "$PSScriptRoot\logs\server.err.log" -PassThru
    $server.Id | Set-Content -LiteralPath data/server.pid
    $origin | Set-Content -LiteralPath data/public-url.txt
    Remove-Item -LiteralPath data/invite-url.txt -ErrorAction SilentlyContinue
    $ready = $false
    $deadline = (Get-Date).AddSeconds(15)
    do {
        $server.Refresh()
        if ($server.HasExited) { throw ("Piik server exited before becoming ready:`n" + (Get-Content -LiteralPath logs/server.err.log -Tail 10 -Encoding UTF8 | Out-String)) }
        try { $ready = (Invoke-RestMethod "$localOrigin/healthz" -TimeoutSec 1).status -eq 'ok' } catch { $ready = $false }
        if (-not $ready) { Start-Sleep -Milliseconds 200 }
    } until ($ready -or (Get-Date) -gt $deadline)
    if (-not $ready) { throw "Piik server did not become ready on port $localPort. See piik/logs/server.err.log." }
    Start-Process -FilePath $browser -ArgumentList $browserArguments
    & $piikNodeCommand "$PSScriptRoot\launcher\Initialize-Browser.mjs"
    if ($LASTEXITCODE -ne 0) { throw 'Browser setup failed. See the launcher log.' }
    & "$PSScriptRoot\..\kook-bot\Start-Bot.ps1"
    Write-Host "Public site: $origin"
    Write-Host 'Click Start sharing, then copy the current invitation. The public address changes after restarting the tunnel.'
} catch {
    Stop-Process -Id $tunnel.Id -ErrorAction SilentlyContinue
    throw
}
