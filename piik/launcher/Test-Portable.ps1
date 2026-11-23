param([switch]$Anonymous, [switch]$CloseBrowserFirst)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$releaseRoot = Join-Path $workspace 'piik\releases'
$testRoot = Join-Path $releaseRoot ('.test portable 便携 ' + [guid]::NewGuid().ToString('N'))
$archive = Join-Path $releaseRoot 'Piik-Friends-Windows-x64.zip'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    foreach ($entry in $zip.Entries) {
        $name = $entry.FullName.Replace('\','/')
        if ($name -notmatch '^(piik|kook-bot)/' -or $name -match '(^|/)\.\./|\.sqlite|\.pid$|/browser-profile/|/node_modules/|/(logs|data)/.+') { throw "Unexpected private/generated content in archive: $name" }
    }
} finally { $zip.Dispose() }
[IO.Compression.ZipFile]::ExtractToDirectory($archive, $testRoot)
try {
    $exportedConfig = Get-Content -LiteralPath "$testRoot\kook-bot\config.local.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    $originalConfig = Get-Content -LiteralPath "$workspace\kook-bot\config.local.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($exportedConfig.bot_token -ne $originalConfig.bot_token -or $exportedConfig.channel_id -ne $originalConfig.channel_id) { throw 'Shared bot/channel export mismatch.' }
    if ((Get-FileHash -LiteralPath "$testRoot\piik\server\piik-server.exe").Hash -ne (Get-FileHash -LiteralPath "$workspace\piik\server\piik-server.exe").Hash) { throw 'Portable server does not include the deployed invitation fix.' }
    # Same binaries and scripts, isolated ports/mutex so the owner's active share keeps running.
    $textFiles = @(Get-ChildItem -LiteralPath $testRoot -File -Recurse | Where-Object { $_.Extension -in '.ps1','.mjs' -or $_.Name -eq '.env' })
    foreach ($file in $textFiles) {
        $text = (Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8).Replace('8787','18787').Replace('17887','18787').Replace('9227','19227')
        if ($file.Name -eq '.env') { $text = $text.Replace('STUN_LISTEN_HOST=127.0.0.1','STUN_LISTEN_HOST=127.0.0.3') }
        if ($file.Name -eq 'Runtime.ps1') { $text = $text.Replace('Google\Chrome\Application\chrome.exe','NoChromeForTest\chrome.exe') }
        if ($file.Name -eq 'Start-Piik.ps1') { $text = $text.Replace("'--no-first-run'", "'--headless=new','--no-first-run'") }
        [IO.File]::WriteAllText($file.FullName, $text, (New-Object Text.UTF8Encoding($false)))
    }
    $launcherSource = (Get-Content -LiteralPath "$PSScriptRoot\Launcher.cs" -Raw).Replace('Local\PiikScreenShareLauncher', ('Local\PiikPortableTest' + [guid]::NewGuid().ToString('N'))).Replace('Piik 屏幕共享','Piik 便携验收')
    [IO.File]::WriteAllText("$testRoot\TestLauncher.cs", $launcherSource, (New-Object Text.UTF8Encoding($false)))
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:winexe /platform:x64 /define:PORTABLE /codepage:65001 /reference:System.Windows.Forms.dll /reference:System.Drawing.dll "/out:$testRoot\piik\Piik-Screen-Share.exe" "$testRoot\TestLauncher.cs"
    if ($LASTEXITCODE -ne 0) { throw 'Portable test launcher compilation failed.' }
    $integration = (Get-Content -LiteralPath "$PSScriptRoot\Test-Launcher.ps1" -Raw).Replace('8787','18787').Replace('9227','19227').Replace('& node.exe', '& "$workspace\piik\runtime\node\node.exe"')
    [IO.File]::WriteAllText("$testRoot\piik\launcher\Test-Launcher.ps1", $integration, (New-Object Text.UTF8Encoding($false)))
    foreach ($name in 'cdp.mjs','start-test-preview.js','choose-test-preview.js','close-test-browser.mjs') {
        New-Item -ItemType Directory -Path "$testRoot\piik\launcher\fixtures" -Force | Out-Null
        $text = (Get-Content -LiteralPath "$PSScriptRoot\fixtures\$name" -Raw -Encoding UTF8).Replace('8787','18787').Replace('9227','19227')
        [IO.File]::WriteAllText("$testRoot\piik\launcher\fixtures\$name", $text, (New-Object Text.UTF8Encoding($false)))
    }
    $testMessages = Get-Content -LiteralPath "$testRoot\kook-bot\messages.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    $testMessages.start[0] = if ($Anonymous) { '**朋友便携版匿名测试（合成画面）**' } else { '**朋友便携版联动测试（合成画面）**' }
    [IO.File]::WriteAllText("$testRoot\kook-bot\messages.json", ($testMessages | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    $originalPath = $env:Path
    try {
        # No global Node/Git/development tool is on PATH. Package scripts must find their own runtime.
        $env:Path = "$env:WINDIR\System32;$env:WINDIR;$env:WINDIR\System32\WindowsPowerShell\v1.0"
        $testOwner = if ($Anonymous) { '' } else { (Get-Content -LiteralPath "$workspace\piik\data\kook-user-id.txt" -Raw).Trim() }
        & "$testRoot\piik\launcher\Test-Launcher.ps1" -LivePreview -CloseWhileRunning -OwnerUserId $testOwner -Anonymous:$Anonymous -CloseBrowserFirst:$CloseBrowserFirst
    } finally { $env:Path = $originalPath }
    $profilePath = Join-Path $testRoot 'piik\data\rooms.sqlite'
    if (-not (Test-Path -LiteralPath $profilePath)) { throw 'Fresh installation did not create its own database.' }
    $state = Get-Content -LiteralPath "$testRoot\kook-bot\data\last-message.json" -Raw | ConvertFrom-Json
    if (-not $state.expiredAt) { throw 'Portable shutdown did not remove its own invitation.' }
    if ($Anonymous) {
        if ($state.owner) { throw 'Anonymous share retained an owner identity.' }
    } elseif ($state.owner.id -ne $testOwner -or -not $state.owner.nickname) { throw 'Portable message did not record the selected server member.' }
    @'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
rows=c.execute('SELECT code_entry_policy,viewer_password_material IS NOT NULL FROM rooms').fetchall()
assert rows and all(policy=='private' and not password for policy,password in rows), rows
print('PASS: fresh portable rooms are private and password-free.')
'@ | & 'E:\Python\Python312\python.exe' - $profilePath
    if ($LASTEXITCODE -ne 0) { throw 'Portable room defaults were incorrect.' }
    Write-Output 'PASS: private archive, moved Unicode/space directory, bundled Node without global PATH, Edge, automatic KOOK publish/expiry and close cleanup.'
} catch {
    if (Test-Path -LiteralPath "$testRoot\piik\logs\launcher.log") { Get-Content -LiteralPath "$testRoot\piik\logs\launcher.log" -Tail 35 }
    Get-Content -LiteralPath "$testRoot\piik\server\.env" -ErrorAction SilentlyContinue | Where-Object { $_ -match '^PORT=' }
    foreach ($diagnostic in 'activity.txt','watch.err.log','watch.out.log') {
        if (Test-Path -LiteralPath "$testRoot\kook-bot\data\$diagnostic") { Get-Content -LiteralPath "$testRoot\kook-bot\data\$diagnostic" -Tail 5 }
    }
    throw
} finally {
    $testProfile = Join-Path $testRoot 'piik\data\browser-profile'
    Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe' OR Name = 'chrome.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($testProfile) } | ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
    if (-not $resolvedTestRoot.StartsWith(([IO.Path]::GetFullPath($releaseRoot) + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Portable test cleanup escaped releases.' }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
