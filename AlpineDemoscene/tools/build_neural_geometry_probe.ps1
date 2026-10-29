[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsRoot=(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
$toolset=Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Tools\MSVC') -Directory | Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$sdk=Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'um\x64\d3d11.lib')} | Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1
$cl=Join-Path $toolset.FullName 'bin\Hostx64\x64\cl.exe'
$build=Join-Path $root 'build'
$includes=@("/I$($toolset.FullName)\include", "/I$root\src")
foreach ($part in @('ucrt','shared','um','winrt')) { $includes+="/I$sdkRoot\Include\$($sdk.Name)\$part" }
& $cl /nologo /std:c++17 /EHsc /O2 /W4 @includes "/Fo$build\neural_geometry_probe.obj" "/Fe$build\neural_geometry_probe.exe" (Join-Path $PSScriptRoot 'neural_geometry_probe.cpp') /link "/LIBPATH:$($toolset.FullName)\lib\x64" "/LIBPATH:$($sdk.FullName)\um\x64" "/LIBPATH:$($sdk.FullName)\ucrt\x64" d3d11.lib dxgi.lib
if ($LASTEXITCODE -ne 0) { throw 'CPU geometry probe compilation failed.' }
