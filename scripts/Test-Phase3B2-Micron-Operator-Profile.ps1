[CmdletBinding()]
param(
    [string]$AccountName = 'nlloperator',
    [string]$EvidenceRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\operator-profile-v1',
    [string]$SamsungProtectedRoot =
        'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\Operator'
)

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
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

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_micron_operator_profile_requires_administrator'
$bootDisk = Get-Partition -DriveLetter C | Get-Disk
$samsungDisk = Get-Partition -DriveLetter E | Get-Disk
Assert-True ($bootDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    $bootDisk.IsBoot -and $bootDisk.IsSystem -and
    $samsungDisk.FriendlyName -ceq 'Samsung SSD 980 1TB') `
    'phase3b2_micron_operator_profile_wrong_boot_disk'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentName = ($identity.Name -split '\\')[-1]
$profileRoot = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::UserProfile)
$expectedProfileRoot = Join-Path 'C:\Users' $AccountName
$localLowRoot = Join-Path $profileRoot 'AppData\LocalLow'
Assert-True ($currentName -ceq $AccountName -and
    [IO.Path]::GetFullPath($profileRoot).TrimEnd('\') -ceq
        [IO.Path]::GetFullPath($expectedProfileRoot).TrimEnd('\') -and
    (Test-Path -LiteralPath $localLowRoot -PathType Container)) `
    'phase3b2_micron_operator_profile_identity_invalid'
Assert-True (-not [IO.Path]::GetFullPath($localLowRoot).StartsWith(
        'C:\Users\ccccc\', [StringComparison]::OrdinalIgnoreCase)) `
    'phase3b2_micron_operator_profile_not_isolated'
Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_micron_operator_profile_runtime_not_cold'

$candidateDirectories = @(Get-ChildItem -LiteralPath $localLowRoot -Directory `
    -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '(?i)nikke|shift[ _-]*up|level[ _-]*infinite'
    })
Assert-True ($candidateDirectories.Count -eq 0) `
    'phase3b2_micron_operator_profile_not_clean_before_first_run'

$accountReceiptPath = Join-Path $EvidenceRoot 'account-creation.receipt.json'
$profileReceiptPath = Join-Path $EvidenceRoot 'profile-isolation.receipt.json'
Assert-True ((Test-Path -LiteralPath $accountReceiptPath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $profileReceiptPath)) `
    'phase3b2_micron_operator_profile_evidence_shape_invalid'
$accountReceipt = Get-Content -LiteralPath $accountReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True ($accountReceipt.contractId -ceq
        'nll/phase3b2-micron-operator-account/v1' -and
    $accountReceipt.accountName -ceq $AccountName -and
    -not $accountReceipt.existingOperatorNikkeCacheMutationPerformed) `
    'phase3b2_micron_operator_account_receipt_invalid'

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-micron-operator-profile-isolation/v1'
    verifiedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    accountName = $AccountName
    currentUserVerified = $true
    profileRootCode = 'dedicated_nlloperator_profile'
    localLowRootCode = 'dedicated_nlloperator_locallow'
    localLowCandidateCacheDirectoryCountBeforeFirstRun = 0
    existingOperatorProfileInspected = $false
    existingOperatorLocalLowReadPerformed = $false
    existingOperatorLocalLowWritePerformed = $false
    existingOperatorNikkeCacheMutationPerformed = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = 'prepare_p2_v2_observed_run'
}
Write-AtomicUtf8NoBom $profileReceiptPath `
    (($receipt | ConvertTo-Json -Depth 6) + "`n")
Copy-Item -LiteralPath $profileReceiptPath -Destination $SamsungProtectedRoot
$protectedPath = Join-Path $SamsungProtectedRoot `
    'profile-isolation.receipt.json'
Assert-True ((Get-Sha256Hex $protectedPath) -ceq
    (Get-Sha256Hex $profileReceiptPath)) `
    'phase3b2_micron_operator_profile_protected_copy_failed'
$receipt | ConvertTo-Json -Depth 7

