[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path $PSScriptRoot '..\artifacts\phase-d\presentation-assets\consoles')
)

# Public mirrors of original game item artwork, not an authenticated game API.
# Keep the downloaded media and resolved upstream image identifiers out of Git.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Net.Http
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$items = [ordered]@{
    common = @{ slug = 're-energy'; title = 'RE-Energy' }
    attacker = @{ slug = 'attacker-common-console'; title = 'Attacker Common Console' }
    defender = @{ slug = 'defender-common-console'; title = 'Defender Common Console' }
    supporter = @{ slug = 'supporter-common-console'; title = 'Supporter Common Console' }
    elysion = @{ slug = 'elysion-common-console'; title = 'Elysion Common Console' }
    missilis = @{ slug = 'missilis-common-console'; title = 'Missilis Common Console' }
    tetra = @{ slug = 'tetra-common-console'; title = 'Tetra Common Console' }
    pilgrim = @{ slug = 'pilgrim-common-console'; title = 'Pilgrim Common Console' }
    abnormal = @{ slug = 'abnormal-common-console'; title = 'Abnormal Common Console' }
}
$handler = [Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$handler.UseCookies = $false
$handler.UseDefaultCredentials = $false
$client = [Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(25)
$client.MaxResponseContentBufferSize = 2MB
$prepared = [Collections.Generic.List[object]]::new()
try {
    foreach ($entry in $items.GetEnumerator()) {
        $pageUri = 'https://nikke.gg/items/' + $entry.Value.slug + '/'
        $html = $client.GetStringAsync($pageUri).GetAwaiter().GetResult()
        $title = [regex]::Match($html, '<meta property="og:title" content="([^"]+)"').Groups[1].Value
        if ($title -cne ($entry.Value.title + ' - Nikke Item - Nikke.gg')) {
            throw ('console_asset_title_mismatch:' + $entry.Key)
        }
        $imageValue = [regex]::Match($html, '<meta property="og:image" content="([^"]+)"').Groups[1].Value
        $imageUri = $null
        if (-not [uri]::TryCreate($imageValue, [UriKind]::Absolute, [ref]$imageUri) -or
            $imageUri.Scheme -cne 'https' -or $imageUri.Host -cne 'static.dotgg.gg' -or
            $imageUri.Port -ne 443 -or $imageUri.UserInfo -or $imageUri.Query -or $imageUri.Fragment -or
            $imageUri.AbsolutePath -cnotmatch '^/nikke/items/[a-zA-Z0-9_-]+\.webp$') {
            throw ('console_asset_source_invalid:' + $entry.Key)
        }
        $bytes = $client.GetByteArrayAsync($imageUri).GetAwaiter().GetResult()
        if ($bytes.Length -lt 16 -or $bytes.Length -gt 1MB -or
            [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne 'RIFF' -or
            [Text.Encoding]::ASCII.GetString($bytes, 8, 4) -cne 'WEBP') {
            throw ('console_asset_webp_invalid:' + $entry.Key)
        }
        $prepared.Add(@{ code = $entry.Key; bytes = $bytes; sourcePage = $pageUri })
    }
    # Finish all nine reads/validations before writing any output member.
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    $members = foreach ($item in $prepared) {
        $path = Join-Path $OutputRoot ($item.code + '.webp')
        [IO.File]::WriteAllBytes($path, $item.bytes)
        [ordered]@{
            coordinateCode = $item.code
            fileName = $item.code + '.webp'
            sourcePage = $item.sourcePage
            byteLength = $item.bytes.Length
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $receipt = [ordered]@{
        contractId = 'nll/console-presentation-assets/v1'
        materializedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        artworkKind = 'original_game_item_icon_public_mirror'
        commonArtworkKind = 're_energy'
        sourceHost = 'static.dotgg.gg'
        officialAccountOrSessionUsed = $false
        memberCount = $prepared.Count
        members = @($members)
    }
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'console-assets.receipt.json'),
        ($receipt | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ Status = 'ready'; ConsoleCount = $prepared.Count; OutputRoot = $OutputRoot }
}
catch {
    # Upstream URLs can contain game identifiers. Do not echo HTTP exceptions.
    throw 'console_presentation_asset_materialization_failed'
}
finally { $client.Dispose(); $handler.Dispose() }
