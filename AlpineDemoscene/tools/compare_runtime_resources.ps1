# Establish which executable shader stages changed between two verified builds.
# Also compare all non-resource sections, excluding mutable PE header timestamps.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Reference,
    [Parameter(Mandatory)][string]$Candidate,
    [int[]]$ExpectedChangedResources=@(102),
    [Parameter(Mandatory)][string]$Report
)
$ErrorActionPreference='Stop'
function Read-Snapshot([string]$path) {
    $verified=& (Join-Path $PSScriptRoot 'verify.ps1') -Executable $path
    $bytes=[IO.File]::ReadAllBytes((Get-Item -LiteralPath $path).FullName)
    function U16([int]$p){[BitConverter]::ToUInt16($bytes,$p)}
    function U32([int]$p){[BitConverter]::ToUInt32($bytes,$p)}
    function Hash-Range([int]$offset,[int]$length) {
        $sha=[Security.Cryptography.SHA256]::Create()
        try {[BitConverter]::ToString($sha.ComputeHash($bytes,$offset,$length)).Replace('-','')}finally{$sha.Dispose()}
    }
    $pe=U32 0x3c;$optional=$pe+24;$sectionStart=$optional+(U16 ($pe+20))
    $sections=@(for($i=0;$i -lt (U16 ($pe+6));$i++){
        $p=$sectionStart+$i*40
        [pscustomobject]@{Name=[Text.Encoding]::ASCII.GetString($bytes,$p,8).TrimEnd([char]0);VA=(U32 ($p+12));Size=[Math]::Max((U32 ($p+8)),(U32 ($p+16)));Raw=(U32 ($p+20));RawSize=(U32 ($p+16))}
    })
    function Rva([uint32]$value){
        foreach($s in $sections){if($value -ge $s.VA -and $value -lt $s.VA+$s.Size){return [int]($s.Raw+$value-$s.VA)}}
        throw "Unmapped RVA $value."
    }
    $resourceBase=Rva (U32 ($optional+128));$resources=@{};$sectionHashes=@{};$rawSectionHashes=@{};$metadata=@()
    function Walk([int]$relative,[int[]]$keys){
        $directory=$resourceBase+$relative;$count=(U16 ($directory+12))+(U16 ($directory+14))
        for($i=0;$i -lt $count;$i++){
            $entry=$directory+16+$i*8;$id=U32 $entry;$target=U32 ($entry+4);$keysNext=@($keys)+@([int]$id)
            if(($target -band 0x80000000L) -ne 0){Walk ([int]($target -band 0x7fffffff)) $keysNext}
            else {
                $dataEntry=$resourceBase+$target;$data=Rva (U32 $dataEntry);$length=U32 ($dataEntry+4)
                $resources[[int]$keysNext[1]]=[pscustomobject]@{Bytes=$length;SHA256=(Hash-Range $data $length)}
            }
        }
    }
    Walk 0 @()
    foreach($section in $sections){if($section.Name -ne '.rsrc'){$rawSectionHashes[$section.Name]=Hash-Range $section.Raw $section.RawSize}}
    # LINK emits an IMAGE_DEBUG_TYPE_POGO contribution map even without a PDB.
    # Its timestamp and .rsrc contribution size describe the build, not runtime
    # behavior. Normalize only these identified fields; keep raw hashes too.
    $debugRva=U32 ($optional+160);$debugSize=U32 ($optional+164)
    if($debugRva -ne 0){
        $debugBase=Rva $debugRva
        for($i=0;$i -lt $debugSize;$i+=28){
            $directory=$debugBase+$i;$metadata+=@{kind='debug_timestamp';offset=$directory+4;bytes=4;original=(U32 ($directory+4))}
            [Array]::Clear($bytes,$directory+4,4)
            if((U32 ($directory+12)) -eq 13){
                $length=U32 ($directory+16);$start=U32 ($directory+24);$p=$start+4;$end=$start+$length
                while($p+8 -lt $end){
                    $nameEnd=$p+8;while($nameEnd -lt $end -and $bytes[$nameEnd] -ne 0){$nameEnd++}
                    if($nameEnd -eq $end){throw 'Malformed linker contribution metadata.'}
                    $name=[Text.Encoding]::ASCII.GetString($bytes,$p+8,$nameEnd-$p-8)
                    if($name.StartsWith('.rsrc$')){
                        $metadata+=@{kind='resource_contribution_size';name=$name;offset=$p+4;bytes=4;original=(U32 ($p+4))}
                        [Array]::Clear($bytes,$p+4,4)
                    }
                    $p=($nameEnd+4)-band(-4)
                }
            }
        }
    }
    foreach($section in $sections){if($section.Name -ne '.rsrc'){$sectionHashes[$section.Name]=Hash-Range $section.Raw $section.RawSize}}
    @{Verified=$verified;Resources=$resources;Sections=$sectionHashes;RawSections=$rawSectionHashes;NormalizedMetadata=$metadata}
}
$before=Read-Snapshot $Reference;$after=Read-Snapshot $Candidate
$resourceComparison=@(foreach($id in ($before.Resources.Keys|Sort-Object)){
    [pscustomobject]@{id=$id;reference_bytes=$before.Resources[$id].Bytes;candidate_bytes=$after.Resources[$id].Bytes;reference_sha256=$before.Resources[$id].SHA256;candidate_sha256=$after.Resources[$id].SHA256;identical=($before.Resources[$id].SHA256 -eq $after.Resources[$id].SHA256)}
})
$changed=@($resourceComparison|Where-Object {-not $_.identical}|ForEach-Object {$_.id})
$sectionComparison=@(foreach($name in ((@($before.Sections.Keys)+@($after.Sections.Keys))|Sort-Object -Unique)){
    [pscustomobject]@{name=$name;reference_sha256_raw=$before.RawSections[$name];candidate_sha256_raw=$after.RawSections[$name];raw_identical=($before.RawSections[$name] -eq $after.RawSections[$name]);reference_sha256_normalized=$before.Sections[$name];candidate_sha256_normalized=$after.Sections[$name];identical=($before.Sections[$name] -eq $after.Sections[$name])}
})
$expected=@($ExpectedChangedResources|Sort-Object)
$passed=(($changed -join ',') -eq ($expected -join ',')) -and @($sectionComparison|Where-Object {-not $_.identical}).Count -eq 0
[ordered]@{reference=$before.Verified;candidate=$after.Verified;expected_changed_resources=$expected;changed_resources=$changed;all_other_resources_identical=(($changed -join ',') -eq ($expected -join ','));host_runtime_sections_identical_excluding_linker_metadata=(@($sectionComparison|Where-Object {-not $_.identical}).Count -eq 0);reference_normalized_metadata=$before.NormalizedMetadata;candidate_normalized_metadata=$after.NormalizedMetadata;resources=$resourceComparison;sections=$sectionComparison;passed=$passed}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $Report -Encoding UTF8
if(-not $passed){throw "Unexpected runtime difference; inspect $Report."}
Write-Host "Runtime equivalence passed: only resource $($changed -join ',') changed; host sections match after explicit linker metadata normalization. Report: $Report"
