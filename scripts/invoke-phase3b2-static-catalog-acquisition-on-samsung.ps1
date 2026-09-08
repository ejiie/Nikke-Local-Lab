[CmdletBinding(DefaultParameterSetName = 'Validate')]
param(
    [Parameter(Mandatory)]
    [string]$RequestManifestPath,

    [Parameter(Mandatory, ParameterSetName = 'Execute')]
    [switch]$ExecuteApprovedAcquisition,

    [Parameter(Mandatory, ParameterSetName = 'Execute')]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$ExpectedRequestManifestSha256,

    [long]$MaximumMemberByteLength = 134217728,

    [string]$AcquisitionRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\CatalogAcquisition'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-BytesSha256Hex {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        (($sha.ComputeHash($Bytes) | ForEach-Object {
            $_.ToString('x2')
        }) -join '')
    }
    finally { $sha.Dispose() }
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporaryPath, $Text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Assert-ExactPropertySet {
    param([object]$Value, [string[]]$Expected, [string]$FailureCode)
    $actual = @($Value.PSObject.Properties.Name | Sort-Object -CaseSensitive)
    $wanted = @($Expected | Sort-Object -CaseSensitive)
    Assert-True (($actual -join "`n") -ceq ($wanted -join "`n")) `
        $FailureCode
}

function Assert-NoReparseAncestor {
    param([string]$Path, [string]$FailureCode)
    $cursor = [IO.Path]::GetFullPath($Path)
    while (-not (Test-Path -LiteralPath $cursor)) {
        $parent = Split-Path -Parent $cursor
        Assert-True (-not [string]::IsNullOrWhiteSpace($parent)) $FailureCode
        $cursor = $parent
    }
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        $item = Get-Item -LiteralPath $cursor -Force
        Assert-True (
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
        ) $FailureCode
        $parent = Split-Path -Parent $cursor
        if ($parent -ceq $cursor) { break }
        $cursor = $parent
    }
}

function Test-NkdbBody {
    param([string]$Path)
    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 4) { return $false }
        $magic = [byte[]]::new(4)
        $read = $stream.Read($magic, 0, $magic.Length)
        return $read -eq 4 -and
            $magic[0] -eq 0x4e -and
            $magic[1] -eq 0x4b -and
            $magic[2] -eq 0x44 -and
            $magic[3] -eq 0x42
    }
    finally { $stream.Dispose() }
}

function Get-ApprovedRequestSet {
    param([string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-True ($fullPath -cmatch '^[A-Za-z]:\\' -and
        $fullPath.Substring(2).IndexOf(':') -lt 0) `
        'phase3b2_static_catalog_request_path_invalid'
    Assert-True (Test-Path -LiteralPath $fullPath -PathType Leaf) `
        'phase3b2_static_catalog_request_manifest_missing'
    Assert-NoReparseAncestor $fullPath `
        'phase3b2_static_catalog_request_reparse_boundary_invalid'

    $repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
    Assert-True (-not $fullPath.StartsWith(
        $repositoryRoot.TrimEnd('\') + '\',
        [StringComparison]::OrdinalIgnoreCase)) `
        'phase3b2_static_catalog_request_manifest_must_be_git_external'

    $bytes = [IO.File]::ReadAllBytes($fullPath)
    Assert-True ($bytes.Length -gt 0 -and $bytes.Length -le 32768) `
        'phase3b2_static_catalog_request_manifest_size_invalid'
    Assert-True (-not ($bytes.Length -ge 3 -and
        $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and
        $bytes[2] -eq 0xbf)) `
        'phase3b2_static_catalog_request_manifest_bom_invalid'

    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $manifest = $text | ConvertFrom-Json
    }
    catch {
        throw 'phase3b2_static_catalog_request_manifest_json_invalid'
    }

    Assert-ExactPropertySet $manifest @(
        'schemaVersion', 'contractId', 'requestSetUid', 'clientBuild',
        'members'
    ) 'phase3b2_static_catalog_request_manifest_property_shape_invalid'
    Assert-True ($manifest.schemaVersion -eq 1 -and
        $manifest.contractId -ceq
            'nll/phase3b2-approved-static-catalog-request/v1' -and
        $manifest.clientBuild -ceq '150.6.9') `
        'phase3b2_static_catalog_request_manifest_contract_invalid'

    $uid = [Guid]::Empty
    Assert-True ([Guid]::TryParseExact(
        [string]$manifest.requestSetUid, 'D', [ref]$uid)) `
        'phase3b2_static_catalog_request_uid_invalid'

    $expectedRoles = @(
        'core_body', 'core_signature',
        'dp_body', 'dp_signature',
        'fd_body', 'fd_signature'
    )
    $members = @($manifest.members)
    Assert-True ($members.Count -eq $expectedRoles.Count) `
        'phase3b2_static_catalog_request_member_count_invalid'

    $validated = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $expectedRoles.Count; $index++) {
        $member = $members[$index]
        Assert-ExactPropertySet $member @('roleCode', 'kindCode', 'uri') `
            'phase3b2_static_catalog_request_member_property_shape_invalid'
        $roleCode = [string]$member.roleCode
        $kindCode = [string]$member.kindCode
        Assert-True ($roleCode -ceq $expectedRoles[$index]) `
            'phase3b2_static_catalog_request_role_order_invalid'

        $uri = $null
        Assert-True ([Uri]::TryCreate(
            [string]$member.uri, [UriKind]::Absolute, [ref]$uri)) `
            'phase3b2_static_catalog_request_uri_invalid'
        Assert-True ($uri.Scheme -ceq 'https' -and
            $uri.Authority -ceq 'cloud.nikke-kr.com' -and
            $uri.DnsSafeHost -ceq 'cloud.nikke-kr.com' -and
            $uri.IsDefaultPort -and
            [string]::IsNullOrEmpty($uri.UserInfo) -and
            [string]::IsNullOrEmpty($uri.Query) -and
            [string]::IsNullOrEmpty($uri.Fragment) -and
            [Uri]::UnescapeDataString($uri.AbsolutePath) -ceq
                $uri.AbsolutePath -and
            $uri.OriginalString -ceq
                ('https://cloud.nikke-kr.com' + $uri.AbsolutePath)) `
            'phase3b2_static_catalog_request_transport_boundary_invalid'

        Assert-True ($uri.AbsolutePath -cmatch
            '^/prdenv/[a-z0-9-]{1,64}/StandaloneWindows64/pck/(core|dp|fd)/[A-Za-z0-9.]{1,64}/catalog\.db(?:\.nds)?$') `
            'phase3b2_static_catalog_request_path_shape_invalid'
        $pathRole = $Matches[1]
        $expectedPathRole = $roleCode.Split('_')[0]
        $isSignature = $roleCode.EndsWith(
            '_signature', [StringComparison]::Ordinal)
        Assert-True ($pathRole -ceq $expectedPathRole -and
            (($isSignature -and
                    $uri.AbsolutePath.EndsWith(
                        '/catalog.db.nds', [StringComparison]::Ordinal) -and
                    $kindCode -ceq 'detached_signature_96') -or
                (-not $isSignature -and
                    $uri.AbsolutePath.EndsWith(
                        '/catalog.db', [StringComparison]::Ordinal) -and
                    $kindCode -ceq 'nkdb_body'))) `
            'phase3b2_static_catalog_request_role_path_mismatch'

        $validated.Add([pscustomobject]@{
            RoleCode = $roleCode
            KindCode = $kindCode
            Uri = $uri
            RelativePath = $uri.AbsolutePath.TrimStart('/').Replace('/', '\')
        })
    }

    foreach ($role in @('core', 'dp', 'fd')) {
        $body = @($validated | Where-Object RoleCode -CEQ ($role + '_body'))[0]
        $signature = @($validated |
            Where-Object RoleCode -CEQ ($role + '_signature'))[0]
        Assert-True (
            ($signature.Uri.AbsolutePath.Substring(
                0, $signature.Uri.AbsolutePath.Length - 4)) -ceq
            $body.Uri.AbsolutePath
        ) 'phase3b2_static_catalog_request_pair_mismatch'
    }

    [pscustomobject]@{
        FullPath = $fullPath
        Bytes = $bytes
        ByteLength = $bytes.Length
        Sha256 = Get-BytesSha256Hex $bytes
        RequestSetUid = $uid.ToString('D')
        Members = $validated.ToArray()
    }
}

function Save-ApprovedMember {
    param(
        [Net.Http.HttpClient]$Client,
        [object]$Member,
        [string]$ContentRoot,
        [long]$MaximumLength
    )

    $destinationPath = Join-Path $ContentRoot $Member.RelativePath
    $destinationDirectory = Split-Path -Parent $destinationPath
    New-Item -ItemType Directory -Path $destinationDirectory -Force |
        Out-Null
    Assert-True (-not (Test-Path -LiteralPath $destinationPath)) `
        'phase3b2_static_catalog_destination_member_already_present'
    $partialPath = $destinationPath + '.partial'
    Assert-True (-not (Test-Path -LiteralPath $partialPath)) `
        'phase3b2_static_catalog_partial_member_already_present'

    $request = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::Get, $Member.Uri)
    $response = $null
    try {
        $response = $Client.SendAsync(
            $request,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        Assert-True ([int]$response.StatusCode -eq 200) `
            'phase3b2_static_catalog_response_status_invalid'
        Assert-True ($null -eq $response.Headers.Location -and
            -not $response.Headers.Contains('Set-Cookie')) `
            'phase3b2_static_catalog_response_boundary_invalid'

        $declaredLength = $response.Content.Headers.ContentLength
        if ($null -ne $declaredLength) {
            Assert-True ($declaredLength -gt 0 -and
                $declaredLength -le $MaximumLength) `
                'phase3b2_static_catalog_response_length_invalid'
        }

        $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $destination = [IO.File]::Open(
            $partialPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None)
        try {
            $buffer = [byte[]]::new(1048576)
            [long]$total = 0
            while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $total += $read
                Assert-True ($total -le $MaximumLength) `
                    'phase3b2_static_catalog_response_length_limit_exceeded'
                $destination.Write($buffer, 0, $read)
            }
            $destination.Flush($true)
        }
        finally {
            $destination.Dispose()
            $source.Dispose()
        }
        Assert-True ($total -gt 0 -and
            ($null -eq $declaredLength -or $total -eq $declaredLength)) `
            'phase3b2_static_catalog_response_body_incomplete'
        Move-Item -LiteralPath $partialPath -Destination $destinationPath
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
    }

    $item = Get-Item -LiteralPath $destinationPath
    Assert-True (
        ($Member.KindCode -ceq 'nkdb_body' -and
            (Test-NkdbBody $destinationPath)) -or
        ($Member.KindCode -ceq 'detached_signature_96' -and
            $item.Length -eq 96L)
    ) 'phase3b2_static_catalog_member_shape_invalid'

    [pscustomobject]@{
        roleCode = $Member.RoleCode
        kindCode = $Member.KindCode
        relativePath = $Member.RelativePath.Replace('\', '/')
        byteLength = $item.Length
        sha256 = Get-Sha256Hex $destinationPath
        httpStatusCode = 200
    }
}

$requestSet = Get-ApprovedRequestSet $RequestManifestPath
$validation = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-static-catalog-request-validation/v1'
    requestSetUid = $requestSet.RequestSetUid
    requestManifestByteLength = $requestSet.ByteLength
    requestManifestSha256 = $requestSet.Sha256
    approvedHostCode = 'official_static_asset_cdn_single_host'
    approvedMemberCount = $requestSet.Members.Count
    redirectAllowed = $false
    proxyAllowed = $false
    cookieAllowed = $false
    credentialAllowed = $false
    serverExecutionAllowed = $false
    clientExecutionAllowed = $false
    micronMutationAllowed = $false
    readyForExplicitAcquisition = $true
}

if (-not $ExecuteApprovedAcquisition) {
    [pscustomobject]$validation | ConvertTo-Json
    return
}

Assert-True ($requestSet.Sha256 -ceq $ExpectedRequestManifestSha256) `
    'phase3b2_static_catalog_request_manifest_hash_mismatch'
Assert-True ($MaximumMemberByteLength -ge 96 -and
    $MaximumMemberByteLength -le 536870912) `
    'phase3b2_static_catalog_member_length_limit_invalid'

$isAdministrator = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
Assert-True $isAdministrator `
    'phase3b2_static_catalog_acquisition_requires_administrator'

$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter E | Get-Disk
Assert-True ($systemDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $systemDisk.IsBoot -and $systemDisk.IsSystem -and
    $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
    'phase3b2_static_catalog_acquisition_disk_boundary_invalid'

$runtimeProcessCount = @(
    Get-Process -Name EpinelPS, nikke, nikke_launcher,
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
        -ErrorAction SilentlyContinue
).Count
Assert-True ($runtimeProcessCount -eq 0) `
    'phase3b2_static_catalog_acquisition_runtime_not_cold'

$fullAcquisitionRoot = [IO.Path]::GetFullPath($AcquisitionRoot)
$requiredAcquisitionRoot = [IO.Path]::GetFullPath(
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\CatalogAcquisition')
Assert-True ($fullAcquisitionRoot -ceq $requiredAcquisitionRoot) `
    'phase3b2_static_catalog_acquisition_root_invalid'
Assert-NoReparseAncestor $fullAcquisitionRoot `
    'phase3b2_static_catalog_acquisition_root_reparse_invalid'

$assessmentUid = [Guid]::NewGuid().ToString('D')
$pendingParent = Join-Path $fullAcquisitionRoot 'Pending'
$sealedParent = Join-Path $fullAcquisitionRoot 'Sealed'
$pendingRoot = Join-Path $pendingParent $assessmentUid
$sealedRoot = Join-Path $sealedParent $assessmentUid
Assert-True (-not (Test-Path -LiteralPath $pendingRoot) -and
    -not (Test-Path -LiteralPath $sealedRoot)) `
    'phase3b2_static_catalog_assessment_already_present'
New-Item -ItemType Directory -Path (Join-Path $pendingRoot 'content') `
    -Force | Out-Null

$stageCode = 'transport_initialization'
$handler = $null
$client = $null
try {
    Add-Type -AssemblyName System.Net.Http
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.UseDefaultCredentials = $false
    $handler.PreAuthenticate = $false
    $handler.UseProxy = $false
    $handler.AutomaticDecompression =
        [Net.DecompressionMethods]::None
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(120)

    $stageCode = 'six_member_https_get'
    $observedMembers = [Collections.Generic.List[object]]::new()
    foreach ($member in $requestSet.Members) {
        $observedMembers.Add((Save-ApprovedMember `
            -Client $client `
            -Member $member `
            -ContentRoot (Join-Path $pendingRoot 'content') `
            -MaximumLength $MaximumMemberByteLength))
    }

    $stageCode = 'pair_and_manifest_verification'
    Assert-True ($observedMembers.Count -eq 6 -and
        @($observedMembers | Where-Object kindCode -CEQ 'nkdb_body').Count -eq 3 -and
        @($observedMembers |
            Where-Object kindCode -CEQ 'detached_signature_96').Count -eq 3) `
        'phase3b2_static_catalog_observed_member_shape_invalid'

    $privateTransport = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-static-catalog-private-transport/v1'
        assessmentUid = $assessmentUid
        requestSetUid = $requestSet.RequestSetUid
        requestManifestSha256 = $requestSet.Sha256
        members = @($observedMembers | ForEach-Object {
            $observation = $_
            $requestMember = @($requestSet.Members | Where-Object {
                $_.RoleCode -ceq $observation.roleCode
            })[0]
            [ordered]@{
                roleCode = $observation.roleCode
                kindCode = $observation.kindCode
                uri = $requestMember.Uri.OriginalString
                relativePath = $observation.relativePath
                byteLength = $observation.byteLength
                sha256 = $observation.sha256
                httpStatusCode = $observation.httpStatusCode
            }
        })
    }
    $privateTransportPath = Join-Path $pendingRoot `
        'transport.private.json'
    Write-AtomicUtf8NoBom $privateTransportPath `
        (($privateTransport | ConvertTo-Json -Depth 7) + "`n")

    $canonicalText = (@($observedMembers | ForEach-Object {
        "{0}`t{1}`t{2}`t{3}" -f $_.roleCode, $_.kindCode,
            $_.byteLength, $_.sha256
    }) -join "`n") + "`n"
    $canonicalBytes = [Text.UTF8Encoding]::new($false).GetBytes(
        $canonicalText)
    $canonicalPath = Join-Path $pendingRoot 'source-free.manifest.tsv'
    [IO.File]::WriteAllBytes($canonicalPath, $canonicalBytes)

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-static-catalog-acquisition/v1'
        acquiredAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = $assessmentUid
        requestSetUid = $requestSet.RequestSetUid
        environmentCode = 'samsung_boot_micron_offline_runtime_cold'
        clientBuild = '150.6.9'
        requestedMemberCount = 6
        acquiredMemberCount = $observedMembers.Count
        nkdbBodyCount = @($observedMembers |
            Where-Object kindCode -CEQ 'nkdb_body').Count
        detachedSignatureCount = @($observedMembers |
            Where-Object kindCode -CEQ 'detached_signature_96').Count
        detachedSignatureByteLength = 96
        requestManifestByteLength = $requestSet.ByteLength
        requestManifestSha256 = $requestSet.Sha256
        privateTransportManifestByteLength =
            (Get-Item -LiteralPath $privateTransportPath).Length
        privateTransportManifestSha256 =
            Get-Sha256Hex $privateTransportPath
        canonicalization =
            'role_code_tab_kind_code_tab_byte_length_tab_lower_sha256_lf_v1'
        canonicalByteLength = $canonicalBytes.Length
        canonicalSha256 = Get-BytesSha256Hex $canonicalBytes
        totalContentByteLength = [long](
            ($observedMembers | Measure-Object -Property byteLength -Sum).Sum)
        tlsCertificateValidationCode =
            'system_default_hostname_validation'
        redirectFollowCount = 0
        proxyUsed = $false
        cookieSent = $false
        credentialSent = $false
        authorizationHeaderSent = $false
        officialStaticAssetCdnUsed = $true
        officialApiUsed = $false
        officialLoginUsed = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        signatureCryptographicVerificationPerformed = $false
        signatureShapeVerified = $true
        nkdbMagicVerified = $true
        gitExternalPlacementVerified = $true
        micronMutationPerformed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        verdictCode = 'exact_six_member_catalog_set_acquired_and_sealed'
        rollbackCode =
            'move_sealed_assessment_to_git_external_quarantine'
        nextStepCode =
            'offline_parse_sealed_catalog_set_then_stage_micron'
    }
    $receiptPath = Join-Path $pendingRoot 'acquisition.receipt.json'
    Write-AtomicUtf8NoBom $receiptPath `
        (($receipt | ConvertTo-Json -Depth 7) + "`n")

    $stageCode = 'sealed_placement'
    New-Item -ItemType Directory -Path $sealedParent -Force | Out-Null
    Move-Item -LiteralPath $pendingRoot -Destination $sealedRoot
    $sealedReceiptPath = Join-Path $sealedRoot 'acquisition.receipt.json'
    Assert-True ((Get-Sha256Hex (Join-Path $sealedRoot `
            'source-free.manifest.tsv')) -ceq $receipt.canonicalSha256) `
        'phase3b2_static_catalog_sealed_manifest_invalid'

    [pscustomobject]@{
        Receipt = $receipt
        ReceiptByteLength =
            (Get-Item -LiteralPath $sealedReceiptPath).Length
        ReceiptSha256 = Get-Sha256Hex $sealedReceiptPath
    } | ConvertTo-Json -Depth 8
}
catch {
    $failure = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-static-catalog-acquisition-failure/v1'
        failedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = $assessmentUid
        requestSetUid = $requestSet.RequestSetUid
        failedStageCode = $stageCode
        pendingEvidencePreserved = (Test-Path -LiteralPath $pendingRoot)
        rawErrorPersisted = $false
        micronMutationPerformed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'inspect_source_free_failure_then_decide_retry'
    }
    if (Test-Path -LiteralPath $pendingRoot -PathType Container) {
        $failurePath = Join-Path $pendingRoot 'failure.receipt.json'
        if (-not (Test-Path -LiteralPath $failurePath)) {
            Write-AtomicUtf8NoBom $failurePath `
                (($failure | ConvertTo-Json) + "`n")
        }
    }
    throw "phase3b2_static_catalog_acquisition_failed:$stageCode"
}
finally {
    if ($null -ne $client) { $client.Dispose() }
    elseif ($null -ne $handler) { $handler.Dispose() }
}
