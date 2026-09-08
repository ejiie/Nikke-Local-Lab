[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedConfigSha256,
    [Parameter(Mandatory)][string]$MetadataPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedMetadataSha256,
    [Parameter(Mandatory)][string]$CertificatePath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedCertificateSha256,
    [ValidateRange(15,300)][int]$DurationSeconds = 120,
    [switch]$StagePrivateInputs
)

# Offline, create-only probe preparation. No game/server launch, downloads,
# preference/hosts/CA/DB updates or mutation of an existing client/runtime.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Require([bool]$Condition, [string]$Code) {
    if (-not $Condition) { throw ('resource_probe_' + $Code) }
}
function Assert-NoReparse([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            Require (((Get-Item -LiteralPath $cursor -Force).Attributes -band
                [IO.FileAttributes]::ReparsePoint) -eq 0) 'reparse_path'
        }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}
function Hash-Bytes([byte[]]$Bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}
function Read-Pinned([string]$Path, [string]$Digest) {
    Assert-NoReparse $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        Require ($stream.Length -gt 0 -and $stream.Length -le 65536) 'input_size_invalid'
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            Require ($read -gt 0) 'input_truncated'
            $offset += $read
        }
        Require ((Hash-Bytes $bytes) -ceq $Digest) 'input_hash_drift'
        return ,$bytes
    }
    finally { $stream.Dispose() }
}
function Write-NewBytes([string]$Path, [byte[]]$Bytes) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
}
function Json-Bytes([object]$Value) {
    return ,[Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 8))
}

$configBytes = Read-Pinned $ConfigPath $ExpectedConfigSha256
$config = [Text.Encoding]::UTF8.GetString($configBytes) | ConvertFrom-Json
Require ($config.TargetVersion -ceq '151.8.5') 'config_build_invalid'
$base = [string]$config.ResourceBaseURL
Require ($base.EndsWith('/{Platform}') -and $base.Split('{').Count -eq 2) 'resource_base_invalid'
Require ([string]$config.ResourceDataPackVersion -cmatch '^[0-9]{1,8}$') 'version_selector_invalid'
$url = $base.Replace('{Platform}', 'StandaloneWindows64') + '/pck/latest-' +
    [string]$config.ResourceDataPackVersion + '.txt'
$uri = $null
Require ([Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) 'metadata_uri_invalid'
Require ($uri.Scheme -ceq 'https' -and $uri.Authority -ceq 'cloud.nikke-kr.com' -and
    $uri.IsDefaultPort -and -not $uri.Query -and -not $uri.Fragment -and -not $uri.UserInfo -and
    $url -ceq $uri.AbsoluteUri -and $uri.AbsolutePath -cmatch '^/prdenv/[A-Za-z0-9_./-]+/pck/latest-[0-9]+\.txt$' -and
    -not $url.Contains('/../') -and -not $url.Contains('/./')) 'metadata_uri_boundary'
$metadata = Read-Pinned $MetadataPath $ExpectedMetadataSha256
$certificate = Read-Pinned $CertificatePath $ExpectedCertificateSha256
try {
    # Inspection only: do not import the certificate into any trust store.
    $parsed = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificate, '',
        [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    try {
        Require ($parsed.HasPrivateKey -and [DateTime]::UtcNow -ge $parsed.NotBefore.ToUniversalTime() -and
            [DateTime]::UtcNow -lt $parsed.NotAfter.ToUniversalTime()) 'certificate_invalid'
    }
    finally { $parsed.Dispose() }
    # Exact SAN/metadata-envelope validation is also mandatory in inspect-route-probe.
    if (-not $StagePrivateInputs) {
        [ordered]@{ contractId = 'nll/resource-route-probe-preparation/v1'
            status = 'offline_plan_validated_no_files_created'; metadataSha256 = $ExpectedMetadataSha256
            certificateSha256 = $ExpectedCertificateSha256; serverStarted = $false; clientStarted = $false
            nativeAdmission = 'not_evaluated' } | ConvertTo-Json
        return
    }
    $parent = 'C:\NLL\Staging\ResourceProbeRuns'
    Assert-NoReparse $parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    $assessmentUid = [Guid]::NewGuid().ToString('D')
    $directory = Join-Path $parent $assessmentUid
    Require (-not (Test-Path -LiteralPath $directory)) 'assessment_exists'
    New-Item -ItemType Directory -Path $directory | Out-Null
    # Restrict the new private evidence directory before copying a local test key.
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($sid)
    foreach ($principal in @($sid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($principal, 'FullControl',
            'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $directory -AclObject $acl
    Require ((Get-Acl -LiteralPath $directory).AreAccessRulesProtected) 'private_acl_invalid'
    $stagedMetadata = Join-Path $directory 'version-metadata.txt'
    $stagedCertificate = Join-Path $directory 'server.pfx'
    Write-NewBytes $stagedMetadata $metadata
    Write-NewBytes $stagedCertificate $certificate
    $plan = [ordered]@{ contractId = 'nll/resource-route-probe-plan/v1'; assessmentUid = $assessmentUid
        expectedHost = $uri.DnsSafeHost; metadataRequestPath = $uri.AbsolutePath
        metadataFile = $stagedMetadata; metadataByteLength = $metadata.Length; metadataSha256 = $ExpectedMetadataSha256
        certificateFile = $stagedCertificate; certificateByteLength = $certificate.Length; certificateSha256 = $ExpectedCertificateSha256
        durationSeconds = $DurationSeconds; maximumRequests = 64 }
    $planBytes = Json-Bytes $plan
    Write-NewBytes (Join-Path $directory 'probe.private.json') $planBytes
    $receipt = [ordered]@{ contractId = 'nll/resource-route-probe-preparation/v1'; assessmentUid = $assessmentUid
        status = 'private_inputs_staged_not_started'; planSha256 = (Hash-Bytes $planBytes)
        configSha256 = $ExpectedConfigSha256; metadataSha256 = $ExpectedMetadataSha256
        certificateSha256 = $ExpectedCertificateSha256; serverStarted = $false; clientStarted = $false
        nativeAdmission = 'not_evaluated'; systemTrustChanged = $false; privateAclApplied = $true }
    Write-NewBytes (Join-Path $directory 'preparation.receipt.json') (Json-Bytes $receipt)
    Write-NewBytes (Join-Path $directory 'cleanup.private.json') (Json-Bytes ([ordered]@{
        contractId = 'nll/resource-route-probe-cleanup/v1'; assessmentUid = $assessmentUid
        ownedDirectory = $directory; existingFilesModified = @(); hostsChanged = $false; caChanged = $false
        clientChanged = $false; dbChanged = $false; cleanupRequiresStoppedProbeAndExactAssessment = $true
    }))
    $receipt | ConvertTo-Json
}
finally { [Array]::Clear($certificate, 0, $certificate.Length) }
