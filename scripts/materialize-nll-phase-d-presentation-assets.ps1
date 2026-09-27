[CmdletBinding()]
param(
    [string]$PresentationPath =
        'C:\NLL\ControlCenter\app\wwwroot\editor\presentation.json',
    [string]$OutputRoot =
        'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\artifacts\phase-d\presentation-assets',
    [ValidateRange(0, 10000)] [int]$MaximumMissingCharacterCount = 0,
    [switch]$CharactersOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Net.Http

function Assert-PresentationAsset {
    param([bool]$Condition, [string]$Code)
    if (-not $Condition) { throw $Code }
}
function Get-PresentationAssetSha256 {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Get-NormalizedPresentationName {
    param([string]$Value)
    $normalized = $Value.Normalize([Text.NormalizationForm]::FormKC).ToUpperInvariant()
    [Text.RegularExpressions.Regex]::Replace($normalized, '[\p{P}\p{Z}\s]', '')
}
function Get-BlablalinkDjb2Value {
    param([string]$Value, [int64]$Seed)
    [int64]$hash = $Seed
    foreach ($character in $Value.ToCharArray()) {
        [int64]$unsigned = (($hash * 33L + [int][char]$character) -band 0xffffffffL)
        $hash = if ($unsigned -ge 0x80000000L) {
            $unsigned - 0x100000000L
        }
        else { $unsigned }
    }
    $hash
}
function Get-BlablalinkNormalResourceUri {
    param([string]$LogicalPath)
    $path = $LogicalPath.TrimStart('/')
    $segments = @($path.Split('/'))
    $primes = @(
        224737L, 1000639L, 2654435761L,
        2654435769L, 1000621L, 4294967291L)
    Assert-PresentationAsset `
        ($segments.Count -ge 2 -and $segments.Count -le ($primes.Count + 1)) `
        'phase_d_blablalink_resource_path_invalid'
    $output = New-Object Collections.Generic.List[string]
    for ($index = 0; $index -lt ($segments.Count - 1); $index++) {
        [int64]$seed = $primes[$index]
        [int64]$hash = Get-BlablalinkDjb2Value -Value $path -Seed $seed
        [int64]$remainder = (($hash % $seed) + $seed) % $seed
        $first = [char][int](97 + (([Math]::Floor($remainder / 26)) % 26))
        $second = [char][int](97 + ($remainder % 26))
        $number = ([string]($remainder % 99)).PadLeft(2, '0')
        $output.Add(([string]$first + [string]$second + '-' + $number))
    }
    $leaf = $segments[-1]
    $firstDot = $leaf.IndexOf('.')
    Assert-PresentationAsset ($firstDot -gt 0) 'phase_d_blablalink_resource_leaf_invalid'
    $extension = $leaf.Substring($firstDot + 1)
    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        $digest = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($path))
    }
    finally { $md5.Dispose() }
    $hashLeaf = ([BitConverter]::ToString($digest).Replace('-', '').ToLowerInvariant()) +
        '.' + $extension
    $output.Add($hashLeaf)
    'https://sg-tools-cdn.blablalink.com/' + ($output -join '/')
}
function Write-AtomicPresentationBytes {
    param([string]$Path, [byte[]]$Bytes)
    $temporary = $Path + '.partial-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllBytes($temporary, $Bytes)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Write-AtomicPresentationJson {
    param([string]$Path, [object]$Value)
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(
        (($Value | ConvertTo-Json -Depth 8) + "`n"))
    Write-AtomicPresentationBytes -Path $Path -Bytes $bytes
}
function Test-PngBytes {
    param([byte[]]$Bytes)
    $Bytes.Length -gt 8 -and
        $Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50 -and
        $Bytes[2] -eq 0x4e -and $Bytes[3] -eq 0x47
}
function Get-RemotePresentationBytes {
    param([Net.Http.HttpClient]$Client, [string]$Uri)
    try {
        $response = $Client.GetAsync($Uri).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) { return $null }
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            if (-not (Test-PngBytes $bytes)) { return $null }
            $bytes
        }
        finally { $response.Dispose() }
    }
    catch { $null }
}

Assert-PresentationAsset `
    ([IO.Path]::IsPathRooted($PresentationPath) -and
     (Test-Path -LiteralPath $PresentationPath -PathType Leaf)) `
    'phase_d_presentation_asset_catalog_missing'
Assert-PresentationAsset ([IO.Path]::IsPathRooted($OutputRoot)) `
    'phase_d_presentation_asset_output_invalid'
$presentation = Get-Content -LiteralPath $PresentationPath -Raw | ConvertFrom-Json
Assert-PresentationAsset `
    ($presentation.contractId -ceq 'nll/control-center-presentation/v1' -and
     @($presentation.characters).Count -gt 0) `
    'phase_d_presentation_asset_catalog_invalid'

$handler = New-Object Net.Http.HttpClientHandler
$client = New-Object Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(25)
$client.DefaultRequestHeaders.UserAgent.ParseAdd('NLL-ControlCenter-AssetMaterializer/1.0')
try {
    # Blabla's own Shifty's Pad bundle resolves normal game resources through
    # the public sg-tools CDN using an obfuscated path. Keep the logical path
    # in memory only and persist only lab-owned character UIDs in the receipt.
    $indexUri = Get-BlablalinkNormalResourceUri `
        -LogicalPath 'character/ko/nikke_list_v2.json'
    $indexText = $client.GetStringAsync($indexUri).GetAwaiter().GetResult()
    $index = ConvertFrom-Json -InputObject $indexText
    Assert-PresentationAsset (@($index).Count -gt 100) 'phase_d_presentation_asset_index_invalid'

    $exact = @{}
    $normalized = @{}
    foreach ($entry in $index) {
        $nameProperty = $entry.PSObject.Properties['name_localkey']
        $resourceProperty = $entry.PSObject.Properties['resource_id']
        if ($null -eq $nameProperty -or $null -eq $resourceProperty) { continue }
        $name = [string]$nameProperty.Value.name
        if ([string]::IsNullOrWhiteSpace($name) -or
            [string]::IsNullOrWhiteSpace([string]$resourceProperty.Value)) { continue }
        if (-not $exact.ContainsKey($name)) { $exact[$name] = @() }
        $exact[$name] += $entry
        $key = Get-NormalizedPresentationName $name
        if (-not $normalized.ContainsKey($key)) { $normalized[$key] = @() }
        $normalized[$key] += $entry
    }

    $characterRoot = Join-Path $OutputRoot 'characters'
    $bossRoot = Join-Path $OutputRoot 'bosses'
    $uiRoot = Join-Path $OutputRoot 'ui'
    New-Item -ItemType Directory -Path $characterRoot,$bossRoot,$uiRoot -Force | Out-Null
    $characterMembers = New-Object Collections.Generic.List[object]
    $unresolvedCharacterUids = New-Object Collections.Generic.List[string]
    $unresolvedMappingUids = New-Object Collections.Generic.List[string]
    $unavailableAssetUids = New-Object Collections.Generic.List[string]
    $weaponCodes = @{
        assault_rifle = 'AR'; machine_gun = 'MG'; rocket_launcher = 'RL'
        shotgun = 'SG'; sniper_rifle = 'SR'; submachine_gun = 'SMG'
    }
    foreach ($character in @($presentation.characters)) {
        $matches = @($exact[[string]$character.displayName])
        if ($matches.Count -gt 1) {
            # Blabla currently contains two display-name-identical Sakura
            # entries. Resolve duplicates from public presentation metadata,
            # never by guessing from order or a raw game identifier.
            $matches = @($matches | Where-Object {
                ([string]$_.original_rare).ToLowerInvariant() -ceq
                    ([string]$character.rarityCode).ToLowerInvariant() -and
                ([string]$_.class).ToLowerInvariant() -ceq
                    ([string]$character.combatClassCode).ToLowerInvariant() -and
                ([string]$_.corporation).ToLowerInvariant() -ceq
                    ([string]$character.manufacturerCode).ToLowerInvariant() -and
                ([string]$_.shot_id.element.weapon_type).ToUpperInvariant() -ceq
                    $weaponCodes[[string]$character.weaponCode]
            })
        }
        if ($matches.Count -ne 1) {
            $matches = @($normalized[(Get-NormalizedPresentationName ([string]$character.displayName))])
            if ($matches.Count -gt 1) {
                $matches = @($matches | Where-Object {
                    ([string]$_.original_rare).ToLowerInvariant() -ceq
                        ([string]$character.rarityCode).ToLowerInvariant() -and
                    ([string]$_.class).ToLowerInvariant() -ceq
                        ([string]$character.combatClassCode).ToLowerInvariant() -and
                    ([string]$_.corporation).ToLowerInvariant() -ceq
                        ([string]$character.manufacturerCode).ToLowerInvariant() -and
                    ([string]$_.shot_id.element.weapon_type).ToUpperInvariant() -ceq
                        $weaponCodes[[string]$character.weaponCode]
                })
            }
        }
        if ($matches.Count -ne 1) {
            $unresolvedCharacterUids.Add([string]$character.characterUid)
            $unresolvedMappingUids.Add([string]$character.characterUid)
            continue
        }

        $resourceId = ([string]$matches[0].resource_id).PadLeft(3, '0')
        $uri = Get-BlablalinkNormalResourceUri `
            -LogicalPath ("character/mi/mi_c${resourceId}_00_s.png")
        $bytes = Get-RemotePresentationBytes -Client $client -Uri $uri
        if ($null -eq $bytes) {
            $unresolvedCharacterUids.Add([string]$character.characterUid)
            $unavailableAssetUids.Add([string]$character.characterUid)
            continue
        }
        $leaf = ([string]$character.characterUid) + '.png'
        $path = Join-Path $characterRoot $leaf
        Write-AtomicPresentationBytes -Path $path -Bytes $bytes
        $characterMembers.Add([ordered]@{
            characterUid = [string]$character.characterUid
            byteLength = (Get-Item -LiteralPath $path).Length
            sha256 = Get-PresentationAssetSha256 $path
        })
    }

    if ($CharactersOnly) {
        Assert-PresentationAsset ($unresolvedCharacterUids.Count -le $MaximumMissingCharacterCount) 'phase_d_presentation_character_assets_incomplete'
        Write-AtomicPresentationJson (Join-Path $OutputRoot 'assets.receipt.json') ([ordered]@{
            contractId='nll/character-portraits/v1'; characterMembers=[object[]]$characterMembers
            unresolvedCharacterUids=[string[]]$unresolvedCharacterUids
        })
        return
    }
    $bossMembers = New-Object Collections.Generic.List[object]
    foreach ($boss in @(
        @{ season = 26; uri = 'https://enikk.app/bosses/full_xbg002_zeus.png' },
        @{ season = 29; uri = 'https://enikk.app/bosses/full_bba001_zeus.png' },
        @{ season = 34; uri = 'https://enikk.app/bosses/full_xbg004_zeus.png' })) {
        $bytes = Get-RemotePresentationBytes -Client $client -Uri $boss.uri
        Assert-PresentationAsset ($null -ne $bytes) `
            ('phase_d_presentation_boss_asset_missing:' + $boss.season)
        $path = Join-Path $bossRoot ('season-' + $boss.season + '.png')
        Write-AtomicPresentationBytes -Path $path -Bytes $bytes
        $bossMembers.Add([ordered]@{
            season = $boss.season
            byteLength = (Get-Item -LiteralPath $path).Length
            sha256 = Get-PresentationAssetSha256 $path
        })
    }

    # These are the exact public image assets used by the authenticated
    # Shifty's Pad card/detail UI. Store stable local names so the Control
    # Center never depends on a signed-in browser session at runtime.
    $uiMembers = New-Object Collections.Generic.List[object]
    $uiAssets = [ordered]@{
        'code-fire.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/icon-code-fire.png'
        'code-water.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/icon-code-water.png'
        'code-wind.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/icon-code-wind.png'
        'code-electric.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/icon-code-electronic.png'
        'code-iron.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/icon-code-iron.png'
        'weapon-assault_rifle.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/icon-weapon-assault_rifle.png'
        'weapon-machine_gun.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/icon-weapon-machine_gun.png'
        'weapon-rocket_launcher.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/icon-weapon-rocket_launcher.png'
        'weapon-shotgun.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/icon-weapon-shot_gun.png'
        'weapon-sniper_rifle.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/icon-weapon-sniper_rifle.png'
        'weapon-submachine_gun.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/icon-weapon-sub_machine_gun.png'
        'burst-1.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/icon-burst-1.png'
        'burst-2.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/icon-burst-2.png'
        'burst-3.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/icon-burst-3.png'
        'burst-p.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/icon-burst-p.png'
        'job-attacker.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/nikkes/nikke-job-attacker--yellow.png'
        'job-defender.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/nikkes/nikke-job-defender--yellow.png'
        'job-supporter.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/nikkes/nikke-job-supporter--yellow.png'
        'star-empty.png' = 'https://www.blablalink.com/assets/nikke/version/default/assets/icon-nikke-star-Bv0b_V3C.png'
        'star-filled.png' = 'https://www.blablalink.com/assets/nikke/version/default/assets/icon-nikke-star-gold-BnTupWrm.png'
        'evolve.png' = 'https://www.blablalink.com/assets/nikke/version/default/assets/icon-evolve-z8366Dwx.png'
        'card-bottom.png' = 'https://www.blablalink.com/assets/nikke/version/default/assets/nikkes-item-btmbg-UZMV6c4h.png'
        'equipment-background.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/nikkes/nikke-equip-bg.png'
        'overload.png' = 'https://www.blablalink.com/assets/nikke/version/default/shiftysassets/images/icon-overload.png'
        'tab-mask.png' = 'https://www.blablalink.com/assets/nikke/version/default/assets/mask-tab-IdeLJVuW.png'
    }
    foreach ($asset in $uiAssets.GetEnumerator()) {
        $bytes = Get-RemotePresentationBytes -Client $client -Uri ([string]$asset.Value)
        Assert-PresentationAsset ($null -ne $bytes) `
            ('phase_d_presentation_ui_asset_missing:' + $asset.Key)
        $path = Join-Path $uiRoot ([string]$asset.Key)
        Write-AtomicPresentationBytes -Path $path -Bytes $bytes
        $uiMembers.Add([ordered]@{
            leaf = [string]$asset.Key
            byteLength = (Get-Item -LiteralPath $path).Length
            sha256 = Get-PresentationAssetSha256 $path
        })
    }

    Assert-PresentationAsset `
        ($unresolvedCharacterUids.Count -le $MaximumMissingCharacterCount) `
        ('phase_d_presentation_character_assets_incomplete:' +
         $unresolvedCharacterUids.Count)
    & (Join-Path $PSScriptRoot 'materialize-nll-console-presentation-assets.ps1') `
        -OutputRoot (Join-Path $OutputRoot 'consoles') | Out-Null
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase-d-presentation-assets/v1'
        materializedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        presentationSha256 = Get-PresentationAssetSha256 $PresentationPath
        characterAssetCount = $characterMembers.Count
        missingCharacterAssetCount = $unresolvedCharacterUids.Count
        unresolvedCharacterUids = [string[]]$unresolvedCharacterUids
        unresolvedCharacterMappingCount = $unresolvedMappingUids.Count
        unavailableCharacterAssetCount = $unavailableAssetUids.Count
        bossAssetCount = $bossMembers.Count
        uiAssetCount = $uiMembers.Count
        consoleAssetCount = 9
        consoleAssetReceiptSha256 = Get-PresentationAssetSha256 `
            (Join-Path $OutputRoot 'consoles\console-assets.receipt.json')
        supportedBossSeasons = @(26,29,34)
        characterAssetAuthorityCode = 'official_blablalink_shiftys_pad_mi_image'
        characterAssetSourceHost = 'sg-tools-cdn.blablalink.com'
        characterAssetPixelWidth = 256
        characterAssetPixelHeight = 512
        characterMembers = [object[]]$characterMembers
        bossMembers = [object[]]$bossMembers
        uiMembers = [object[]]$uiMembers
        rawGameResourceIdentifierPersisted = $false
        officialInstallRead = $false
        officialInstallModified = $false
        officialAccountOrSessionUsed = $false
    }
    $receiptPath = Join-Path $OutputRoot 'assets.receipt.json'
    Write-AtomicPresentationJson -Path $receiptPath -Value $receipt
    [pscustomobject]@{
        Receipt = $receipt
        ReceiptPath = $receiptPath
        ReceiptSha256 = Get-PresentationAssetSha256 $receiptPath
    } | ConvertTo-Json -Depth 10
}
finally {
    $client.Dispose()
    $handler.Dispose()
}
