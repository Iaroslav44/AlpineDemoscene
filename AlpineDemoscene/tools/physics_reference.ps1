[CmdletBinding()]
param([string]$FlightCsv)
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsRoot=(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
$toolset=Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Tools\MSVC') -Directory | Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$sdk=Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1
$cl=Join-Path $toolset.FullName 'bin\Hostx64\x64\cl.exe'
$build=Join-Path $taskRoot 'build'
New-Item -ItemType Directory -Force -Path $build | Out-Null
$includes=@("/I$($toolset.FullName)\include","/I$sdkRoot\Include\$($sdk.Name)\ucrt","/I$sdkRoot\Include\$($sdk.Name)\shared","/I$sdkRoot\Include\$($sdk.Name)\um")
& $cl /nologo /std:c++17 /EHsc /O2 /W4 @includes "/Fo$build\physics_reference.obj" "/Fe$build\physics_reference.exe" (Join-Path $PSScriptRoot 'physics_reference.cpp') /link "/LIBPATH:$($toolset.FullName)\lib\x64" "/LIBPATH:$($sdk.FullName)\um\x64" "/LIBPATH:$($sdk.FullName)\ucrt\x64"
if($LASTEXITCODE -ne 0){throw 'Physics reference compilation failed.'}
if($FlightCsv){& (Join-Path $build 'physics_reference.exe') $FlightCsv}
else{& (Join-Path $build 'physics_reference.exe')}
if($LASTEXITCODE -ne 0){throw 'Physics reference checks failed.'}
