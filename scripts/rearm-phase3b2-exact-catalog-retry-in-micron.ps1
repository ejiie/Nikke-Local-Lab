[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$extensionFirewallGroup = 'NLL Phase3B2 Physical P2 V2 Extension'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-PathDigest {
    param([string]$Path, [long]$ByteLength, [string]$Sha256)
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporaryPath, $Text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Write-AtomicUtf8Bom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporaryPath, $Text, [Text.UTF8Encoding]::new($true))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

Assert-True (([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_catalog_retry_rearm_requires_administrator'
$bootDisk = Get-Partition -DriveLetter C | Get-Disk
$samsungDisk = Get-Partition -DriveLetter E | Get-Disk
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
Assert-True ($bootDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    $bootDisk.IsBoot -and $bootDisk.IsSystem -and
    $samsungDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    -not $samsungDisk.IsBoot -and -not $samsungDisk.IsSystem -and
    (($identity.Name -split '\\')[-1] -ceq 'nlloperator')) `
    'phase3b2_catalog_retry_rearm_boundary_invalid'
$runtimeNames = @(
    'EpinelPS', 'nikke', 'nikke_launcher',
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
)
Assert-True (@(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $runtimeNames -contains $_.ProcessName }).Count -eq 0) `
    'phase3b2_catalog_retry_rearm_runtime_not_cold'

$catalogPointerPath =
    'C:\NLL\Evidence\Phase3B2\Physical\catalog-set-v1\latest.pointer.json'
$catalogDeploymentRoot =
    'C:\NLL\Evidence\Phase3B2\Physical\catalog-set-v1\bf669c3c-fcc8-4d57-9f18-32fee1288862'
$catalogRetryToolReceiptPath = Join-Path $catalogDeploymentRoot `
    'retry-tools.receipt.json'
$preparationReceiptPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-preparation-v2\preparation.receipt.json'
$priorFailurePath =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-client-start-v2\1797ba14-cdd4-45e7-9002-b77ddbee3227\run-failure.receipt.json'
$retryConsumptionPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-client-start-v2\exact-catalog-set-retry.consumed.json'
$activePointerPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-client-start-v2\active-run.pointer.json'
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostsBackupPath =
    'C:\NLL\Backups\Phase3B2\PhysicalP2-v2\hosts.before.bin'
$bootstrapPath =
    'C:\NLL\Runtime\PhysicalBootstrap-v2\artifact\NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe'
$startToolPath =
    'C:\NLL\Tools\start-phase3b2-physical-p2-v2-client-in-micron.ps1'
$catalogSqliteTransportAuthorizationPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\catalog-sqlite-transport-repair.receipt.json'
$catalogProjectionPath =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
$catalogSqliteTransportMode = Test-Path -LiteralPath `
    $catalogSqliteTransportAuthorizationPath -PathType Leaf
$expectedPreparationByteLength = 1693L
$expectedPreparationSha256 =
    'aba8be5a95ee8d326a106397f9286433cdf133b89b5579da74a41238743732ab'
$expectedStartToolByteLength = 99381L
$expectedStartToolSha256 =
    '5417964589cbd0c4cf514e8e6fc887799d5cd056408d54041098a3b0f20bf579'
$catalogSqliteTransport = $null
if ($catalogSqliteTransportMode) {
    $catalogSqliteTransport = Get-Content -LiteralPath `
        $catalogSqliteTransportAuthorizationPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True ($catalogSqliteTransport.contractId -ceq
            'nll/phase3b2-p2-v2-catalog-sqlite-transport-repair/v1' -and
        $catalogSqliteTransport.failedAssessmentUid -ceq
            '083d46b5-696f-407a-9d1c-0f8a5c86a4e1' -and
        $catalogSqliteTransport.singleTransportRetryAuthorized -and
        -not $catalogSqliteTransport.retryConsumed -and
        $catalogSqliteTransport.projectedHeaderApplied -and
        $catalogSqliteTransport.dedicatedCatalogCacheResetCount -eq 6 -and
        $catalogSqliteTransport.appliedRearmToolSha256 -ceq
            (Get-Sha256Hex $MyInvocation.MyCommand.Path)) `
        'phase3b2_catalog_retry_rearm_transport_authorization_invalid'
    $expectedPreparationByteLength =
        [long]$catalogSqliteTransport.appliedPreparationReceiptByteLength
    $expectedPreparationSha256 =
        [string]$catalogSqliteTransport.appliedPreparationReceiptSha256
    $expectedStartToolByteLength =
        [long]$catalogSqliteTransport.appliedStartToolByteLength
    $expectedStartToolSha256 =
        [string]$catalogSqliteTransport.appliedStartToolSha256
}

Assert-True ((Test-PathDigest $catalogPointerPath 707L `
        '5b015177c6b17339cb13989f9056d024831c1b03ff6544c4bcaeb4d676fc47a8') -and
    (Test-PathDigest $catalogRetryToolReceiptPath 1606L `
        '6d181c40d7da412de9f7861f6e12814a304e848adcb4ebe7b1ab2b69ec6dec19') -and
    (Test-PathDigest $preparationReceiptPath $expectedPreparationByteLength `
        $expectedPreparationSha256) -and
    (Test-PathDigest $priorFailurePath 1752L `
        '03a6021e6d84d83ad967b5ce4cb6e74abfc01d28fa902ed45aa4182769fdcc76') -and
    (Test-PathDigest $hostsPath 1690L `
        'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0') -and
    (Test-PathDigest $hostsBackupPath 1690L `
        'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0') -and
    (Test-PathDigest $bootstrapPath 162816L `
        'ff7371b3e20119030c0f3a8e2f6ba9482094c4118f06dbcc4e0e7f137f8e404f') -and
    (Test-PathDigest $startToolPath $expectedStartToolByteLength `
        $expectedStartToolSha256) -and
    (-not $catalogSqliteTransportMode -or
        (Test-PathDigest $catalogProjectionPath 139L `
            '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a')) -and
    -not (Test-Path -LiteralPath $retryConsumptionPath) -and
    -not (Test-Path -LiteralPath $activePointerPath)) `
    'phase3b2_catalog_retry_rearm_evidence_or_state_invalid'
$priorFailure = Get-Content -LiteralPath $priorFailurePath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True ($priorFailure.contractId -ceq
        'nll/phase3b2-physical-p2-v2-client-start-failure/v1' -and
    $priorFailure.failedStageCode -ceq
        'physical_boundary_profile_and_contract_preflight' -and
    $priorFailure.failureCode -ceq
        'phase3b2_physical_p2_v2_runtime_pin_mismatch' -and
    -not $priorFailure.serverExecutionStarted -and
    -not $priorFailure.clientExecutionStarted -and
    $priorFailure.hostsRestored -and
    $priorFailure.extensionFirewallRolledBack) `
    'phase3b2_catalog_retry_rearm_failure_contract_invalid'

$baseRules = @(Get-NetFirewallRule -Group `
    'NLL Phase3B2 Physical Isolation' -ErrorAction SilentlyContinue)
$extensionRules = @(Get-NetFirewallRule -Group $extensionFirewallGroup `
    -ErrorAction SilentlyContinue)
Assert-True ($baseRules.Count -eq 17 -and $extensionRules.Count -eq 0) `
    'phase3b2_catalog_retry_rearm_firewall_precondition_invalid'

$hostsText = [Text.UTF8Encoding]::new($true, $true).GetString(
    [IO.File]::ReadAllBytes($hostsPath)).TrimStart([char]0xFEFF)
Assert-True ($hostsText.IndexOf('global-match.nikke-kr.com',
        [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
    ([regex]::Matches($hostsText,
        '(?m)^# end NLL Phase3B2 Physical entries\r?$')).Count -eq 1) `
    'phase3b2_catalog_retry_rearm_hosts_shape_invalid'
$hostsAppliedText = $hostsText.Replace(
    '# end NLL Phase3B2 Physical entries',
    "127.0.0.1 global-match.nikke-kr.com`r`n# end NLL Phase3B2 Physical entries")
Write-AtomicUtf8Bom $hostsPath $hostsAppliedText
Assert-True (Test-PathDigest $hostsPath 1727L `
    '3b0dcc4396373e9e9d623ef05c345f89330427ad5128727290c9f76138e22f64') `
    'phase3b2_catalog_retry_rearm_hosts_apply_failed'

try {
    New-NetFirewallRule `
        -Name 'NLL.Phase3B2.PhysicalP2V2.BootstrapBlock' `
        -DisplayName 'NLL Phase3B2 P2-v2 Bootstrap Outbound Block' `
        -Group $extensionFirewallGroup -Direction Outbound -Action Block `
        -Enabled True -Profile Any -Program $bootstrapPath | Out-Null
    $extensionRules = @(Get-NetFirewallRule -Group $extensionFirewallGroup)
    $extensionPrograms = @($extensionRules |
        Get-NetFirewallApplicationFilter)
    Assert-True ($extensionRules.Count -eq 1 -and
        $extensionRules[0].Direction -eq 'Outbound' -and
        $extensionRules[0].Action -eq 'Block' -and
        $extensionPrograms.Count -eq 1 -and
        $extensionPrograms[0].Program -ceq $bootstrapPath) `
        'phase3b2_catalog_retry_rearm_firewall_apply_failed'
}
catch {
    [IO.File]::WriteAllBytes($hostsPath,
        [IO.File]::ReadAllBytes($hostsBackupPath))
    Get-NetFirewallRule -Group $extensionFirewallGroup `
        -ErrorAction SilentlyContinue | Remove-NetFirewallRule `
        -ErrorAction SilentlyContinue
    throw
}

$rearmUid = [Guid]::NewGuid().ToString('D')
$rearmRoot = Join-Path $catalogDeploymentRoot 'rearm'
$receiptPath = Join-Path $rearmRoot "$rearmUid.receipt.json"
$pointerPath = Join-Path $rearmRoot 'latest.pointer.json'
New-Item -ItemType Directory -Path $rearmRoot -Force | Out-Null
$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-exact-catalog-retry-rearm/v1'
    rearmedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    rearmUid = $rearmUid
    catalogDeploymentUid = 'bf669c3c-fcc8-4d57-9f18-32fee1288862'
    priorFailureAssessmentUid = [string]$priorFailure.assessmentUid
    priorFailureReceiptSha256 =
        '03a6021e6d84d83ad967b5ce4cb6e74abfc01d28fa902ed45aa4182769fdcc76'
    preparationReceiptSha256 =
        'aba8be5a95ee8d326a106397f9286433cdf133b89b5579da74a41238743732ab'
    baseHostsRestoredBeforeRearm = $true
    hostsReapplied = $true
    extensionFirewallReapplied = $true
    baseFirewallRuleCount = 17
    extensionFirewallRuleCount = 1
    exactCatalogRetryConsumed = $false
    catalogSqliteTransportVerified = $catalogSqliteTransportMode
    dedicatedCatalogCacheResetApplied = $catalogSqliteTransportMode
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = 'continue_wrapper_into_exact_catalog_retry_preflight'
}
Write-AtomicUtf8NoBom $receiptPath `
    (($receipt | ConvertTo-Json -Depth 6) + "`n")
$pointer = [ordered]@{
    contractId = 'nll/phase3b2-exact-catalog-retry-rearm-pointer/v1'
    rearmUid = $rearmUid
    receiptFileName = "$rearmUid.receipt.json"
    receiptByteLength = (Get-Item $receiptPath).Length
    receiptSha256 = Get-Sha256Hex $receiptPath
}
Write-AtomicUtf8NoBom $pointerPath `
    (($pointer | ConvertTo-Json -Depth 4) + "`n")
$receipt | ConvertTo-Json -Depth 6
