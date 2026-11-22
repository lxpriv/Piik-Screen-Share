# Share one runtime lookup between Piik and the notification scripts.
$piikNodeCommand = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\runtime\node\node.exe'))
if (-not (Test-Path -LiteralPath $piikNodeCommand -PathType Leaf)) { $piikNodeCommand = 'node.exe' }

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
