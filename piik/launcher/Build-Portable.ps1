param([string]$NodeExecutable = 'D:\SOFTWARE\node\node.exe')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$releaseRoot = Join-Path $workspace 'piik\releases'
$stage = Join-Path $releaseRoot ('.stage-' + [guid]::NewGuid().ToString('N'))
$zip = Join-Path $releaseRoot 'Piik-Friends-Windows-x64.zip'
$config = Get-Content -LiteralPath "$workspace\kook-bot\config.local.json" -Encoding UTF8 -Raw | ConvertFrom-Json
if (-not $config.bot_token -or -not $config.channel_id) { throw 'Configure the shared bot and exact text channel before exporting.' }
$nodeVersion = (& $NodeExecutable --version).Trim()
& $NodeExecutable -e "if(typeof fetch!=='function'||typeof WebSocket!=='function')process.exit(1)"
if ($LASTEXITCODE -ne 0) { throw 'Node with built-in fetch and WebSocket is required.' }
$nodeLicense = Join-Path $workspace "piik\downloads\node-$nodeVersion-LICENSE.txt"
if (-not (Test-Path -LiteralPath $nodeLicense)) { Invoke-WebRequest -Uri "https://raw.githubusercontent.com/nodejs/node/$nodeVersion/LICENSE" -OutFile $nodeLicense -TimeoutSec 30 }
$tunnelLicense = Join-Path $workspace 'piik\downloads\cloudflared-LICENSE.txt'
if (-not (Test-Path -LiteralPath $tunnelLicense)) { Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/cloudflare/cloudflared/master/LICENSE' -OutFile $tunnelLicense -TimeoutSec 30 }
New-Item -ItemType Directory -Path "$stage\piik\launcher","$stage\piik\server","$stage\piik\runtime\node","$stage\piik\runtime\runtime\tunnel","$stage\piik\patches","$stage\piik\data","$stage\kook-bot" -Force | Out-Null
try {
    foreach ($name in 'Start-Piik.ps1','Stop-Piik.ps1') { Copy-Item -LiteralPath "$workspace\piik\$name" -Destination "$stage\piik\$name" }
    foreach ($name in 'Runtime.ps1','Initialize-Browser.mjs','Stop-Browser.mjs') { Copy-Item -LiteralPath "$PSScriptRoot\$name" -Destination "$stage\piik\launcher\$name" }
    foreach ($name in 'piik-server.exe','LICENSE','REVISION','THIRD-PARTY-NOTICES.txt') { Copy-Item -LiteralPath "$workspace\piik\server\$name" -Destination "$stage\piik\server\$name" }
    foreach ($name in 'bot.mjs','browser.mjs','watch.mjs','Start-Bot.ps1','Stop-Bot.ps1','messages.json','config.example.json') { Copy-Item -LiteralPath "$workspace\kook-bot\$name" -Destination "$stage\kook-bot\$name" }
    Copy-Item -LiteralPath $NodeExecutable -Destination "$stage\piik\runtime\node\node.exe"
    Copy-Item -LiteralPath $nodeLicense -Destination "$stage\piik\runtime\node\LICENSE.txt"
    Copy-Item -LiteralPath "$workspace\piik\runtime\runtime\tunnel\cloudflared.exe","$workspace\piik\runtime\runtime\tunnel\THIRD-PARTY-NOTICES.txt" -Destination "$stage\piik\runtime\runtime\tunnel"
    Copy-Item -LiteralPath $tunnelLicense -Destination "$stage\piik\runtime\runtime\tunnel\LICENSE.txt"
    Copy-Item -LiteralPath "$workspace\piik\patches\mobile-invite-tracking.patch" -Destination "$stage\piik\patches\mobile-invite-tracking.patch"
    Copy-Item -LiteralPath "$PSScriptRoot\PORTABLE-README.zh-CN.md" -Destination "$stage\piik\README.md"
    & "$PSScriptRoot\Build.ps1" -Portable -OutputPath "$stage\piik\Piik-Screen-Share.exe" | Out-Null
    $friendConfig = [ordered]@{bot_token=$config.bot_token; guild_name=$config.guild_name; channel_name=$config.channel_name; channel_id=$config.channel_id}
    [IO.File]::WriteAllText("$stage\kook-bot\config.local.json", ($friendConfig | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    $serverConfig = @'
PIIK_ENV=production
LISTEN_HOST=127.0.0.1
PORT=17887
PUBLIC_BASE_URL=https://example.invalid
ALLOWED_ORIGINS=https://example.invalid,http://localhost:17887,http://127.0.0.1:17887
SITE_ACCESS_PASSWORD=
MAX_VIEWERS_PER_ROOM=10
STUN_URLS=stun:stun.cloudflare.com:3478,stun:stun.miwifi.com:3478,stun:stun.chat.bilibili.com:3478
STUN_LISTEN_HOST=127.0.0.1
SFU_UDP_PORT=
NAT_PREDICTION_ENABLED=false
ROOM_DATABASE_PATH=rooms.sqlite
'@
    [IO.File]::WriteAllText("$stage\piik\server\.env", $serverConfig, (New-Object Text.UTF8Encoding($false)))
    $patchNotice = "Piik v2.8.0 + local invitation tracking fix (2.8.0+invitefix.1).`nBase: 81b4f27eff2a1de1dfe6131c06b525b7ba3508a8`nSource: https://github.com/TNTcraftHIM/Piik`nLocal diff: ../patches/mobile-invite-tracking.patch`n"
    [IO.File]::WriteAllText("$stage\piik\server\LOCAL-PATCH.md", $patchNotice, (New-Object Text.UTF8Encoding($false)))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
    Write-Output 'Private bundle created with the shared Bot Token; no Host/browser/history data was exported.'
    Get-Item -LiteralPath $zip | Select-Object FullName,Length
} finally {
    $resolvedStage = (Resolve-Path -LiteralPath $stage).Path
    $allowedRoot = [IO.Path]::GetFullPath($releaseRoot) + '\'
    if (-not $resolvedStage.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Export cleanup escaped release directory.' }
    Remove-Item -LiteralPath $resolvedStage -Recurse -Force
}
