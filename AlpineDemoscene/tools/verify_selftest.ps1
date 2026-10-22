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
function ExpectRejected([string]$label,[byte[]]$fixtureBytes) {
    [IO.File]::WriteAllBytes($fixture,$fixtureBytes)
    $rejected=$false
    try { & $verify -Executable $fixture | Out-Null } catch { $rejected=$true; Write-Host "$label rejected: $($_.Exception.Message)" }
    if (-not $rejected) { throw "Gate failed to reject $label." }
}
try {
    & $verify -Executable $Executable | Out-Null
    $large=New-Object byte[] 1000000
    [Array]::Copy($bytes,$large,[Math]::Min($bytes.Length,$large.Length))
    ExpectRejected 'exactly 1,000,000 bytes' $large
    $broken=$bytes.Clone();$broken[0]=0
    ExpectRejected 'invalid PE' $broken
    $text=[Text.Encoding]::ASCII.GetString($bytes)
    $offset=$text.IndexOf('DXBC',[StringComparison]::Ordinal)
    if($offset -lt 0){throw 'No DXBC test fixture found.'}
    $broken=$bytes.Clone();$broken[$offset]=0
    ExpectRejected 'non-DXBC resource' $broken
    $offset=$text.IndexOf('d3d11.dll',[StringComparison]::OrdinalIgnoreCase)
    if($offset -lt 0){throw 'No import test fixture found.'}
    $broken=$bytes.Clone();$broken[$offset]=[byte][char]'x'
    ExpectRejected 'unexpected import' $broken
    if((Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash -ne $original.Hash){throw 'Original EXE changed during tests.'}
    Write-Host 'All four negative gates passed; original EXE unchanged.'
} finally {
    # Delete only the exact test file created by this script; no recursive root.
    if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Force}
    Remove-Item -LiteralPath $fixtureDir
}
