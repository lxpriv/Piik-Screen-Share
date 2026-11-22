param([switch]$Portable, [string]$OutputPath)
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$output = if ($OutputPath) { $OutputPath } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'Piik-Screen-Share.exe' }
$defines = if ($Portable) { '/define:PORTABLE' } else { '/define:LOCAL' }
& $compiler /nologo /target:winexe /platform:x64 /optimize+ /codepage:65001 $defines /reference:System.Windows.Forms.dll /reference:System.Drawing.dll "/win32icon:$PSScriptRoot\..\source\public\favicon.ico" "/out:$output" "$PSScriptRoot\Launcher.cs"
if ($LASTEXITCODE -ne 0) { throw 'Launcher compilation failed.' }
Get-Item -LiteralPath $output | Select-Object FullName,Length
