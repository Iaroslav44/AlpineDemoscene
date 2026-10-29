[CmdletBinding()]
param([string]$OutputPath)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsRoot = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
if (-not $vsRoot) { throw 'Visual Studio C++ tools are required.' }
$toolset = Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Tools\MSVC') -Directory | Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1
$sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$sdk = Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'um\x64\dxgi.lib')} | Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1
if (-not $sdk) { throw 'Windows SDK required.' }
$cl = Join-Path $toolset.FullName 'bin\Hostx64\x64\cl.exe'
$build = Join-Path $root 'build'
New-Item -ItemType Directory -Path $build -Force | Out-Null
$includes = @("/I$($toolset.FullName)\include")
foreach ($part in @('ucrt','shared','um','winrt')) { $includes += "/I$sdkRoot\Include\$($sdk.Name)\$part" }
& $cl /nologo /std:c++17 /EHsc /O2 /W4 @includes "/Fo$build\gpu_capabilities.obj" "/Fe$build\gpu_capabilities.exe" (Join-Path $PSScriptRoot 'gpu_capabilities.cpp') /link "/LIBPATH:$($toolset.FullName)\lib\x64" "/LIBPATH:$($sdk.FullName)\um\x64" "/LIBPATH:$($sdk.FullName)\ucrt\x64" d3d11.lib dxgi.lib | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'GPU capability probe compilation failed.' }
$json = & (Join-Path $build 'gpu_capabilities.exe')
if ($LASTEXITCODE -ne 0) { throw 'GPU capability probe failed.' }
$report = $json | ConvertFrom-Json
if (-not $OutputPath) { $OutputPath = Join-Path $build 'gpu_capabilities.json' }
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$report
