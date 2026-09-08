[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EditorRoot,
    [Parameter(Mandatory)][string]$OutputRoot
)

# Local copy only. Never downloads, writes installed assets or exports account data.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sourceRoot = [IO.Path]::GetFullPath($EditorRoot)
$destinationRoot = [IO.Path]::GetFullPath($OutputRoot)
$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$separator = [IO.Path]::DirectorySeparatorChar
function Test-Under([string]$Path, [string]$Parent) {
    $Path.Equals($Parent, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Parent.TrimEnd($separator) + $separator, [StringComparison]::OrdinalIgnoreCase)
}
function Assert-Export([bool]$Condition, [string]$Code) { if (-not $Condition) { throw $Code } }
Assert-Export ([IO.Path]::IsPathRooted($EditorRoot) -and [IO.Path]::IsPathRooted($OutputRoot)) 'ui_export_absolute_paths_required'
Assert-Export (-not (Test-Under $destinationRoot $sourceRoot) -and -not (Test-Under $sourceRoot $destinationRoot)) 'ui_export_source_destination_overlap'
Assert-Export (-not (Test-Path -LiteralPath $destinationRoot)) 'ui_export_destination_must_be_new'
Assert-Export (-not (Test-Under $destinationRoot $repositoryRoot) -or
    (Test-Under $destinationRoot (Join-Path $repositoryRoot 'artifacts'))) 'ui_export_git_source_destination_forbidden'
foreach ($root in @($sourceRoot, [IO.Path]::GetDirectoryName($destinationRoot))) {
    for ($ancestor = $root; $ancestor; $ancestor = [IO.Path]::GetDirectoryName($ancestor)) {
        if (Test-Path -LiteralPath $ancestor) {
            Assert-Export (-not ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'ui_export_reparse_point_forbidden'
        }
    }
}
$presentationPath = Join-Path $sourceRoot 'presentation.json'
Assert-Export (Test-Path -LiteralPath $presentationPath -PathType Leaf) 'ui_export_presentation_missing'
$presentation = Get-Content -Raw -LiteralPath $presentationPath | ConvertFrom-Json
Assert-Export ($presentation.contractId -ceq 'nll/control-center-presentation/v1' -and @($presentation.characters).Count -gt 0) 'ui_export_presentation_invalid'
$files = [Collections.Generic.List[object]]::new()
$characters = [Collections.Generic.List[object]]::new()
$unique = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
function Add-Asset([string]$RelativePath) {
    Assert-Export ($unique.Add($RelativePath)) 'ui_export_duplicate_asset'
    $source = Join-Path $sourceRoot $RelativePath
    Assert-Export (Test-Path -LiteralPath $source -PathType Leaf) 'ui_export_asset_missing'
    for ($ancestor = $source; $ancestor -ne $sourceRoot; $ancestor = [IO.Path]::GetDirectoryName($ancestor)) {
        Assert-Export (-not ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'ui_export_reparse_point_forbidden'
    }
    $bytes = [IO.File]::ReadAllBytes($source)
    Assert-Export ($bytes.Length -ge 8 -and [BitConverter]::ToString($bytes, 0, 8) -ceq '89-50-4E-47-0D-0A-1A-0A') 'ui_export_png_signature_invalid'
    $files.Add([pscustomobject]@{ path = $RelativePath; byteLength = $bytes.Length; sha256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() })
}
foreach ($character in $presentation.characters) {
    $uid = [string]$character.characterUid
    Assert-Export ($uid -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') 'ui_export_character_uid_invalid'
    $relativePath = "assets/characters/$uid.png"
    Assert-Export ([string]$character.portraitPath -ceq "/editor/$relativePath") 'ui_export_portrait_path_invalid'
    Add-Asset $relativePath
    $characters.Add([pscustomobject]@{ characterUid = $uid; displayName = [string]$character.displayName; portraitPath = $relativePath })
}
foreach ($name in @('star-empty.png', 'star-filled.png', 'evolve.png')) { Add-Asset "assets/ui/$name" }
# All inputs have been checked before creating the destination. Existing files are never overwritten.
$null = New-Item -ItemType Directory -Path $destinationRoot
foreach ($entry in $files) {
    $source = Join-Path $sourceRoot $entry.path
    $destination = Join-Path $destinationRoot $entry.path
    $parent = [IO.Path]::GetDirectoryName($destination)
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    [IO.File]::Copy($source, $destination, $false)
    Assert-Export ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $entry.sha256 -and
        (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $entry.sha256) 'ui_export_copy_hash_mismatch'
}
$manifest = [ordered]@{
    contractId = 'nll/local-ui-reuse-assets/v1'; localOnly = $true; containsAccountData = $false
    characters = @($characters.ToArray()); files = @($files.ToArray())
    growth = @{ emptyStar = 'assets/ui/star-empty.png'; filledStar = 'assets/ui/star-filled.png'; coreBackground = 'assets/ui/evolve.png'; coreText = '1..6; MAX for 7'; coreTextIsNotPartOfImage = $true }
}
[IO.File]::WriteAllText((Join-Path $destinationRoot 'manifest.private.json'), ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
Write-Output "Local UI export verified: $($characters.Count) portraits + 3 growth images; no account state."
