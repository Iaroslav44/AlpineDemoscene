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
New-Item -ItemType Directory -Path $build -Force | Out-Null
$includes=@("/I$($toolset.FullName)\include", "/I$root\src")
foreach($part in @('ucrt','shared','um','winrt')){$includes+="/I$sdkRoot\Include\$($sdk.Name)\$part"}
. (Join-Path $PSScriptRoot 'model_manifest.ps1')
$models=@(Get-NeuralResourceManifest -ProjectRoot $root -ValidateFiles)
$additionalObjects=@()
foreach($name in @('neural_avatar_runtime','neural_audio')) {
    $source=Join-Path $root "src\$name.cpp"
    if(Test-Path -LiteralPath $source) {
        $nativeObject=Join-Path $build "audio_$name.obj"
        & $cl /nologo /c /std:c++17 /O2 /Oi /GS- /GR- /EHs-c- /Zl /utf-8 @includes "/Fo$nativeObject" $source
        if($LASTEXITCODE -ne 0){throw "Audio probe helper compilation failed: $name"}
        $additionalObjects+=$nativeObject
    }
}
if($models.Count) {
    $rc=Join-Path $sdkRoot "bin\$($sdk.Name)\x64\rc.exe"
    $modelScript=Join-Path $build 'audio_models.rc'
    $modelResource=Join-Path $build 'audio_models.res'
    $lines=@('#pragma code_page(65001)')
    foreach($model in $models){$lines+=''+$model.ResourceId+' RCDATA "'+$model.FullPath.Replace('\','\\')+'"'}
    $lines | Set-Content -LiteralPath $modelScript -Encoding utf8
    & $rc /nologo /fo $modelResource $modelScript
    if($LASTEXITCODE -ne 0){throw 'Audio probe neural resource compilation failed.'}
    $additionalObjects+=$modelResource
}
& $ml /nologo /c /DQA_AUDIO_EXPORT=1 /DQA_AUDIO_KEEP_BANK=1 "/I$root\src" "/Fo$build\audio_production.obj" (Join-Path $root 'src/alpine.asm')
if($LASTEXITCODE -ne 0){throw 'Audio MASM compilation failed.'}
& $cl /nologo /std:c++17 /EHsc /O2 /W4 @includes "/Fo$build\audio_probe.obj" "/Fe$build\audio_probe.exe" (Join-Path $PSScriptRoot 'audio_probe.cpp') (Join-Path $build 'audio_production.obj') @additionalObjects /link /LARGEADDRESSAWARE:NO "/LIBPATH:$($toolset.FullName)\lib\x64" "/LIBPATH:$($sdk.FullName)\um\x64" "/LIBPATH:$($sdk.FullName)\ucrt\x64" kernel32.lib user32.lib d3d11.lib winmm.lib
if($LASTEXITCODE -ne 0){throw 'Audio probe link failed.'}
& (Join-Path $build 'audio_probe.exe') (Join-Path $root $Out)
if($LASTEXITCODE -ne 0){throw 'Audio probe failed.'}
