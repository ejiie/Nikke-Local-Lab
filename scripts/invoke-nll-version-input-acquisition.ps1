[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedConfigSha256,
    [Parameter(Mandatory)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$ApprovedClientBuild,
    [switch]$ExecuteApprovedAcquisition
)

# Separate cold collector. Never invoked by an Epinel/client request handler.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Require([bool]$Condition, [string]$Code) {
    if (-not $Condition) { throw ('version_input_' + $Code) }
}
function Hash-File([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Assert-Cold {
    $active = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^(nikke|nikke_launcher|EpinelPS|NikkeLocalLab\..*Bootstrap)\.exe$' -or
        ($_.Name -eq 'dotnet.exe' -and $_.CommandLine -match 'EpinelPS')
    })
    Require ($active.Count -eq 0) 'runtime_not_cold'
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in 443, 8443 })
    Require ($listeners.Count -eq 0) 'runtime_listener_present'
}
function Assert-NoReparse([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $entry = Get-Item -LiteralPath $cursor -Force
            Require (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'staging_reparse'
        }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}
function Write-NewJson([string]$Path, [object]$Value) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 8))
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
}
function Validate-Uri([string]$Value) {
    $uri = $null
    Require ([Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) 'uri_invalid'
    Require ($uri.Scheme -ceq 'https' -and $uri.Authority -ceq 'cloud.nikke-kr.com' -and
        $uri.IsDefaultPort -and -not $uri.UserInfo -and -not $uri.Query -and -not $uri.Fragment -and
        $Value -ceq $uri.AbsoluteUri -and $uri.AbsolutePath -cmatch '^/prdenv/[A-Za-z0-9./_-]+$' -and
        -not $Value.Contains('/../') -and -not $Value.Contains('/./')) 'uri_boundary'
    return $uri
}

Require ((Get-Item -LiteralPath $ConfigPath).Length -le 65536) 'config_too_large'
Require ((Hash-File $ConfigPath) -ceq $ExpectedConfigSha256) 'config_hash_drift'
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
Require ($config.TargetVersion -ceq $ApprovedClientBuild) 'build_mismatch'
$staticUri = Validate-Uri ([string]$config.StaticDataMpk.Url)
Require ($staticUri.AbsolutePath.EndsWith('/mpk/StaticData.pack')) 'static_path_invalid'
$resourceBase = [string]$config.ResourceBaseURL
Require ($resourceBase.EndsWith('/{Platform}') -and $resourceBase.Split('{').Count -eq 2) 'resource_base_invalid'
Require ([string]$config.ResourceDataPackVersion -cmatch '^[0-9]{1,8}$') 'data_version_invalid'
$metadataUri = Validate-Uri ($resourceBase.Replace('{Platform}', 'StandaloneWindows64') +
    '/pck/latest-' + [string]$config.ResourceDataPackVersion + '.txt')
$members = @(
    [ordered]@{ role = 'static_pack'; uri = $staticUri.AbsoluteUri; file = 'StaticData.pack'; maxBytes = 268435456L },
    [ordered]@{ role = 'version_metadata'; uri = $metadataUri.AbsoluteUri; file = 'version-metadata.txt'; maxBytes = 65536L }
)
$manifest = [ordered]@{
    contract = 'nll/cold-version-input-request/v1'; build = $ApprovedClientBuild
    configSha256 = $ExpectedConfigSha256; members = $members
    timeoutSecondsPerMember = 120; redirects = $false; proxy = $false; credentials = $false
    destinationBoundary = 'new_git_external_staging_only'
}
if (-not $ExecuteApprovedAcquisition) {
    [ordered]@{ status = 'plan_validated_no_network'; build = $ApprovedClientBuild
        configSha256 = $ExpectedConfigSha256; memberCount = 2
        roles = @($members | ForEach-Object { $_.role }); totalByteLimit = 268500992
    } | ConvertTo-Json
    return
}

Assert-Cold
$base = 'C:\NLL\Staging\ResourceVersionInputs'
Assert-NoReparse $base
$assessment = Join-Path $base ([Guid]::NewGuid().ToString('D'))
Require (-not (Test-Path -LiteralPath $assessment)) 'assessment_exists'
New-Item -ItemType Directory -Path $assessment | Out-Null
$manifestPath = Join-Path $assessment 'request.private.json'
Write-NewJson $manifestPath $manifest
$manifestHash = Hash-File $manifestPath
$handler = [Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$handler.UseProxy = $false
$handler.UseCookies = $false
$handler.UseDefaultCredentials = $false
$handler.PreAuthenticate = $false
$handler.AutomaticDecompression = [Net.DecompressionMethods]::None
$client = [Net.Http.HttpClient]::new($handler)
$client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
$results = [Collections.Generic.List[object]]::new()
$failure = $null
try {
    foreach ($member in $members) {
        Assert-Cold
        Require ((Hash-File $ConfigPath) -ceq $ExpectedConfigSha256 -and
            (Hash-File $manifestPath) -ceq $manifestHash) 'request_drift'
        $cts = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(120))
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, [Uri]$member.uri)
        $response = $null
        try {
            $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
                $cts.Token).GetAwaiter().GetResult()
            if ([int]$response.StatusCode -eq 404) {
                $results.Add([ordered]@{ role = $member.role; status = 'exact_path_not_found'; httpStatus = 404 })
                continue
            }
            Require ([int]$response.StatusCode -eq 200) ('http_status_' + [int]$response.StatusCode)
            Require ($null -eq $response.Headers.Location -and -not $response.Headers.Contains('Set-Cookie') -and
                $response.Content.Headers.ContentEncoding.Count -eq 0) 'response_boundary'
            $declared = $response.Content.Headers.ContentLength
            Require ($null -eq $declared -or ($declared -gt 0 -and $declared -le $member.maxBytes)) 'declared_length'
            $destination = Join-Path $assessment $member.file
            $partial = $destination + '.partial'
            $source = $response.Content.ReadAsStreamAsync($cts.Token).GetAwaiter().GetResult()
            $output = $null
            try {
                $output = [IO.File]::Open($partial, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $buffer = [byte[]]::new(65536)
                [long]$total = 0
                while (($read = $source.ReadAsync($buffer, 0, $buffer.Length, $cts.Token).GetAwaiter().GetResult()) -gt 0) {
                    $total += $read
                    Require ($total -le $member.maxBytes) 'body_limit'
                    $output.Write($buffer, 0, $read)
                }
                Require ($total -gt 0 -and ($null -eq $declared -or $declared -eq $total)) 'body_incomplete'
                $output.Flush($true)
            }
            finally { if ($null -ne $output) { $output.Dispose() }; $source.Dispose() }
            [IO.File]::Move($partial, $destination, $false)
            $results.Add([ordered]@{ role = $member.role; status = 'acquired_hash_sealed'; httpStatus = 200
                byteLength = $total; sha256 = Hash-File $destination })
        }
        finally { if ($null -ne $response) { $response.Dispose() }; $request.Dispose(); $cts.Dispose() }
    }
    Assert-Cold
}
catch {
    $failure = if ($_.Exception.Message -cmatch '^version_input_[a-z0-9_]+$') {
        $_.Exception.Message
    } else { 'version_input_transport_or_io_failure' }
}
finally { $client.Dispose() }
$receipt = [ordered]@{
    contract = 'nll/cold-version-input-acquisition/v1'; acquiredAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    build = $ApprovedClientBuild; requestSha256 = $manifestHash; configSha256 = $ExpectedConfigSha256
    members = $results.ToArray(); failure = $failure; tls = 'system_hostname_and_certificate_validation'
    installationChanged = $false; databaseChanged = $false; nativeReadiness = 'not_evaluated'
}
Write-NewJson (Join-Path $assessment 'acquisition.receipt.json') $receipt
[ordered]@{ assessmentPath = $assessment; receipt = $receipt } | ConvertTo-Json -Depth 8
if ($null -ne $failure) { throw $failure }
