$ErrorActionPreference = 'Stop'
$workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$testRoot = Join-Path $workspace ('piik\data\closed-browser-test-' + [guid]::NewGuid().ToString('N'))
$browser = $null
$previousNodeOptions = $env:NODE_OPTIONS
New-Item -ItemType Directory -Path "$testRoot\piik\data","$testRoot\piik\launcher","$testRoot\kook-bot\data" -Force | Out-Null
Copy-Item -LiteralPath "$workspace\piik\Stop-Piik.ps1" -Destination "$testRoot\piik\Stop-Piik.ps1"
foreach ($name in 'Runtime.ps1','Stop-Browser.mjs') { Copy-Item -LiteralPath "$PSScriptRoot\$name" -Destination "$testRoot\piik\launcher\$name" }
foreach ($name in 'Stop-Bot.ps1','bot.mjs','browser.mjs','messages.json') { Copy-Item -LiteralPath "$workspace\kook-bot\$name" -Destination "$testRoot\kook-bot\$name" }
$browserSource = (Get-Content -LiteralPath "$testRoot\kook-bot\browser.mjs" -Raw).Replace('9227','19346')
[IO.File]::WriteAllText("$testRoot\kook-bot\browser.mjs", $browserSource, (New-Object Text.UTF8Encoding($false)))
'{"bot_token":"test-only-not-a-real-token"}' | Set-Content -LiteralPath "$testRoot\kook-bot\config.local.json"
@'
import {existsSync,writeFileSync} from 'node:fs';
const original = globalThis.fetch;
globalThis.fetch = (url, options) => {
 if (!String(url).startsWith('https://www.kookapp.cn/api/v3')) return original(url, options);
 if (!existsSync(new URL('./online', import.meta.url))) return Promise.resolve(Response.json({code:500,message:'Simulated KOOK outage'},{status:503}));
 writeFileSync(new URL('./updated-message.json',import.meta.url),options.body);
 return Promise.resolve(Response.json({code:0,data:{}}));
};
'@ | Set-Content -LiteralPath "$testRoot\offline.mjs" -Encoding UTF8
$env:NODE_OPTIONS = '--import=' + ([Uri]::new("$testRoot\offline.mjs")).AbsoluteUri
try {
 . "$PSScriptRoot\Runtime.ps1"
 $browser = Start-Process -FilePath (Get-PiikBrowser) -ArgumentList @('--headless=new','--remote-debugging-port=19346',('--user-data-dir="{0}\profile"' -f $testRoot),'--no-first-run','--no-default-browser-check','http://localhost:8787/') -WindowStyle Hidden -PassThru
 $deadline=(Get-Date).AddSeconds(15)
 do {try {$ready=(Invoke-RestMethod 'http://127.0.0.1:19346/json/list' -TimeoutSec 1).Count -gt 0} catch {$ready=$false};if(-not $ready){Start-Sleep -Milliseconds 200}} until($ready -or (Get-Date) -gt $deadline)
 if(-not $ready){throw 'Test browser did not start.'}
 Stop-Process -Id $browser.Id
 if(-not $browser.WaitForExit(5000)){throw 'Test browser did not close.'}
 'stale-pid' | Set-Content -LiteralPath "$testRoot\piik\data\server.pid"
 '{"key":"test","messageId":"test-not-a-real-message","owner":null}' | Set-Content -LiteralPath "$testRoot\kook-bot\data\last-message.json"
 $shell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
 & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$testRoot\piik\Stop-Piik.ps1" *> "$testRoot\stop.log"
 if($LASTEXITCODE -ne 0){throw 'Closed browser plus failed notification blocked shutdown.'}
 if(Test-Path -LiteralPath "$testRoot\piik\data\server.pid"){throw 'Local cleanup was skipped.'}
 $state=Get-Content -LiteralPath "$testRoot\kook-bot\data\last-message.json" -Raw | ConvertFrom-Json
 if($state.expiredAt){throw 'Failed notification was falsely marked ended.'}
 $log=Get-Content -LiteralPath "$testRoot\stop.log" -Raw
 if($log -notmatch 'KOOK_END_PENDING:' -or $log -notmatch 'Simulated KOOK outage'){throw 'Notification failure was not logged.'}
 New-Item -ItemType File -Path "$testRoot\online" | Out-Null
 & $piikNodeCommand "$testRoot\kook-bot\bot.mjs" --expire | Out-Null
 if($LASTEXITCODE -ne 0){throw 'Pending notification could not be retried.'}
 $state=Get-Content -LiteralPath "$testRoot\kook-bot\data\last-message.json" -Raw | ConvertFrom-Json
 $updated=Get-Content -LiteralPath "$testRoot\updated-message.json" -Raw | ConvertFrom-Json
 if(-not $state.expiredAt -or $updated.msg_id -ne 'test-not-a-real-message' -or $updated.content -match 'https?://'){throw 'Retry did not expire the original message and remove its link.'}
 Write-Output 'PASS: real browser closed first; shutdown succeeds during simulated KOOK outage; retry updates the same message without a link. No real KOOK requests.'
} catch {
 if(Test-Path -LiteralPath "$testRoot\stop.log"){Get-Content -LiteralPath "$testRoot\stop.log" -Tail 15}
 throw
} finally {
 $env:NODE_OPTIONS=$previousNodeOptions
 if($browser -and -not $browser.HasExited){Stop-Process -Id $browser.Id -ErrorAction SilentlyContinue}
 $resolved=(Resolve-Path -LiteralPath $testRoot).Path
 if(-not $resolved.StartsWith(([IO.Path]::GetFullPath((Join-Path $workspace 'piik\data'))+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Test cleanup escaped workspace.'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
