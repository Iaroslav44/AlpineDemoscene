$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsRoot=(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
$toolset=Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Tools\MSVC') -Directory | Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$sdk=Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'um\x64\d3d11.lib')} | Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1
$cl=Join-Path $toolset.FullName 'bin\Hostx64\x64\cl.exe'
$fxc=Join-Path $sdkRoot "bin\$($sdk.Name)\x64\fxc.exe"
$includes=@("/I$($toolset.FullName)\include","/I$root\src")
foreach($part in @('ucrt','shared','um','winrt')){$includes+="/I$sdkRoot\Include\$($sdk.Name)\$part"}
Push-Location (Join-Path $root 'build')
try {
    & $fxc /nologo /T cs_5_0 /E WorldCS /O3 /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo world_cs.cso (Join-Path $root 'src\geomorphology.hlsl')
    if($LASTEXITCODE -ne 0){throw 'World probe shader compilation failed.'}
    & $cl /nologo /std:c++17 /EHsc /O2 /W4 @includes /Fe:world_probe.exe (Join-Path $PSScriptRoot 'world_probe.cpp') (Join-Path $root 'src\world_generation.cpp') /link "/LIBPATH:$($toolset.FullName)\lib\x64" "/LIBPATH:$($sdk.FullName)\um\x64" "/LIBPATH:$($sdk.FullName)\ucrt\x64" d3d11.lib
    if($LASTEXITCODE -ne 0){throw 'World probe build failed.'}
}finally{Pop-Location}
