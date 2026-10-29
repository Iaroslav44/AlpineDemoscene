# Negative tests for packaging gates. Mutates only disposable copies in build/.
[CmdletBinding()]
param([string]$Executable=(Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\AlpineDreaming.exe'))
$ErrorActionPreference='Stop'
$verify=Join-Path $PSScriptRoot 'verify.ps1'
$original=Get-FileHash -LiteralPath $Executable -Algorithm SHA256
$bytes=[IO.File]::ReadAllBytes((Get-Item -LiteralPath $Executable).FullName)
$fixtureDir=Join-Path (Split-Path -Parent $PSScriptRoot) ('build\verify-fixtures-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureDir | Out-Null
$fixture=Join-Path $fixtureDir 'fixture.exe'
$fixtureManifest=Join-Path $fixtureDir 'models.json'
$emptyManifest=Join-Path $fixtureDir 'original-models.json'
$fixtureModel=Join-Path $fixtureDir 'packaging-test.bin'
function ExpectRejected([string]$label,[byte[]]$fixtureBytes,[string]$Manifest) {
    [IO.File]::WriteAllBytes($fixture,$fixtureBytes)
    $rejected=$false
    $arguments=@{Executable=$fixture}
    if($Manifest){$arguments.ModelManifest=$Manifest}
    try { & $verify @arguments | Out-Null } catch { $rejected=$true; Write-Host "$label rejected: $($_.Exception.Message)" }
    if (-not $rejected) { throw "Gate failed to reject $label." }
}
try {
    & $verify -Executable $Executable | Out-Null
    # Set the logical file length instead of allocating another 400 MB array.
    # Verification must reject by length before reading the payload into RAM.
    $largeStream=[IO.File]::Create($fixture)
    try { $largeStream.SetLength(400000000) } finally { $largeStream.Dispose() }
    $rejected=$false
    try { & $verify -Executable $fixture | Out-Null } catch { $rejected=$true; Write-Host "exactly 400,000,000 bytes rejected: $($_.Exception.Message)" }
    if(-not $rejected){throw 'Gate failed to reject exactly 400,000,000 bytes.'}
    $broken=$bytes.Clone();$broken[0]=0
    ExpectRejected 'invalid PE' $broken
    $text=[Text.Encoding]::ASCII.GetString($bytes)
    $offset=$text.IndexOf('DXBC',[StringComparison]::Ordinal)
    if($offset -lt 0){throw 'No DXBC test fixture found.'}
    $broken=$bytes.Clone();$broken[$offset]=0
    ExpectRejected 'non-DXBC resource' $broken
    $dxbcOffset=$offset
    $chunkCount=[BitConverter]::ToUInt32($bytes,$dxbcOffset+28)
    $programOffset=-1
    for($chunk=0;$chunk -lt $chunkCount;$chunk++) {
        $chunkOffset=[BitConverter]::ToUInt32($bytes,$dxbcOffset+32+$chunk*4)
        $tag=[Text.Encoding]::ASCII.GetString($bytes,$dxbcOffset+$chunkOffset,4)
        if($tag -in @('SHDR','SHEX')){$programOffset=$dxbcOffset+$chunkOffset+8;break}
    }
    if($programOffset -lt 0){throw 'No shader program chunk fixture found.'}
    $broken=$bytes.Clone();$broken[$programOffset+2]=255
    ExpectRejected 'wrong shader stage' $broken
    $broken=$bytes.Clone();$broken[$programOffset]=64
    ExpectRejected 'wrong shader model' $broken
    $offset=$text.IndexOf('d3d11.dll',[StringComparison]::OrdinalIgnoreCase)
    if($offset -lt 0){throw 'No import test fixture found.'}
    $broken=$bytes.Clone();$broken[$offset]=[byte][char]'x'
    ExpectRejected 'unexpected import' $broken

    # A tiny clearly labelled fixture exercises exact model packaging; it is
    # disposable test data, never trained weights or part of a release build.
    if (-not ('AlpinePackagingResourceWriter' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AlpinePackagingResourceWriter {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr BeginUpdateResource(string name, bool deleteExisting);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool UpdateResource(IntPtr handle, IntPtr type, IntPtr name, ushort language, byte[] data, uint size);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool EndUpdateResource(IntPtr handle, bool discard);
}
'@
    }
    $root=Split-Path -Parent $PSScriptRoot
    $releaseManifest=Join-Path $root 'models\runtime-manifest.json'
    $existing=@()
    if(Test-Path -LiteralPath $releaseManifest){$existing=@((Get-Content -LiteralPath $releaseManifest -Raw | ConvertFrom-Json).models)}
    if(299 -in $existing.resource_id){throw 'Resource 299 is reserved by this packaging test.'}
    $payload=New-Object byte[] 96
    $marker=[Text.Encoding]::ASCII.GetBytes('NAV1ALPINE_MODEL_PACKAGING_FIXTURE_v1')
    [Array]::Copy($marker,$payload,$marker.Length)
    [IO.File]::WriteAllBytes($fixtureModel,$payload)
    $model=[ordered]@{resource_id=299;path=$fixtureModel.Substring($root.Length+1).Replace('\','/');bytes=$payload.Length;sha256=(Get-FileHash -LiteralPath $fixtureModel -Algorithm SHA256).Hash;magic_hex='4e415631'}
    @{schema=1;models=@($existing)+@($model)} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureManifest -Encoding utf8
    @{schema=1;models=@($existing)} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $emptyManifest -Encoding utf8
    [IO.File]::WriteAllBytes($fixture,$bytes)
    $handle=[AlpinePackagingResourceWriter]::BeginUpdateResource($fixture,$false)
    if($handle -eq [IntPtr]::Zero){throw 'Cannot open disposable resource fixture.'}
    $updated=[AlpinePackagingResourceWriter]::UpdateResource($handle,[IntPtr]10,[IntPtr]299,1033,$payload,$payload.Length)
    $closed=[AlpinePackagingResourceWriter]::EndUpdateResource($handle,(-not $updated))
    if(-not $updated -or -not $closed){throw 'Cannot create disposable model resource fixture.'}
    & $verify -Executable $fixture -ModelManifest $fixtureManifest | Out-Null
    $withModel=[IO.File]::ReadAllBytes($fixture)
    ExpectRejected 'unlisted model resource' $withModel $emptyManifest
    $modelOffset=[Text.Encoding]::ASCII.GetString($withModel).IndexOf('NAV1ALPINE_MODEL_PACKAGING_FIXTURE_v1',[StringComparison]::Ordinal)
    if($modelOffset -lt 0){throw 'No neural packaging marker found.'}
    $broken=$withModel.Clone();$broken[$modelOffset]=0
    ExpectRejected 'wrong model header' $broken $fixtureManifest
    $broken=$withModel.Clone();$broken[$modelOffset+16]=$broken[$modelOffset+16] -bxor 1
    ExpectRejected 'changed model weights' $broken $fixtureManifest
    ExpectRejected 'missing model resource' $bytes $fixtureManifest
    if((Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash -ne $original.Hash){throw 'Original EXE changed during tests.'}
    Write-Host 'One exact-model positive gate and all ten negative gates passed; original EXE unchanged.'
} finally {
    # Delete only the exact test file created by this script; no recursive root.
    if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Force}
    foreach($temporary in @($fixtureManifest,$emptyManifest,$fixtureModel)) {
        if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}
    }
    Remove-Item -LiteralPath $fixtureDir
}
