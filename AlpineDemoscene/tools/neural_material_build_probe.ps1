[CmdletBinding()]
param([switch]$CompileOnly,[string]$Out='build/neural_material_probe42',[uint32]$Seed=42,[uint32]$CancelAt=0)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
$toolset=Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$sdk=Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'um\x64\d3d11.lib')} | Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1
$cl=Join-Path $toolset.FullName 'bin\Hostx64\x64\cl.exe'
$fxc=Join-Path $sdkRoot "bin\$($sdk.Name)\x64\fxc.exe"
$build=Join-Path $root 'build'
$includes=@("/I$($toolset.FullName)\include","/I$root\src")
foreach($part in @('ucrt','shared','um','winrt')){$includes+="/I$sdkRoot\Include\$($sdk.Name)\$part"}
& $fxc /nologo /T cs_5_0 /E NeuralMaterialCS /O3 /Fo "$build\neural_material_cs.cso" "$root\src\neural_material.hlsl"
if($LASTEXITCODE -ne 0){throw 'Material shader compilation failed.'}
& $cl /nologo /c /std:c++17 /O2 /Oi /GS- /GR- /EHs-c- /Zl /utf-8 @includes "/Fo$build\neural_material_runtime.obj" "$root\src\neural_material_runtime.cpp"
if($LASTEXITCODE -ne 0){throw 'Material runtime compilation failed.'}
& $cl /nologo /std:c++17 /EHsc /O2 /W4 @includes "/Fo$build\neural_material_probe.obj" "/Fe$build\neural_material_probe.exe" "$root\tools\neural_material_probe.cpp" "$build\neural_material_runtime.obj" /link "/LIBPATH:$($toolset.FullName)\lib\x64" "/LIBPATH:$($sdk.FullName)\um\x64" "/LIBPATH:$($sdk.FullName)\ucrt\x64" kernel32.lib user32.lib d3d11.lib
if($LASTEXITCODE -ne 0){throw 'Material probe link failed.'}
if(-not $CompileOnly){
    & "$build\neural_material_probe.exe" "$root\models\material\photomat-256.nam" "$build\neural_material_cs.cso" (Join-Path $root $Out) $Seed $CancelAt
    if($LASTEXITCODE -ne 0){throw 'Material probe failed.'}
}
