$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\launcher\Runtime.ps1"
$failures = @()
try {
    & $piikNodeCommand "$PSScriptRoot\launcher\Stop-Browser.mjs"
    if ($LASTEXITCODE -ne 0) { throw 'Piik capture page could not be closed. Stop sharing in the browser and retry Stop.' }
} catch { $failures += $_.Exception.Message }
try { & "$PSScriptRoot\..\kook-bot\Stop-Bot.ps1" -Expire } catch { $failures += $_.Exception.Message }
foreach ($name in 'server','tunnel') {
    $pidFile = Join-Path $PSScriptRoot "data\$name.pid"
    if (-not (Test-Path -LiteralPath $pidFile)) { continue }
    try {
        $processId = 0
        if ([int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$processId) -and $processId -gt 0) {
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            $expected = if ($name -eq 'server') { "$PSScriptRoot\server\piik-server.exe" } else { "$PSScriptRoot\runtime\runtime\tunnel\cloudflared.exe" }
            if ($process -and $process.Path -eq $expected) {
                Stop-Process -Id $processId -ErrorAction Stop
                if (-not $process.WaitForExit(5000)) { throw "$name did not exit after Stop." }
            }
        }
        Remove-Item -LiteralPath $pidFile -ErrorAction Stop
    } catch { $failures += $_.Exception.Message }
}
if ($failures.Count) { throw ($failures -join "`n") }
Write-Host 'Piik and its public tunnel are stopped.'
