[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [Parameter(Mandatory)][string]$ExpectedConfigurationSha256,
    [Parameter(Mandatory)][string]$OutputRoot
)
# Button-triggered read/import. No account edits, game launch or voice settings.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Need([bool]$Value,[string]$Code) { if(-not $Value){throw ('character_catalog_sync_'+$Code)} }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Json([string]$Path,[object]$Value) { [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 50),[Text.UTF8Encoding]::new($false)) }
Need ((Hash $ConfigurationPath) -ceq $ExpectedConfigurationSha256) 'configuration_changed'
$config=Get-Content -LiteralPath $ConfigurationPath -Raw|ConvertFrom-Json
$sync=$config.characterSync
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
$allowed=[IO.Path]::GetFullPath((Join-Path $sync.root 'runs')).TrimEnd('\')+'\'
Need ($OutputRoot.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) 'output_invalid'
Need (@(Get-ChildItem -LiteralPath $OutputRoot -Force).Count -eq 0) 'output_not_empty'
foreach($pin in $sync.toolPins){ Need ((Hash $pin.path) -ceq $pin.sha256) 'tool_changed' }
$presentationPath=[IO.Path]::GetFullPath($sync.presentationPath)
Need (-not $presentationPath.StartsWith('C:\NIKKE\',[StringComparison]::OrdinalIgnoreCase)) 'official_output_forbidden'
$beforeHash=Hash $presentationPath
$previous=Get-Content -LiteralPath $presentationPath -Raw|ConvertFrom-Json
Need ($previous.contractId -ceq 'nll/control-center-presentation/v1') 'presentation_invalid'
$pack=Join-Path $OutputRoot 'StaticData.pack'
$decoded=Join-Path $OutputRoot 'decoded'
$locales=Join-Path $OutputRoot 'locales'
$stagedSd=Join-Path $OutputRoot 'sd.bin'
function StableCopy([string]$Source,[string]$Target,[long]$Limit) {
    $inputStream=[IO.File]::Open($Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        Need ($inputStream.Length -gt 0 -and $inputStream.Length -le $Limit) 'source_invalid'
        $destination=[IO.File]::Open($Target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {$inputStream.CopyTo($destination);$destination.Flush($true)} finally {$destination.Dispose()}
    } finally {$inputStream.Dispose()}
}
try {
    StableCopy $config.seasonSync.sourcePackPath $pack 67108864
    StableCopy $sync.gameConfigArchivePath $stagedSd 16777216
    $localeRoot=$config.seasonSync.localeSourcePath
    $body=Join-Path $localeRoot 'catalog.ndb'
    $sourceKey=(Hash $pack)+':'+(Hash $stagedSd)+':'+(Hash $body)
    $assetRoot=Join-Path (Split-Path $presentationPath -Parent) 'assets/characters'
    $missingBefore=@($previous.characters|Where-Object {-not (Test-Path -LiteralPath (Join-Path $assetRoot ($_.characterUid+'.png')))})
    if($previous.PSObject.Properties.Name -contains 'characterSyncSource' -and
       $previous.characterSyncSource -ceq $sourceKey -and $missingBefore.Count -eq 0){
        Json (Join-Path $OutputRoot 'sync-result.json') @{statusCode='unchanged';addedCharacterCount=0;missingPortraitCount=0}
        return
    }
    & $config.nativePipeline.dotnetPath $config.nativePipeline.catalogToolPath stage-boss-catalog-locales `
        $localeRoot $locales (Hash $body) (Hash ($body+'.nds')) *> (Join-Path $OutputRoot 'locales.log')
    Need ($LASTEXITCODE -eq 0) 'locales_unreadable'
    & $sync.materializerPath --export-local-character-source $decoded --static-pack $pack `
        --game-config $config.gameConfigPath --locale-root $locales --identity-secret-env NIKKE_LAB_ID_SECRET *> (Join-Path $OutputRoot 'decode.log')
    Need ($LASTEXITCODE -eq 0) 'source_unreadable'
    # The existing read-only importer expects a separate source root. This run
    # directory is outside the repository and the runtime-home directory.
    $importConfig=Get-Content (Join-Path $config.repositoryRoot 'config/appsettings.example.json') -Raw|ConvertFrom-Json
    $importConfig.paths.gameRoot=$OutputRoot
    $importConfigPath=Join-Path $OutputRoot 'import-config.json'
    Json $importConfigPath $importConfig
    $nextPath=Join-Path $OutputRoot 'presentation.json'
    & $config.nativePipeline.dotnetPath $sync.importerPath character-catalog-import --config $importConfigPath `
        --repository-root $config.repositoryRoot --static-root $decoded --static-file StaticData.zip `
        --game-config-file sd.bin --presentation-input $presentationPath --presentation-output $nextPath `
        --character-metadata (Join-Path $decoded 'metadata.private.json') *> (Join-Path $OutputRoot 'import.log')
    Need ($LASTEXITCODE -eq 0) 'import_failed'
    $next=Get-Content -LiteralPath $nextPath -Raw|ConvertFrom-Json
    $oldUids=@{}; foreach($row in $previous.characters){$oldUids[$row.characterUid]=$true}
    $added=@($next.characters|Where-Object {-not $oldUids.ContainsKey($_.characterUid)}).Count
    $missing=@($next.characters|Where-Object {-not (Test-Path -LiteralPath (Join-Path $assetRoot ($_.characterUid+'.png')))})
    if($missing.Count -gt 0){
        $imageInput=Join-Path $OutputRoot 'image-input.json'
        Json $imageInput @{contractId='nll/control-center-presentation/v1';characters=$missing}
        $images=Join-Path $OutputRoot 'images'
        try {
            & (Join-Path $config.repositoryRoot 'scripts/materialize-nll-phase-d-presentation-assets.ps1') `
                -PresentationPath $imageInput -OutputRoot $images -CharactersOnly -MaximumMissingCharacterCount $missing.Count *> (Join-Path $OutputRoot 'images.log')
            New-Item -ItemType Directory -Path $assetRoot -Force|Out-Null
            foreach($row in $missing){
                $leaf=$row.characterUid+'.png'
                $source=Join-Path $images ('characters/'+$leaf)
                if(Test-Path -LiteralPath $source){
                    $destination=Join-Path $assetRoot $leaf
                    $stagedImage=$destination+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
                    try {Copy-Item -LiteralPath $source -Destination $stagedImage;[IO.File]::Move($stagedImage,$destination,$true)}
                    finally {if(Test-Path -LiteralPath $stagedImage){Remove-Item -LiteralPath $stagedImage}}
                }
            }
        } catch {
            # Missing portraits remain explicit in the receipt and retry on the
            # next sync. A CDN outage does not discard valid character metadata.
            'character_portraits_unavailable'|Set-Content (Join-Path $OutputRoot 'images-status.txt')
        }
    }
    $missingCount=@($next.characters|Where-Object {-not (Test-Path -LiteralPath (Join-Path $assetRoot ($_.characterUid+'.png')))}).Count
    $next|Add-Member -NotePropertyName characterSyncSource -NotePropertyValue $sourceKey -Force
    Json $nextPath $next
    Need ((Hash $presentationPath) -ceq $beforeHash) 'presentation_changed'
    # The live file switches only after parsing/import succeed. Existing builds
    # stay bound to their old immutable snapshots until an explicit ownership Save.
    $temporary=$presentationPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        Copy-Item -LiteralPath $nextPath -Destination $temporary
        [IO.File]::Replace($temporary,$presentationPath,(Join-Path $OutputRoot 'previous-presentation.json'))
    } finally {if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary}}
    Json (Join-Path $OutputRoot 'sync-result.json') @{statusCode='updated';addedCharacterCount=$added;missingPortraitCount=$missingCount}
} finally {
    # Delete only this invocation's decoded copies, never the input cache/install.
    foreach($path in @($decoded,$locales)){
        $resolved=[IO.Path]::GetFullPath($path)
        Need ($resolved.StartsWith($OutputRoot+'\',[StringComparison]::OrdinalIgnoreCase)) 'cleanup_scope_invalid'
        if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
    }
    foreach($path in @($pack,$stagedSd)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
}
