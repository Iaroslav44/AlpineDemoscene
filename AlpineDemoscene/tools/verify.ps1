[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Executable,
    [string]$ModelManifest,
    [switch]$AsJson
)
$ErrorActionPreference = 'Stop'
$file = Get-Item -LiteralPath $Executable
if ($file.Length -ge 400000000) { throw "EXE is $($file.Length) bytes; limit is strictly below 400,000,000 bytes." }
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'model_manifest.ps1')
$manifestArguments = @{ProjectRoot=$projectRoot}
if ($ModelManifest) { $manifestArguments.ManifestPath = $ModelManifest }
$models = @(Get-NeuralResourceManifest @manifestArguments)
$modelMap = @{}
foreach ($model in $models) { $modelMap[$model.ResourceId] = $model }
$shaderIds = @(101..119)
if ($modelMap.ContainsKey(200)) { $shaderIds += 120 }
$bytes = [IO.File]::ReadAllBytes($file.FullName)
function U16([int]$p) { [BitConverter]::ToUInt16($bytes, $p) }
function U32([int]$p) { [BitConverter]::ToUInt32($bytes, $p) }
function AsciiZ([int]$p) {
    $end = $p
    while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
    if ($end -eq $bytes.Length) { throw 'Unterminated PE string.' }
    [Text.Encoding]::ASCII.GetString($bytes, $p, $end - $p)
}
if ((U16 0) -ne 0x5A4D) { throw 'Missing MZ signature.' }
$pe = U32 0x3C
if ((U32 $pe) -ne 0x4550 -or (U16 ($pe+4)) -ne 0x8664) { throw 'Expected an x64 PE executable.' }
$optional = $pe + 24
if ((U16 $optional) -ne 0x20B) { throw 'Expected PE32+.' }
$sectionStart = $optional + (U16 ($pe+20))
$sections = @(for ($i=0; $i -lt (U16 ($pe+6)); $i++) {
    $p = $sectionStart + $i*40
    [pscustomobject]@{ VA=(U32 ($p+12)); Size=[Math]::Max((U32 ($p+8)),(U32 ($p+16))); Raw=(U32 ($p+20)); RawSize=(U32 ($p+16)) }
})
function Rva([uint32]$value) {
    foreach ($s in $sections) {
        if ($value -ge $s.VA -and $value -lt $s.VA + $s.Size) {
            $offset = $value - $s.VA
            if ($offset -ge $s.RawSize) { throw 'RVA points outside file-backed data.' }
            return [int]($s.Raw + $offset)
        }
    }
    throw "Unmapped RVA $value."
}
$imports = @()
$importRva = U32 ($optional+120)
if ($importRva -eq 0) { throw 'Missing import directory.' }
$p = Rva $importRva
while ((U32 ($p+12)) -ne 0) {
    $name = (AsciiZ (Rva (U32 ($p+12)))).ToLowerInvariant()
    if ($name -notin @('kernel32.dll','user32.dll','d3d11.dll','winmm.dll')) { throw "Unexpected runtime dependency: $name" }
    $imports += $name
    $p += 20
}
if ((U32 ($optional+216)) -ne 0) { throw 'Delay-loaded DLLs are not permitted.' }
$resourceRva = U32 ($optional+128)
if ($resourceRva -eq 0) { throw 'Missing shader resources.' }
$resourceBase = Rva $resourceRva
$script:found = @()
$script:foundModels = @()
function WalkResources([int]$relative, [int[]]$keys) {
    $directory = $resourceBase + $relative
    $named = U16 ($directory+12)
    $count = $named + (U16 ($directory+14))
    if ($named -ne 0) { throw 'Named resources are not part of the procedural runtime contract.' }
    for ($i=0; $i -lt $count; $i++) {
        $entry = $directory + 16 + $i*8
        $id = U32 $entry
        $target = U32 ($entry+4)
        $path = @($keys) + @([int]$id)
        if (($target -band 0x80000000L) -ne 0) {
            if ($path.Count -gt 2) { throw 'Unexpected resource directory depth.' }
            WalkResources ([int]($target -band 0x7FFFFFFF)) $path
        } else {
            if ($path.Count -ne 3 -or $path[0] -ne 10 -or ($path[1] -notin $shaderIds -and -not $modelMap.ContainsKey($path[1]))) { throw "Unexpected resource: $($path -join '/')." }
            $dataEntry = $resourceBase + $target
            $data = Rva (U32 $dataEntry)
            $length = U32 ($dataEntry+4)
            if ([uint64]$data + $length -gt $bytes.Length) { throw 'Resource extends beyond executable.' }
            if ($modelMap.ContainsKey($path[1])) {
                $model = $modelMap[$path[1]]
                if ($length -ne $model.Bytes) { throw "Model $($path[1]) embedded byte length mismatch." }
                for ($m = 0; $m -lt $model.Magic.Length; $m++) {
                    if ($bytes[$data+$m] -ne $model.Magic[$m]) { throw "Model $($path[1]) embedded header mismatch." }
                }
                $hasher = [Security.Cryptography.SHA256]::Create()
                try { $hash = [BitConverter]::ToString($hasher.ComputeHash($bytes, $data, $length)).Replace('-', '') }
                finally { $hasher.Dispose() }
                if ($hash -ne $model.SHA256) { throw "Model $($path[1]) embedded SHA-256 mismatch." }
                $script:foundModels += $path[1]
                continue
            }
            if ($length -lt 32 -or [Text.Encoding]::ASCII.GetString($bytes,$data,4) -ne 'DXBC') { throw "Resource $($path[1]) is not DXBC bytecode." }
            if ((U32 ($data+24)) -ne $length) { throw "DXBC size mismatch in resource $($path[1])." }
            # A valid DXBC container must hold the expected shader stage, not
            # arbitrary data with a DXBC prefix or a vertex/pixel resource swap.
            $chunkCount=U32 ($data+28)
            if ($chunkCount -gt (($length-32)/4)) { throw 'Invalid DXBC chunk table.' }
            $programs=0
            for ($chunk=0; $chunk -lt $chunkCount; $chunk++) {
                $offset=U32 ($data+32+$chunk*4)
                if ([uint64]$offset+8 -gt $length) { throw 'DXBC chunk offset is outside resource.' }
                $chunkLength=U32 ($data+$offset+4)
                if ([uint64]$offset+8+$chunkLength -gt $length) { throw 'DXBC chunk payload is outside resource.' }
                $tag=[Text.Encoding]::ASCII.GetString($bytes,$data+$offset,4)
                if ($tag -in @('SHDR','SHEX')) {
                    if ($chunkLength -lt 8) { throw 'Invalid shader program chunk.' }
                    $version=U32 ($data+$offset+8)
                    $expected=if($path[1] -in @(101,106,108)){1}elseif($path[1] -in @(110,111,112,113,114,115,116,117,118,120)){5}else{0}
                    if (($version -shr 16) -ne $expected -or (($version -shr 4) -band 15) -ne 5 -or ($version -band 15) -ne 0) {
                        throw "Resource $($path[1]) does not contain its expected Shader Model 5.0 stage."
                    }
                    $programs++
                }
            }
            if ($programs -ne 1) { throw 'Expected exactly one shader program in DXBC.' }
            $script:found += $path[1]
        }
    }
}
WalkResources 0 @()
if ((($found | Sort-Object) -join ',') -ne (($shaderIds | Sort-Object) -join ',')) { throw "Expected shader resources $($shaderIds -join ','); found $($found -join ',')." }
$actualModels = ($foundModels | Sort-Object) -join ','
$expectedModels = ($models.ResourceId | Sort-Object) -join ','
if ($actualModels -ne $expectedModels) {
    throw "Expected exactly the manifest's neural resources; found $($foundModels -join ',')."
}
$result = [pscustomobject]@{ Path=$file.FullName; Bytes=$file.Length; LimitBytesExclusive=400000000; SHA256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash; ShaderResources=($found -join ','); ModelResources=($foundModels -join ','); Imports=($imports -join ',') }
if ($AsJson) { $result | ConvertTo-Json -Depth 4 } else { $result }
