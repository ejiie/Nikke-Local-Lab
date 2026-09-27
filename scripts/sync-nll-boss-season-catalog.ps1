[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [Parameter(Mandatory)][string]$ExpectedConfigurationSha256,
    [Parameter(Mandatory)][string]$SourcePackPath,
    [Parameter(Mandatory)][string]$LocaleSourcePath,
    [Parameter(Mandatory)][string]$CatalogMaterializerPath,
    [Parameter(Mandatory)][string]$OutputRoot
)
# Button-triggered local intake. No client start, writer tracing, registry/voice
# access, DB operation, runtime selection or official-install mutation.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Need([bool]$Value, [string]$Code) { if (-not $Value) { throw ('boss_catalog_sync_' + $Code) } }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Json([string]$Path, [object]$Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
}
Need ((Hash $ConfigurationPath) -ceq $ExpectedConfigurationSha256) 'configuration_changed'
$config = Get-Content -LiteralPath $ConfigurationPath -Raw | ConvertFrom-Json
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$allowed = [IO.Path]::GetFullPath((Join-Path (Split-Path $config.jobsRoot -Parent) 'season-sync/runs')).TrimEnd('\') + '\'
Need ($OutputRoot.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) 'output_invalid'
Need (@(Get-ChildItem -LiteralPath $OutputRoot -Force).Count -eq 0) 'output_not_empty'
Need ((Hash $config.catalogPath) -ceq $config.catalogSha256) 'catalog_changed'
$previous = Get-Content -LiteralPath $config.catalogPath -Raw | ConvertFrom-Json
Need ($config.PSObject.Properties.Name -contains 'bossImageExtraction') 'image_tool_missing'
$imageOptions = $config.bossImageExtraction
Need ((Hash $imageOptions.catalogToolPath) -ceq $imageOptions.catalogToolSha256) 'image_tool_changed'
$sourcePins = @('catalog.ndb', 'catalog.ndb.nds', 'chunk/store.cdb.idx') | ForEach-Object {
    $member = Join-Path $imageOptions.sourceRoot $_
    if (Test-Path -LiteralPath $member -PathType Leaf) { Hash $member } else { 'missing' }
}
$imageIdentity = 'enikk_then_local_game_dp/v1:' + ($sourcePins -join ':')
$previousImageSource = Join-Path (Split-Path $config.catalogPath -Parent) 'image-source.json'
$imagesUnchanged = (Test-Path -LiteralPath $previousImageSource -PathType Leaf) -and
    ((Get-Content -LiteralPath $previousImageSource -Raw | ConvertFrom-Json).identity -ceq $imageIdentity)
# The .exe is a stable .NET apphost; the implementation changes in its DLL.
$readerHash = Hash ([IO.Path]::ChangeExtension($CatalogMaterializerPath, '.dll'))
$readerUnchanged = $false
if (Test-Path -LiteralPath $previousImageSource -PathType Leaf) {
    $previousSource = Get-Content -LiteralPath $previousImageSource -Raw | ConvertFrom-Json
    $readerUnchanged = ($previousSource.PSObject.Properties.Name -contains 'catalogReaderSha256') -and
        ($previousSource.catalogReaderSha256 -ceq $readerHash)
}
Need (Test-Path -LiteralPath $SourcePackPath -PathType Leaf) 'source_missing'
$pack = Join-Path $OutputRoot 'StaticData.pack'
# Keep only a stable copy of the file selected by the user. Never alter its source.
$source = [IO.File]::Open($SourcePackPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    Need ($source.Length -gt 0 -and $source.Length -le 67108864) 'source_invalid'
    $target = [IO.File]::Open($pack, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $source.CopyTo($target); $target.Flush($true) } finally { $target.Dispose() }
} finally { $source.Dispose() }
$packHash = Hash $pack
function Unchanged {
    # Exact file created by this invocation, never a client file or shared input.
    Remove-Item -LiteralPath $pack
    Json (Join-Path $OutputRoot 'sync-result.json') @{statusCode='unchanged';configurationPath=$null;configurationSha256=$null}
}
if ($packHash -ceq $previous.sourceStaticDataSha256 -and $imagesUnchanged -and $readerUnchanged) { Unchanged; return }
$empty = Join-Path $OutputRoot 'empty-locales'
New-Item -ItemType Directory -Path $empty | Out-Null
$discovery = Join-Path $OutputRoot 'discovery'
& $CatalogMaterializerPath --export-local-boss-season-catalog $discovery --static-pack $pack `
    --game-config $config.gameConfigPath --locale-root $empty *> (Join-Path $OutputRoot 'discovery.log')
Need ($LASTEXITCODE -eq 0) 'source_unreadable'
$found = Get-Content -LiteralPath (Join-Path $discovery 'catalog.json') -Raw | ConvertFrom-Json
$recovered = [Collections.Generic.HashSet[int]]::new()
foreach ($row in $found.seasons) {
    if ($row.seasonNumber -le $previous.maximumKnownSeason -and $row.discoveryStatusCode -ceq 'resolved' -and
        $previous.seasons[$row.seasonNumber - 1].discoveryStatusCode -ceq 'unresolved') {
        [void]$recovered.Add([int]$row.seasonNumber)
    }
}
if ($found.maximumKnownSeason -le $previous.maximumKnownSeason -and $imagesUnchanged -and $recovered.Count -eq 0) { Unchanged; return }

$locales = Join-Path $OutputRoot 'locales'
$body = Join-Path $LocaleSourcePath 'catalog.ndb'
$signature = $body + '.nds'
Need ($config.PSObject.Properties.Name -contains 'nativePipeline') 'locale_tool_missing'
& $config.nativePipeline.dotnetPath $config.nativePipeline.catalogToolPath stage-boss-catalog-locales `
    $LocaleSourcePath $locales (Hash $body) (Hash $signature) *> (Join-Path $OutputRoot 'locales.log')
Need ($LASTEXITCODE -eq 0) 'locales_unreadable'
$localized = Join-Path $OutputRoot 'localized'
try {
    & $CatalogMaterializerPath --export-local-boss-season-catalog $localized --static-pack $pack `
        --game-config $config.gameConfigPath --locale-root $locales *> (Join-Path $OutputRoot 'localized.log')
    Need ($LASTEXITCODE -eq 0) 'source_unreadable'
} finally {
    $resolvedLocales = [IO.Path]::GetFullPath($locales)
    Need ($resolvedLocales -ceq (Join-Path $OutputRoot 'locales') -and
        $resolvedLocales.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) 'cleanup_scope_invalid'
    [IO.Directory]::Delete($resolvedLocales, $true)
}
$catalogPath = Join-Path $localized 'catalog.json'
$hintsPath = Join-Path $localized 'images.private.json'
$hints = Get-Content -LiteralPath $hintsPath -Raw | ConvertFrom-Json
if ($imagesUnchanged) {
    $hints.images = @($hints.images | Where-Object { $_.seasonNumber -gt $previous.maximumKnownSeason -or $recovered.Contains([int]$_.seasonNumber) })
}
Json $hintsPath $hints
$presentation = Join-Path $OutputRoot 'presentation'
& $config.pythonPath (Join-Path $config.repositoryRoot 'scripts/materialize-nll-boss-catalog-images.py') `
    --catalog $catalogPath --catalog-sha256 (Hash $catalogPath) --hints $hintsPath --hints-sha256 (Hash $hintsPath) `
    --output-root $presentation --local-source $imageOptions.sourceRoot `
    --catalog-tool $imageOptions.catalogToolPath --catalog-tool-sha256 $imageOptions.catalogToolSha256 `
    --dotnet $config.nativePipeline.dotnetPath --unitypy-root $config.unityPyRoot *> (Join-Path $OutputRoot 'images.log')
Need ($LASTEXITCODE -eq 0) 'images_failed'
$catalogPath = Join-Path $presentation 'catalog.json'
$next = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
foreach ($row in $previous.seasons) {
    $replacement = @($next.seasons | Where-Object seasonNumber -EQ $row.seasonNumber)
    if ($recovered.Contains([int]$row.seasonNumber)) {
        foreach ($name in @('displayName','defaultWeaknessCode','discoveryStatusCode','failureCode','nameStatusCode')) {
            $row.$name = $replacement[0].$name
        }
    }
    if ($replacement.Count -eq 1 -and $replacement[0].imageStatusCode -ceq 'resolved') {
        # Preserve existing names, weaknesses and discovery metadata. Only the
        # successfully extracted presentation image changes for an old season.
        $row.imageStatusCode = 'resolved'
        $row.imageSha256 = $replacement[0].imageSha256
        continue
    }
    if ($row.imageStatusCode -cne 'resolved') { continue }
    $image = Join-Path (Split-Path $config.catalogPath -Parent) ('images/' + $row.imageSha256 + '.png')
    Need ((Hash $image) -ceq $row.imageSha256) 'image_changed'
    Copy-Item -LiteralPath $image -Destination (Join-Path $presentation ('images/' + $row.imageSha256 + '.png')) -Force
}
$addedSeasons = @($next.seasons | Where-Object seasonNumber -GT $previous.maximumKnownSeason)
if ($addedSeasons.Count -eq 0) {
    # An image-only refresh must not replace combat/static-data inputs.
    $next = $previous
} else {
    $next.seasons = @($previous.seasons) + $addedSeasons
}
Json $catalogPath $next
Json (Join-Path $presentation 'image-source.json') @{identity=$imageIdentity;providerCode='enikk_then_local_game_dp/v1';catalogReaderSha256=$readerHash}
$oldCatalog = $config.catalogPath
$oldPack = $config.staticDataPackPath
$config.catalogPath = $catalogPath
$config.catalogSha256 = Hash $catalogPath
$config.inputPins = @($config.inputPins | Where-Object { $_.path -ine $oldCatalog }) +
    @([pscustomobject]@{path=$catalogPath;sha256=$config.catalogSha256})
if ($addedSeasons.Count -gt 0 -or ($recovered.Count -gt 0 -and $packHash -cne $previous.sourceStaticDataSha256)) {
    if ($next.sourceStaticDataSha256 -cne $packHash) {
        $next.sourceStaticDataSha256 = $packHash
        Json $catalogPath $next
        $config.catalogSha256 = Hash $catalogPath
        $config.inputPins = @($config.inputPins | Where-Object { $_.path -ine $catalogPath }) +
            @([pscustomobject]@{path=$catalogPath;sha256=$config.catalogSha256})
    }
    $config.staticDataPackPath = $pack
    $config.inputPins = @($config.inputPins | Where-Object { $_.path -ine $oldPack }) +
        @([pscustomobject]@{path=$pack;sha256=$packHash})
} else { Remove-Item -LiteralPath $pack }
$nextConfig = Join-Path $OutputRoot 'configuration.private.json'
Json $nextConfig $config
Json (Join-Path $OutputRoot 'sync-result.json') @{statusCode='updated';configurationPath=$nextConfig;configurationSha256=(Hash $nextConfig)}
