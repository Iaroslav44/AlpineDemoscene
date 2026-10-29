[CmdletBinding()]
param(
    [switch]$KeepIntermediates
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$sourceDir = Join-Path $projectRoot 'src'
$assetDir = Join-Path $projectRoot 'assets'
$buildDir = Join-Path $projectRoot 'build'
$distDir = Join-Path $projectRoot 'dist'
New-Item -ItemType Directory -Force -Path $buildDir, $distDir | Out-Null

# A runtime build must remain genuinely procedural.  Look-development images
# live under reference/, which is intentionally outside this check and outside
# the resource script.  Any raster accidentally placed in assets/ or src/ makes
# the build fail instead of silently turning the intro back into a slideshow.
$rasterExtensions = @('.jpg', '.jpeg', '.png', '.webp', '.bmp', '.gif', '.tif', '.tiff', '.dds')
$runtimeRasters = @(
    Get-ChildItem -LiteralPath $sourceDir, $assetDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $rasterExtensions -contains $_.Extension.ToLowerInvariant() }
)
if ($runtimeRasters.Count -ne 0) {
    $paths = ($runtimeRasters.FullName -join [Environment]::NewLine)
    throw "Procedural-only contract violated by runtime raster assets:`n$paths"
}

$resourceScript = Join-Path $sourceDir 'shaders.rc'
$resourceText = Get-Content -LiteralPath $resourceScript -Raw
if ($resourceText -match '(?i)\.(jpe?g|png|webp|bmp|gif|tiff?|dds)') {
    throw 'Procedural-only contract violated: shaders.rc references a raster image.'
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw 'Visual Studio Installer (vswhere.exe) was not found.'
}
$vsRoot = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
if (-not $vsRoot) {
    throw 'Visual Studio C++ x64 build tools are required.'
}
$msvcRoot = Join-Path $vsRoot 'VC\Tools\MSVC'
$toolset = Get-ChildItem -LiteralPath $msvcRoot -Directory |
    Sort-Object { [version]$_.Name } -Descending |
    Select-Object -First 1
$toolBin = Join-Path $toolset.FullName 'bin\Hostx64\x64'
$ml64 = Join-Path $toolBin 'ml64.exe'
$link = Join-Path $toolBin 'link.exe'

$sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$sdkLibVersion = Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'um\x64\d3d11.lib') } |
    Sort-Object { [version]$_.Name } -Descending |
    Select-Object -First 1
if (-not $sdkLibVersion) {
    throw 'A Windows 10/11 SDK with the x64 Direct3D libraries is required.'
}
$sdkVersion = $sdkLibVersion.Name
$sdkBin = Join-Path $sdkRoot "bin\$sdkVersion\x64"
$sdkLib = Join-Path $sdkRoot "Lib\$sdkVersion\um\x64"
$fxc = Join-Path $sdkBin 'fxc.exe'
$rc = Join-Path $sdkBin 'rc.exe'

foreach ($tool in @($ml64, $link, $fxc, $rc)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        throw "Required build tool not found: $tool"
    }
}

$hlsl = Join-Path $sourceDir 'scene.hlsl'
$humanHlsl = Join-Path $sourceDir 'human_pass.hlsl'
$postHlsl = Join-Path $sourceDir 'post.hlsl'
$meshHlsl = Join-Path $sourceDir 'cinematic_mesh.hlsl'
$vsBytecode = Join-Path $buildDir 'scene_vs.cso'
$psBytecode = Join-Path $buildDir 'scene_ps.cso'
$humanBytecode = Join-Path $buildDir 'human_ps.cso'
$temporalBytecode = Join-Path $buildDir 'temporal_ps.cso'
$displayBytecode = Join-Path $buildDir 'display_ps.cso'
$meshVSBytecode = Join-Path $buildDir 'mesh_vs.cso'
$meshPSBytecode = Join-Path $buildDir 'mesh_ps.cso'
$shadowVSBytecode = Join-Path $buildDir 'shadow_vs.cso'
$shadowPSBytecode = Join-Path $buildDir 'shadow_ps.cso'
$cameraBytecode = Join-Path $buildDir 'camera_cs.cso'
$instancesBytecode = Join-Path $buildDir 'instances_cs.cso'
$terrainBytecode = Join-Path $buildDir 'terrain_cs.cso'
$flightBytecode = Join-Path $buildDir 'flight_cs.cso'
$waterBytecode = Join-Path $buildDir 'water_cs.cso'
$materialBytecode = Join-Path $buildDir 'material_cs.cso'
$atmosphereBytecode = Join-Path $buildDir 'atmosphere_cs.cso'
$cloudBytecode = Join-Path $buildDir 'cloud_cs.cso'
$boundsBytecode = Join-Path $buildDir 'terrain_bounds_cs.cso'
$cloudCompositeBytecode = Join-Path $buildDir 'cloud_composite_ps.cso'
$resource = Join-Path $buildDir 'shaders.res'
$object = Join-Path $buildDir 'alpine.obj'
$candidateDir = Join-Path $buildDir 'candidate'
New-Item -ItemType Directory -Force -Path $candidateDir | Out-Null
$executable = Join-Path $candidateDir 'AlpineDreaming.exe'

Write-Host 'Compiling procedural cinematic Direct3D shaders...'
& $fxc /nologo /T vs_5_0 /E V /O3 /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo $vsBytecode $hlsl
if ($LASTEXITCODE -ne 0) { throw 'Vertex shader compilation failed.' }
# O1 is the verified stable profile for the large procedural world marcher.
# The current O3 experiment produced identical DXBC, with no runtime benefit.
& $fxc /nologo /T ps_5_0 /E P /O1 /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo $psBytecode $hlsl
if ($LASTEXITCODE -ne 0) { throw 'Pixel shader compilation failed.' }
& $fxc /nologo /T ps_5_0 /E H /O1 /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo $humanBytecode $humanHlsl
if ($LASTEXITCODE -ne 0) { throw 'Human composite shader compilation failed.' }
& $fxc /nologo /T ps_5_0 /E Temporal /O3 /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo $temporalBytecode $postHlsl
if ($LASTEXITCODE -ne 0) { throw 'Temporal reconstruction shader compilation failed.' }
& $fxc /nologo /T ps_5_0 /E Display /O3 /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo $displayBytecode $postHlsl
if ($LASTEXITCODE -ne 0) { throw 'Display shader compilation failed.' }
foreach ($shader in @(
    @{ Entry='MeshVS'; Profile='vs_5_0'; Output=$meshVSBytecode },
    @{ Entry='MeshPS'; Profile='ps_5_0'; Output=$meshPSBytecode },
    @{ Entry='ShadowVS'; Profile='vs_5_0'; Output=$shadowVSBytecode },
    @{ Entry='ShadowPS'; Profile='ps_5_0'; Output=$shadowPSBytecode },
    @{ Entry='CameraCS'; Profile='cs_5_0'; Output=$cameraBytecode },
    @{ Entry='SceneInstancesCS'; Profile='cs_5_0'; Output=$instancesBytecode }
)) {
    & $fxc /nologo /T $shader.Profile /E $shader.Entry /O3 /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo $shader.Output $meshHlsl
    if ($LASTEXITCODE -ne 0) { throw "$($shader.Entry) compilation failed." }
}

& $fxc /nologo /T cs_5_0 /E TerrainCS /O3 /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo $terrainBytecode (Join-Path $sourceDir 'terrain_compute.hlsl')
if ($LASTEXITCODE -ne 0) { throw 'Terrain cache shader compilation failed.' }

& $fxc /nologo /T cs_5_0 /E FlightCS /D ALPINE_FLIGHT_SIM=1 /O3 /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo $flightBytecode (Join-Path $sourceDir 'physics_simulation.hlsl')
if ($LASTEXITCODE -ne 0) { throw 'Flight physics shader compilation failed.' }
& $fxc /nologo /T cs_5_0 /E WaterCS /O3 /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo $waterBytecode (Join-Path $sourceDir 'physics_simulation.hlsl')
if ($LASTEXITCODE -ne 0) { throw 'Water physics shader compilation failed.' }

& $fxc /nologo /T cs_5_0 /E MaterialCS /O3 /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo $materialBytecode (Join-Path $sourceDir 'material_compute.hlsl')
if ($LASTEXITCODE -ne 0) { throw 'Procedural material generator compilation failed.' }
& $fxc /nologo /T cs_5_0 /E AtmosphereCS /O3 /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo $atmosphereBytecode (Join-Path $sourceDir 'atmosphere_compute.hlsl')
if ($LASTEXITCODE -ne 0) { throw 'Atmosphere lookup generator compilation failed.' }
& $fxc /nologo /T cs_5_0 /E CloudNoiseCS /O3 /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo $cloudBytecode (Join-Path $sourceDir 'cloud_volume.hlsl')
if ($LASTEXITCODE -ne 0) { throw 'Cloud volume generator compilation failed.' }
& $fxc /nologo /T cs_5_0 /E TerrainBoundsCS /O3 /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo $boundsBytecode (Join-Path $sourceDir 'terrain_bounds.hlsl')
if ($LASTEXITCODE -ne 0) { throw 'Terrain bounds hierarchy compilation failed.' }
& $fxc /nologo /T ps_5_0 /E CloudCompositePS /O3 /Qstrip_debug /Qstrip_reflect /Qstrip_priv /Fo $cloudCompositeBytecode (Join-Path $sourceDir 'cloud_post.hlsl')
if ($LASTEXITCODE -ne 0) { throw 'Cloud composite shader compilation failed.' }

Write-Host 'Embedding compact procedural DXBC shaders...'
Push-Location $sourceDir
try {
    & $rc /nologo /fo $resource 'shaders.rc'
    if ($LASTEXITCODE -ne 0) { throw 'Resource compilation failed.' }
}
finally {
    Pop-Location
}

Write-Host 'Assembling the no-CRT x64 host and procedural instrument synthesizer...'
& $ml64 /nologo /c "/I$sourceDir" "/Fo$object" (Join-Path $sourceDir 'alpine.asm')
if ($LASTEXITCODE -ne 0) { throw 'MASM compilation failed.' }

Write-Host 'Linking compact Windows PE...'
& $link /nologo /machine:x64 /subsystem:windows /entry:start /nodefaultlib /incremental:no `
    /opt:ref /opt:icf /dynamicbase /nxcompat /largeaddressaware:no /manifest:no /filealign:512 `
    "/libpath:$sdkLib" "/out:$executable" $object $resource `
    kernel32.lib user32.lib d3d11.lib winmm.lib
if ($LASTEXITCODE -ne 0) { throw 'Linking failed.' }

$verification = & (Join-Path $projectRoot 'tools\verify.ps1') -Executable $executable
$file = Get-Item -LiteralPath $executable
$limit = 88000000
$hash = $verification.SHA256
$percent = [math]::Round(100.0 * $file.Length / $limit, 2)

# Only a validated candidate may replace the last working distribution. Keep
# the preceding EXE recoverable; a compile/link/contract failure leaves it alone.
$published = Join-Path $distDir 'AlpineDreaming.exe'
$pending = Join-Path $distDir 'AlpineDreaming.pending.exe'
Copy-Item -LiteralPath $executable -Destination $pending -Force
if (Test-Path -LiteralPath $published) {
    [IO.File]::Replace($pending, $published, (Join-Path $distDir 'AlpineDreaming.previous.exe'))
} else {
    [IO.File]::Move($pending, $published)
}

Write-Host ''
Write-Host "Built:  $published"
Write-Host "Size:   $($file.Length) bytes ($percent% of the strict 88,000,000-byte limit)"
Write-Host "SHA256: $hash"

if (-not $KeepIntermediates) {
    Remove-Item -LiteralPath $vsBytecode, $psBytecode, $humanBytecode, $temporalBytecode, $displayBytecode, $meshVSBytecode, $meshPSBytecode, $shadowVSBytecode, $shadowPSBytecode, $cameraBytecode, $instancesBytecode, $terrainBytecode, $flightBytecode, $waterBytecode, $materialBytecode, $atmosphereBytecode, $cloudBytecode, $boundsBytecode, $cloudCompositeBytecode, $resource, $object -Force -ErrorAction SilentlyContinue
}
