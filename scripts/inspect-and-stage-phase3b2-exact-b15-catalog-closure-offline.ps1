[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$MicronDrive = 'E:',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\CatalogClosure'
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

function Get-StringSha256Hex {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) |
            ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Test-NkdbBody {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        if ($stream.Length -lt 4) { return $false }
        $bytes = [byte[]]::new(4)
        $read = $stream.Read($bytes, 0, $bytes.Length)
        $read -eq 4 -and
            $bytes[0] -eq 0x4e -and
            $bytes[1] -eq 0x4b -and
            $bytes[2] -eq 0x44 -and
            $bytes[3] -eq 0x42
    }
    finally { $stream.Dispose() }
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

$isAdministrator = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
Assert-True $isAdministrator `
    'phase3b2_exact_catalog_closure_requires_administrator'

$micronLetter = $MicronDrive.TrimEnd(':')
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $micronLetter | Get-Disk
Assert-True ($systemDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $systemDisk.IsBoot -and $systemDisk.IsSystem -and
    $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
    'phase3b2_exact_catalog_closure_disk_boundary_invalid'
$runtimeProcesses = @(
    Get-Process -Name EpinelPS, nikke, nikke_launcher,
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
        -ErrorAction SilentlyContinue |
        ForEach-Object {
            $executablePath = ''
            try { $executablePath = [string]$_.Path } catch {}

            [pscustomobject]@{
                processId = $_.Id
                processName = $_.ProcessName
                executablePath = $executablePath
                responding = $_.Responding
            }
        }
)
if ($runtimeProcesses.Count -ne 0) {
    [pscustomobject]@{
        runtimeCold = $false
        blockingProcessCount = $runtimeProcesses.Count
        blockingProcesses = $runtimeProcesses
    } | ConvertTo-Json -Depth 5
    throw 'phase3b2_exact_catalog_closure_runtime_not_cold'
}

$clientRoot = Join-Path $MicronDrive `
    'NLL\Clients\NIKKE-150.6.9-Physical'
$trustedSignatureSample = Join-Path $clientRoot `
    'NIKKE\game\nikke_Data\StreamingAssets\aa\catalog.db.nds'
Assert-True ((Test-Path -LiteralPath $trustedSignatureSample -PathType Leaf) -and
    (Get-Item -LiteralPath $trustedSignatureSample).Length -eq 96L -and
    (Get-Sha256Hex $trustedSignatureSample) -ceq
        '81285efa5ba789eec9a9377a94405f44c0d21089af13f42e08ee612a9cc7137e') `
    'phase3b2_exact_catalog_closure_trusted_signature_invalid'

$roleContracts = @(
    [pscustomobject]@{
        RoleCode = 'core'
        VersionTag = '150.6.b15'
        ExpectedRelativeDirectory =
            'prdenv\150-b059c3f36c\StandaloneWindows64\pck\core\150.6.b15'
    },
    [pscustomobject]@{
        RoleCode = 'dp'
        VersionTag = '1d5645e'
        ExpectedRelativeDirectory =
            'prdenv\150-b059c3f36c\StandaloneWindows64\pck\dp\1d5645e'
    },
    [pscustomobject]@{
        RoleCode = 'fd'
        VersionTag = '85b12fc'
        ExpectedRelativeDirectory =
            'prdenv\150-b059c3f36c\StandaloneWindows64\pck\fd\85b12fc'
    }
)

$candidateRoots = @(
    (Join-Path $MicronDrive 'NLL'),
    (Join-Path $MicronDrive 'NIKKE'),
    (Join-Path $MicronDrive 'Users\ccccc\AppData\LocalLow'),
    (Join-Path $MicronDrive 'Users\nlloperator\AppData\LocalLow'),
    (Join-Path $env:SystemDrive 'Users\zih44\AppData\LocalLow'),
    (Join-Path $env:SystemDrive `
        'Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS')
) | Select-Object -Unique

$searchRootReceipts = [Collections.Generic.List[object]]::new()
$pairCandidates = [Collections.Generic.List[object]]::new()
$unassignedSignedNkdbPairCount = 0
foreach ($root in $candidateRoots) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        $searchRootReceipts.Add([pscustomobject]@{
            rootRoleSha256 = Get-StringSha256Hex `
                ([IO.Path]::GetFullPath($root).ToLowerInvariant())
            rootPresent = $false
            signatureCandidateCount = 0
            validSignedNkdbPairCount = 0
            accessFailureCode = ''
        })
        continue
    }

    $signatureCandidates = @()
    $accessFailureCode = ''
    try {
        $signatureCandidates = @(Get-ChildItem -LiteralPath $root -Recurse `
            -File -Filter '*.nds' -Force -ErrorAction Stop | Where-Object {
                $_.Name -ieq 'catalog.db.nds' -or
                $_.Name -like '*.cat.nds'
            })
    }
    catch [UnauthorizedAccessException] {
        $accessFailureCode = 'access_denied'
    }
    catch [IO.IOException] {
        $accessFailureCode = 'io_error'
    }

    $validPairCount = 0
    foreach ($signature in $signatureCandidates) {
        if ($signature.Length -ne 96L) { continue }
        $bodyPath = $signature.FullName.Substring(
            0, $signature.FullName.Length - '.nds'.Length)
        if (-not (Test-NkdbBody $bodyPath)) { continue }
        $validPairCount++

        $normalizedPath = $signature.FullName.Replace('/', '\')
        $assignedRole = @($roleContracts | Where-Object {
            $normalizedPath.IndexOf(
                ('\' + $_.RoleCode + '\'),
                [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            $normalizedPath.IndexOf(
                ('\' + $_.VersionTag + '\'),
                [StringComparison]::OrdinalIgnoreCase) -ge 0
        })
        if ($assignedRole.Count -ne 1) {
            $unassignedSignedNkdbPairCount++
            continue
        }

        $body = Get-Item -LiteralPath $bodyPath
        $pairCandidates.Add([pscustomobject]@{
            RoleCode = $assignedRole[0].RoleCode
            VersionTag = $assignedRole[0].VersionTag
            BodyPath = $body.FullName
            BodyByteLength = $body.Length
            BodySha256 = Get-Sha256Hex $body.FullName
            SignaturePath = $signature.FullName
            SignatureByteLength = $signature.Length
            SignatureSha256 = Get-Sha256Hex $signature.FullName
            SourcePathSha256 = Get-StringSha256Hex `
                ($body.FullName.ToLowerInvariant())
        })
    }

    $searchRootReceipts.Add([pscustomobject]@{
        rootRoleSha256 = Get-StringSha256Hex `
            ([IO.Path]::GetFullPath($root).ToLowerInvariant())
        rootPresent = $true
        signatureCandidateCount = $signatureCandidates.Count
        validSignedNkdbPairCount = $validPairCount
        accessFailureCode = $accessFailureCode
    })
}

$roleResults = @($roleContracts | ForEach-Object {
    $role = $_
    $matches = @($pairCandidates | Where-Object RoleCode -CEQ $role.RoleCode)
    $uniquePairs = @($matches | Group-Object {
        $_.BodySha256 + ':' + $_.SignatureSha256
    })
    [pscustomobject]@{
        RoleCode = $role.RoleCode
        VersionTag = $role.VersionTag
        SourceCandidateCount = $matches.Count
        UniquePairCount = $uniquePairs.Count
        StatusCode = if ($uniquePairs.Count -eq 1) {
            'exact_local_pair_verified'
        }
        elseif ($uniquePairs.Count -eq 0) {
            'exact_local_pair_missing'
        }
        else { 'exact_local_pairs_diverged' }
        Selected = if ($uniquePairs.Count -eq 1) {
            $uniquePairs[0].Group | Sort-Object BodyPath | Select-Object -First 1
        }
        else { $null }
        ExpectedRelativeDirectory = $role.ExpectedRelativeDirectory
    }
})

$closureReady = @($roleResults | Where-Object {
    $_.StatusCode -cne 'exact_local_pair_verified'
}).Count -eq 0
$accessFailureCount = @($searchRootReceipts | Where-Object {
    $_.accessFailureCode
}).Count
$assessmentUid = [Guid]::NewGuid().ToString()
$stagingRoot = Join-Path $MicronDrive `
    'NLL\Staging\Phase3B2\ExactCatalogClosure-b15-v1'
$stagedMembers = @()
$manifestPath = $null
if ($closureReady) {
    Assert-True (-not (Test-Path -LiteralPath $stagingRoot)) `
        'phase3b2_exact_catalog_closure_staging_already_present'
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    foreach ($result in $roleResults) {
        $selected = $result.Selected
        $destinationDirectory = Join-Path $stagingRoot `
            $result.ExpectedRelativeDirectory
        New-Item -ItemType Directory -Path $destinationDirectory -Force |
            Out-Null
        $bodyDestination = Join-Path $destinationDirectory 'catalog.db'
        $signatureDestination = Join-Path $destinationDirectory `
            'catalog.db.nds'
        Copy-Item -LiteralPath $selected.BodyPath `
            -Destination $bodyDestination
        Copy-Item -LiteralPath $selected.SignaturePath `
            -Destination $signatureDestination
        Assert-True ((Get-Sha256Hex $bodyDestination) -ceq
                $selected.BodySha256 -and
            (Get-Sha256Hex $signatureDestination) -ceq
                $selected.SignatureSha256) `
            'phase3b2_exact_catalog_closure_staging_copy_invalid'
        $stagedMembers += [ordered]@{
            roleCode = $result.RoleCode
            versionTag = $result.VersionTag
            bodyByteLength = (Get-Item $bodyDestination).Length
            bodySha256 = Get-Sha256Hex $bodyDestination
            signatureByteLength = (Get-Item $signatureDestination).Length
            signatureSha256 = Get-Sha256Hex $signatureDestination
            sourcePathSha256 = $selected.SourcePathSha256
        }
    }
    $manifest = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-exact-b15-catalog-staging-manifest/v1'
        assessmentUid = $assessmentUid
        clientBuild = '150.6.9'
        resourceRootTag = '150-b059c3f36c'
        memberCount = $stagedMembers.Count
        members = $stagedMembers
        officialOutboundUsed = $false
        sourceMutationPerformed = $false
        runtimeCacheModified = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
    }
    $manifestPath = Join-Path $stagingRoot 'trusted.manifest.json'
    Write-AtomicUtf8NoBom $manifestPath `
        (($manifest | ConvertTo-Json -Depth 8) + "`n")
}

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-exact-b15-catalog-closure/v1'
    inspectedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    assessmentUid = $assessmentUid
    environmentCode = 'samsung_boot_micron_offline'
    clientBuild = '150.6.9'
    resourceRootTag = '150-b059c3f36c'
    requiredRoleCount = $roleContracts.Count
    exactRoleReadyCount = @($roleResults | Where-Object {
        $_.StatusCode -ceq 'exact_local_pair_verified'
    }).Count
    closureReady = $closureReady
    verdictCode = if ($closureReady) {
        'exact_local_catalog_set_staged'
    }
    elseif ($accessFailureCount -gt 0) {
        'blocked_source_roots_inaccessible'
    }
    elseif (@($roleResults | Where-Object {
            $_.StatusCode -ceq 'exact_local_pairs_diverged'
        }).Count -gt 0) {
        'blocked_exact_local_catalog_pairs_diverged'
    }
    else { 'blocked_exact_local_catalog_source_missing' }
    roleResults = @($roleResults | ForEach-Object {
        [ordered]@{
            roleCode = $_.RoleCode
            versionTag = $_.VersionTag
            sourceCandidateCount = $_.SourceCandidateCount
            uniquePairCount = $_.UniquePairCount
            statusCode = $_.StatusCode
            bodyByteLength = if ($null -ne $_.Selected) {
                $_.Selected.BodyByteLength
            }
            else { 0 }
            bodySha256 = if ($null -ne $_.Selected) {
                $_.Selected.BodySha256
            }
            else { '' }
            signatureByteLength = if ($null -ne $_.Selected) {
                $_.Selected.SignatureByteLength
            }
            else { 0 }
            signatureSha256 = if ($null -ne $_.Selected) {
                $_.Selected.SignatureSha256
            }
            else { '' }
        }
    })
    searchRootCount = $searchRootReceipts.Count
    searchRoots = $searchRootReceipts
    accessFailureCount = $accessFailureCount
    unassignedSignedNkdbPairCount = $unassignedSignedNkdbPairCount
    stagingManifestByteLength = if ($null -ne $manifestPath) {
        (Get-Item $manifestPath).Length
    }
    else { 0 }
    stagingManifestSha256 = if ($null -ne $manifestPath) {
        Get-Sha256Hex $manifestPath
    }
    else { '' }
    rawContentEmitted = $false
    rawSourcePathEmitted = $false
    sourceMutationPerformed = $false
    runtimeCacheModified = $false
    officialOutboundUsed = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = if ($closureReady) {
        'verify_staged_catalog_set_then_materialize_runtime_cache'
    }
    else { 'provide_exact_local_core_dp_fd_catalog_pairs' }
}

$micronEvidenceRoot = Join-Path $MicronDrive (
    'NLL\Evidence\Phase3B2\Physical\catalog-closure-b15\' +
        $assessmentUid)
$protectedEvidenceRoot = Join-Path $SamsungProtectedRoot $assessmentUid
foreach ($root in @($micronEvidenceRoot, $protectedEvidenceRoot)) {
    Assert-True (-not (Test-Path -LiteralPath $root)) `
        'phase3b2_exact_catalog_closure_evidence_already_present'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $path = Join-Path $root 'inspection.receipt.json'
    Write-AtomicUtf8NoBom $path (($receipt | ConvertTo-Json -Depth 9) + "`n")
}

$micronReceiptPath = Join-Path $micronEvidenceRoot 'inspection.receipt.json'
$protectedReceiptPath = Join-Path $protectedEvidenceRoot `
    'inspection.receipt.json'
Assert-True ((Get-Sha256Hex $micronReceiptPath) -ceq
        (Get-Sha256Hex $protectedReceiptPath)) `
    'phase3b2_exact_catalog_closure_protected_copy_invalid'

[pscustomobject]@{
    Receipt = $receipt
    MicronReceiptPath = $micronReceiptPath
    ProtectedReceiptPath = $protectedReceiptPath
    ReceiptByteLength = (Get-Item $micronReceiptPath).Length
    ReceiptSha256 = Get-Sha256Hex $micronReceiptPath
} | ConvertTo-Json -Depth 10

if (-not $closureReady) {
    throw ('phase3b2_exact_catalog_closure_blocked:' +
        $receipt.verdictCode)
}
