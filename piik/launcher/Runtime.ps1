# Share one runtime lookup between Piik and the notification scripts.
$piikNodeCommand = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\runtime\node\node.exe'))
if (-not (Test-Path -LiteralPath $piikNodeCommand -PathType Leaf)) { $piikNodeCommand = 'node.exe' }

function Get-PiikLocalPort {
    $configFile = Join-Path $PSScriptRoot '..\server\.env'
    if (-not (Test-Path -LiteralPath $configFile)) { return 8787 }
    $config = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8
    $match = [regex]::Match($config, '(?m)^PORT=(\d+)[ \t]*\r?$')
    $port = 0
    if (-not $match.Success -or -not [int]::TryParse($match.Groups[1].Value, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw 'Invalid PORT in piik/server/.env' }
    return $port
}

function Get-PiikBrowser {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
    )
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate } }
    throw 'Chrome or Microsoft Edge is required. Install one, then retry Start.'
}
