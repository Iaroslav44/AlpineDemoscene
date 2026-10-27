# Verify finite production water normals, then prove the diagnostic rejects
# the old overflowing tanh implementation. Only disposable build files mutate.
[CmdletBinding()]
param(
    [string]$Executable=(Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\AlpineDreaming.exe'),
    [string]$OutputDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) 'build\water_regression')
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$probe=Join-Path $root 'build\render_probe.exe'
if(-not (Test-Path -LiteralPath $probe)){throw 'Run tools/build_probe.ps1 first.'}
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$sdk=Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'bin') -Directory |
    Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'x64\fxc.exe')} |
    Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1
$fxc=Join-Path $sdk.FullName 'x64\fxc.exe'
$safe=Join-Path $OutputDirectory 'safe'
$negative=Join-Path $OutputDirectory 'negative'
New-Item -ItemType Directory -Path $safe,$negative -Force | Out-Null
$scene=Get-Content -LiteralPath (Join-Path $root 'src\scene.hlsl') -Raw
$anchor='float finiteDepth=(1.0-decay)/(1.0+decay);'
if(-not $scene.Contains($anchor)){throw 'Stable dispersion expression changed; review regression mutation.'}
$scene=$scene.Replace($anchor,'float finiteDepth=tanh(k*localDepth);')
$negativeScene=Join-Path $negative 'negative_scene.hlsl'
[IO.File]::WriteAllText($negativeScene,$scene)
$diagnostic=(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'water_probe.hlsl') -Raw).Replace('../src/scene.hlsl','negative_scene.hlsl')
$negativeProbe=Join-Path $negative 'negative_probe.hlsl'
[IO.File]::WriteAllText($negativeProbe,$diagnostic)
& $fxc /nologo /T ps_5_0 /E WaterProbe /O1 /Gis /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo (Join-Path $safe 'water_probe.cso') (Join-Path $PSScriptRoot 'water_probe.hlsl')
if($LASTEXITCODE -ne 0){throw 'Production water diagnostic compilation failed.'}
& $fxc /nologo /T ps_5_0 /E WaterProbe /O1 /Gis /I (Join-Path $root 'src') /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo (Join-Path $negative 'water_probe.cso') $negativeProbe
if($LASTEXITCODE -ne 0){throw 'Negative water diagnostic compilation failed.'}
& $probe --exe $Executable --shaders $negative --diagnostic-water --time 64 --width 512 --height 288 --out $negative
if($LASTEXITCODE -ne 2){throw 'The diagnostic did not reject overflowing water normals.'}
& $probe --exe $Executable --shaders $safe --diagnostic-water --time 64 --width 512 --height 288 --out $safe
if($LASTEXITCODE -ne 0){throw 'Production water normals or reflection coordinates are invalid.'}
Write-Host "Water regression passed; reports: $OutputDirectory"
