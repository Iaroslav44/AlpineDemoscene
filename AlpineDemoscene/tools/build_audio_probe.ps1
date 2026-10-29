[CmdletBinding()]
param([string]$Out='build/audio_revision')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsRoot=(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
$toolset=Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Tools\MSVC') -Directory | Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$sdk=Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'um\x64\d3d11.lib')} | Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1
$cl=Join-Path $toolset.FullName 'bin\Hostx64\x64\cl.exe'
$ml=Join-Path $toolset.FullName 'bin\Hostx64\x64\ml64.exe'
$build=Join-Path $root 'build'
$includes=@("/I$($toolset.FullName)\include")
foreach($part in @('ucrt','shared','um','winrt')){$includes+="/I$sdkRoot\Include\$($sdk.Name)\$part"}
& $ml /nologo /c /DQA_AUDIO_EXPORT=1 /DQA_AUDIO_KEEP_BANK=1 "/I$root\src" "/Fo$build\audio_production.obj" (Join-Path $root 'src/alpine.asm')
if($LASTEXITCODE -ne 0){throw 'Audio MASM compilation failed.'}
& $cl /nologo /std:c++17 /EHsc /O2 /W4 @includes "/Fo$build\audio_probe.obj" "/Fe$build\audio_probe.exe" (Join-Path $PSScriptRoot 'audio_probe.cpp') (Join-Path $build 'audio_production.obj') /link /LARGEADDRESSAWARE:NO "/LIBPATH:$($toolset.FullName)\lib\x64" "/LIBPATH:$($sdk.FullName)\um\x64" "/LIBPATH:$($sdk.FullName)\ucrt\x64" kernel32.lib user32.lib d3d11.lib winmm.lib
if($LASTEXITCODE -ne 0){throw 'Audio probe link failed.'}
& (Join-Path $build 'audio_probe.exe') (Join-Path $root $Out)
if($LASTEXITCODE -ne 0){throw 'Audio probe failed.'}

