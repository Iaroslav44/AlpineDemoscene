# Packaging metadata for explicitly approved embedded neural weights. This file
# is shared by the build and PE verifier; it never loads an ML framework/model.
function Get-NeuralResourceManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$ManifestPath = (Join-Path $ProjectRoot 'models\runtime-manifest.json'),
        [switch]$ValidateFiles
    )
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $null -eq $manifest.models) {
        throw 'Expected neural resource manifest schema 1 and a models array.'
    }
    $root = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $seen = @{}
    foreach ($model in @($manifest.models)) {
        $id = [int]$model.resource_id
        if ($model.resource_id -isnot [ValueType] -or [double]$model.resource_id -ne $id -or $id -lt 200 -or $id -gt 299 -or $seen.ContainsKey($id)) {
            throw "Invalid or duplicate neural model resource ID: $id."
        }
        $seen[$id] = $true
        if ([string]::IsNullOrWhiteSpace($model.path) -or [IO.Path]::IsPathRooted($model.path)) {
            throw "Model $id needs a project-relative file path."
        }
        $fullPath = [IO.Path]::GetFullPath((Join-Path $root $model.path))
        if (-not $fullPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Model $id escapes the project directory."
        }
        if ($model.bytes -isnot [ValueType] -or [double]$model.bytes -ne [int64]$model.bytes -or [int64]$model.bytes -lt 32 -or [int64]$model.bytes -ge 400000000) {
            throw "Invalid byte length for model $id."
        }
        if ([string]$model.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
            throw "Model $id needs an exact SHA-256."
        }
        if ([string]$model.magic_hex -notmatch '^(?:[a-fA-F0-9]{2}){4,32}$') {
            throw "Model $id needs 4-32 explicit header bytes in magic_hex."
        }
        $magic = [byte[]]@(for ($i = 0; $i -lt $model.magic_hex.Length; $i += 2) {
            [Convert]::ToByte($model.magic_hex.Substring($i, 2), 16)
        })
        if ($ValidateFiles) {
            $file = Get-Item -LiteralPath $fullPath
            if ($file.Length -ne [int64]$model.bytes) { throw "Model $id source byte length mismatch." }
            if ((Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash -ne $model.sha256) {
                throw "Model $id source SHA-256 mismatch."
            }
            $stream = [IO.File]::OpenRead($fullPath)
            try {
                for ($i = 0; $i -lt $magic.Length; $i++) {
                    if ($stream.ReadByte() -ne $magic[$i]) { throw "Model $id source header mismatch." }
                }
            } finally { $stream.Dispose() }
        }
        [pscustomobject]@{
            ResourceId = $id
            Path = [string]$model.path
            FullPath = $fullPath
            Bytes = [int64]$model.bytes
            SHA256 = ([string]$model.sha256).ToUpperInvariant()
            Magic = $magic
        }
    }
}
