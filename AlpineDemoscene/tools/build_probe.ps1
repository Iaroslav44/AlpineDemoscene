[CmdletBinding()]
param([switch]$SkipShaderCompilation)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsRoot=(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
if (-not $vsRoot) { throw 'Visual Studio C++ tools are required.' }
$toolset=Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Tools\MSVC') -Directory | Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$sdk=Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'um\x64\d3d11.lib')} | Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1
if (-not $sdk) { throw 'Windows SDK required.' }
$cl=Join-Path $toolset.FullName 'bin\Hostx64\x64\cl.exe'
$build=Join-Path $root 'build'
New-Item -ItemType Directory -Path $build -Force | Out-Null
$includes=@("/I$($toolset.FullName)\include", "/I$root\src")
foreach ($part in @('ucrt','shared','um','winrt')) { $includes+="/I$sdkRoot\Include\$($sdk.Name)\$part" }
& $cl /nologo /c /std:c++17 /O2 /Oi /GS- /GR- /EHs-c- /Zl /utf-8 @includes "/Fo$build\probe_neural_avatar.obj" (Join-Path $root 'src\neural_avatar_runtime.cpp')
if ($LASTEXITCODE -ne 0) { throw 'Neural avatar runtime compilation failed.' }
& $cl /nologo /std:c++17 /EHsc /O2 /W4 @includes "/Fo$build\render_probe.obj" "/Fe$build\render_probe.exe" (Join-Path $PSScriptRoot 'render_probe.cpp') (Join-Path $build 'probe_neural_avatar.obj') /link "/LIBPATH:$($toolset.FullName)\lib\x64" "/LIBPATH:$($sdk.FullName)\um\x64" "/LIBPATH:$($sdk.FullName)\ucrt\x64" d3d11.lib dxgi.lib
if ($LASTEXITCODE -ne 0) { throw 'Offscreen probe compilation failed.' }
if ($SkipShaderCompilation) {
    Write-Host "Built development-only probe using existing/candidate shaders: $build\render_probe.exe"
    return
}
$fxc=Join-Path $sdkRoot "bin\$($sdk.Name)\x64\fxc.exe"
& $fxc /nologo /T cs_5_0 /E NeuralAvatarCS /O3 /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo (Join-Path $build 'neural_avatar_cs.cso') (Join-Path $root 'src\neural_avatar.hlsl')
if ($LASTEXITCODE -ne 0) { throw 'Neural avatar compute shader compilation failed.' }
& $fxc /nologo /T ps_5_0 /E CameraProbe /O1 /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo (Join-Path $build 'camera_probe.cso') (Join-Path $PSScriptRoot 'camera_probe.hlsl')
if ($LASTEXITCODE -ne 0) { throw 'Camera diagnostic shader compilation failed.' }
& $fxc /nologo /T vs_5_0 /E InstanceVS /O3 /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo (Join-Path $build 'instance_probe_vs.cso') (Join-Path $PSScriptRoot 'instance_probe.hlsl')
if ($LASTEXITCODE -ne 0) { throw 'Instance diagnostic vertex shader compilation failed.' }
& $fxc /nologo /T ps_5_0 /E InstancePS /O3 /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo (Join-Path $build 'instance_probe_ps.cso') (Join-Path $PSScriptRoot 'instance_probe.hlsl')
if ($LASTEXITCODE -ne 0) { throw 'Instance diagnostic pixel shader compilation failed.' }
& $fxc /nologo /T ps_5_0 /E WaterProbe /O1 /Gis /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo (Join-Path $build 'water_probe.cso') (Join-Path $PSScriptRoot 'water_probe.hlsl')
if ($LASTEXITCODE -ne 0) { throw 'Water normal/UV diagnostic shader compilation failed.' }
Write-Host "Built development-only probe: $build\render_probe.exe"
