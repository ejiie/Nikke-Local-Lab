param([Parameter(Mandatory)][string]$ConfigurationPath,
      [Parameter(Mandatory)][string]$ExpectedConfigurationSha256,
      [Parameter(Mandatory)][string]$MaterializerPath,
      [Parameter(Mandatory)][string]$ExpectedMaterializerSha256,
      [Parameter(Mandatory)][string]$OutputRoot)
$ErrorActionPreference = 'Stop'
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
if ((Hash $ConfigurationPath) -cne $ExpectedConfigurationSha256 -or
    (Hash ([IO.Path]::ChangeExtension($MaterializerPath, '.dll'))) -cne $ExpectedMaterializerSha256) {
  throw 'boss_union_input_changed'
}
$config = Get-Content -LiteralPath $ConfigurationPath -Raw | ConvertFrom-Json
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$allowed = [IO.Path]::GetFullPath((Join-Path $config.repositoryRoot 'artifacts')).TrimEnd('\') + '\'
if (-not $OutputRoot.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $OutputRoot)) {
  throw 'boss_union_output_invalid'
}
$ancestor = [IO.DirectoryInfo]::new($OutputRoot)
while ($null -ne $ancestor) {
  if ($ancestor.Exists -and ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'boss_union_output_invalid' }
  $ancestor = $ancestor.Parent
}
if ((Hash $config.nativePipeline.catalogToolPath) -cne $config.nativePipeline.catalogToolSha256) { throw 'boss_union_input_changed' }
$localeSource = $config.seasonSync.localeSourcePath
$locales = Join-Path $OutputRoot 'locales'
[IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
$body = Join-Path $localeSource 'catalog.ndb'
& $config.nativePipeline.dotnetPath $config.nativePipeline.catalogToolPath stage-boss-catalog-locales `
  $localeSource $locales (Hash $body) (Hash ($body + '.nds')) *> (Join-Path $OutputRoot 'locales.log')
if ($LASTEXITCODE -ne 0) { throw 'boss_union_locales_unreadable' }
& $MaterializerPath --export-union-raid-catalog (Join-Path $OutputRoot 'catalog') `
  --static-pack $config.staticDataPackPath --game-config $config.gameConfigPath --locale-root $locales `
  *> (Join-Path $OutputRoot 'catalog.log')
if ($LASTEXITCODE -ne 0) { throw 'boss_union_catalog_unreadable' }
$imageOptions = $config.bossImageExtraction
if ($null -eq $imageOptions) { throw 'boss_union_image_tool_missing' }
$catalogRoot = Join-Path $OutputRoot 'catalog'
$catalogPath = Join-Path $catalogRoot 'catalog.json'
$hintsPath = Join-Path $catalogRoot 'images.private.json'
$presentation = Join-Path $OutputRoot 'presentation'
& $config.pythonPath (Join-Path $config.repositoryRoot 'scripts/materialize-nll-boss-catalog-images.py') `
  --catalog $catalogPath --catalog-sha256 (Hash $catalogPath) --hints $hintsPath --hints-sha256 (Hash $hintsPath) `
  --output-root $presentation --local-source $imageOptions.sourceRoot `
  --catalog-tool $imageOptions.catalogToolPath --catalog-tool-sha256 $imageOptions.catalogToolSha256 `
  --dotnet $config.nativePipeline.dotnetPath --unitypy-root $config.unityPyRoot *> (Join-Path $OutputRoot 'images.log')
if ($LASTEXITCODE -ne 0) { throw 'boss_union_images_failed' }
# Keep the catalog and its private season sources at the existing output path.
Copy-Item -LiteralPath (Join-Path $presentation 'images') -Destination $catalogRoot -Recurse
Copy-Item -LiteralPath (Join-Path $presentation 'catalog.json') -Destination $catalogPath -Force
if ((Hash $ConfigurationPath) -cne $ExpectedConfigurationSha256) { throw 'boss_union_input_changed' }
# This directory was newly created above, remains inside the checked output root,
# and contains only our temporary decoded localization input.
$resolvedLocales = [IO.Path]::GetFullPath($locales)
if ($resolvedLocales -cne (Join-Path $OutputRoot 'locales') -or
    -not $resolvedLocales.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -or
    ((Get-Item -LiteralPath $resolvedLocales).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
  throw 'boss_union_cleanup_scope_invalid'
}
Remove-Item -LiteralPath $resolvedLocales -Recurse -Force
