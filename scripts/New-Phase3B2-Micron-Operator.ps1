[CmdletBinding()]
param(
    [string]$AccountName = 'nlloperator',
    [string]$EvidenceRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\operator-profile-v1',
    [string]$SamsungProtectedRoot =
        'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\Operator'
)

$ErrorActionPreference = 'Stop'
$created = $false
$evidenceCreated = $false
$protectedCreated = $false

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

try {
    Assert-True ([Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) `
        'phase3b2_micron_operator_creation_requires_administrator'
    $bootDisk = Get-Partition -DriveLetter C | Get-Disk
    $samsungDisk = Get-Partition -DriveLetter E | Get-Disk
    Assert-True ($bootDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
        $bootDisk.IsBoot -and $bootDisk.IsSystem -and
        $samsungDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
        -not $samsungDisk.IsBoot -and -not $samsungDisk.IsSystem) `
        'phase3b2_micron_operator_creation_wrong_boot_disk'
    Assert-True (([Security.Principal.WindowsIdentity]::GetCurrent().Name `
            -split '\\')[-1] -cne $AccountName) `
        'phase3b2_micron_operator_creation_must_run_from_existing_operator'
    Assert-True ($null -eq (Get-LocalUser -Name $AccountName `
            -ErrorAction SilentlyContinue)) `
        'phase3b2_micron_operator_account_already_exists'
    Assert-True (-not (Test-Path -LiteralPath $EvidenceRoot) -and
        -not (Test-Path -LiteralPath $SamsungProtectedRoot)) `
        'phase3b2_micron_operator_evidence_already_exists'
    Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
            -ErrorAction SilentlyContinue).Count -eq 0) `
        'phase3b2_micron_operator_runtime_not_cold'

    $credential = Get-Credential -UserName $AccountName `
        -Message '새 Micron 전용 Windows 계정 암호를 정하세요. NIKKE 계정 암호가 아닙니다.'
    Assert-True ($null -ne $credential -and
        $credential.Password.Length -ge 12) `
        'phase3b2_micron_operator_password_too_short_or_cancelled'

    $account = New-LocalUser -Name $AccountName -Password $credential.Password `
        -AccountNeverExpires -PasswordNeverExpires `
        -Description 'NLL isolated physical client operator'
    $created = $true
    $administrators = Get-LocalGroup -SID 'S-1-5-32-544'
    Add-LocalGroupMember -Group $administrators -Member $account

    $account = Get-LocalUser -Name $AccountName
    $adminMembership = @(Get-LocalGroupMember -Group $administrators |
        Where-Object { $_.SID.Value -ceq $account.SID.Value }).Count
    Assert-True ($account.Enabled -and $adminMembership -eq 1) `
        'phase3b2_micron_operator_account_verification_failed'

    New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
    $evidenceCreated = $true
    New-Item -ItemType Directory -Path $SamsungProtectedRoot -Force | Out-Null
    $protectedCreated = $true
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-micron-operator-account/v1'
        createdAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        accountName = $AccountName
        accountEnabled = $true
        localAdministrator = $true
        profileCreated = $false
        profileIsolationPendingFirstSignIn = $true
        existingOperatorLocalLowReadPerformed = $false
        existingOperatorLocalLowWritePerformed = $false
        existingOperatorNikkeCacheMutationPerformed = $false
        passwordPersistedOutsideWindowsCredentialStore = $false
        passwordEmitted = $false
        credentialPromptUserNameCode = 'bare_local_account_name'
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'sign_out_then_sign_in_as_nlloperator_and_verify_profile'
    }
    $receiptPath = Join-Path $EvidenceRoot 'account-creation.receipt.json'
    Write-AtomicUtf8NoBom $receiptPath `
        (($receipt | ConvertTo-Json -Depth 6) + "`n")
    Copy-Item -LiteralPath $receiptPath -Destination $SamsungProtectedRoot
    $protectedPath = Join-Path $SamsungProtectedRoot `
        'account-creation.receipt.json'
    Assert-True ((Get-Sha256Hex $protectedPath) -ceq
        (Get-Sha256Hex $receiptPath)) `
        'phase3b2_micron_operator_protected_copy_failed'
    $credential = $null
    $receipt | ConvertTo-Json -Depth 7
}
catch {
    $credential = $null
    if ($created) {
        Remove-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
    }
    if ($evidenceCreated -and (Test-Path -LiteralPath $EvidenceRoot)) {
        Remove-Item -LiteralPath $EvidenceRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
    if ($protectedCreated -and
        (Test-Path -LiteralPath $SamsungProtectedRoot)) {
        Remove-Item -LiteralPath $SamsungProtectedRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
    throw
}
