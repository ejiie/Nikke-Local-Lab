#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.
        ToLowerInvariant()
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporary, $Text, [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

$restoreUid = '__GOLDEN_RESTORE_UID__'
$expectedRestoreReceiptSha256 = '__GOLDEN_RESTORE_RECEIPT_SHA256__'
$expectedDatabaseSha256 =
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
$expectedWrapperSha256 =
    'fe667ba466ea27a5bfd55e09c4d0cd9ef94b04d434d95ac1590ccd7f813e493b'
$expectedInnerStartSha256 =
    'a039cd5186df92c16c0091f7d4b4c4bbb907d0bf2adc3ff94d8d425699bc5f69'
$expectedHostsSha256 =
    'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
$extensionFirewallGroup = 'NLL Phase3B2 Epinel Minimal Extension'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True ($principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_epinel_golden_restore_finalize_requires_administrator'
Assert-True (
    $env:SystemDrive -ceq 'C:' -and
    $env:USERNAME -ceq 'nlloperator' -and
    (Get-Partition -DriveLetter C | Get-Disk).FriendlyName -like
        'Micron_2200*'
) 'phase3b2_epinel_golden_restore_finalize_wrong_boundary_or_user'
Assert-True (@(Get-Process -Name @(
        'EpinelPS', 'NIKKE', 'nikke_launcher',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
    ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_epinel_golden_restore_finalize_runtime_not_cold'

$physicalRoot = 'C:\NLL\Evidence\Phase3B2\Physical'
$runtimeRoot = 'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$evidenceRoot = Join-Path (
    $physicalRoot + '\epinel-lobby-golden-restore-v1'
) $restoreUid
$restoreReceiptPath = Join-Path $evidenceRoot 'restore.receipt.json'
$bindingReceiptPath = Join-Path $evidenceRoot 'finalizer.binding.receipt.json'
$finalReceiptPath = Join-Path $evidenceRoot 'finalization.receipt.json'
$pendingPointerPath = Join-Path (
    $physicalRoot + '\epinel-lobby-golden-restore-v1'
) 'pending-firewall-cleanup.pointer.json'
$archivedPointerPath = Join-Path $evidenceRoot `
    'pending-firewall-cleanup.pointer.archived.json'
$activeRunPointerPath = Join-Path (
    $physicalRoot + '\epinel-minimal-reference-v1'
) 'active-run.pointer.json'
$databasePath = Join-Path $runtimeRoot 'db.json'
$wrapperPath = 'C:\NLL\Tools\Start-Phase3B2-Epinel-NativeCache.ps1'
$innerStartPath =
    'C:\NLL\Tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$hostsPath = 'C:\Windows\System32\drivers\etc\hosts'
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
    ForEach-Object { Join-Path $runtimeRoot $_ })

Assert-True (
    (Test-Path -LiteralPath $restoreReceiptPath -PathType Leaf) -and
    (Test-Path -LiteralPath $bindingReceiptPath -PathType Leaf) -and
    (Test-Path -LiteralPath $pendingPointerPath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $finalReceiptPath) -and
    -not (Test-Path -LiteralPath $activeRunPointerPath) -and
    @($sqlitePaths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0
) 'phase3b2_epinel_golden_restore_finalize_input_shape_invalid'
Assert-True (
    (Get-Sha256Hex $restoreReceiptPath) -ceq
        $expectedRestoreReceiptSha256 -and
    (Get-Sha256Hex $databasePath) -ceq $expectedDatabaseSha256 -and
    (Get-Sha256Hex $wrapperPath) -ceq $expectedWrapperSha256 -and
    (Get-Sha256Hex $innerStartPath) -ceq $expectedInnerStartSha256 -and
    (Get-Sha256Hex $hostsPath) -ceq $expectedHostsSha256
) 'phase3b2_epinel_golden_restore_finalize_digest_invalid'

$restore = Get-Content -LiteralPath $restoreReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$binding = Get-Content -LiteralPath $bindingReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$pending = Get-Content -LiteralPath $pendingPointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$selfPath = $MyInvocation.MyCommand.Path
Assert-True (
    $restore.contractId -ceq
        'nll/phase3b2-epinel-lobby-golden-restore/v1' -and
    $restore.restoreUid -ceq $restoreUid -and
    $restore.goldenBaselineActive -and
    $restore.firewallCleanupPending -and
    $binding.contractId -ceq
        'nll/phase3b2-epinel-lobby-golden-restore-finalizer-binding/v1' -and
    $binding.restoreUid -ceq $restoreUid -and
    $binding.restoreReceiptSha256 -ceq $expectedRestoreReceiptSha256 -and
    $binding.activeFinalizerSha256 -ceq (Get-Sha256Hex $selfPath) -and
    $pending.contractId -ceq
        'nll/phase3b2-epinel-lobby-golden-restore-pending-finalization/v1' -and
    $pending.restoreUid -ceq $restoreUid -and
    $pending.restoreReceiptSha256 -ceq $expectedRestoreReceiptSha256
) 'phase3b2_epinel_golden_restore_finalize_contract_invalid'

$observedExtensionFirewallRuleCount = @(
    Get-NetFirewallRule -Group $extensionFirewallGroup `
        -ErrorAction SilentlyContinue
).Count
Get-NetFirewallRule -Group $extensionFirewallGroup `
    -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Assert-True (@(Get-NetFirewallRule -Group $extensionFirewallGroup `
            -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_epinel_golden_restore_finalize_firewall_remove_failed'

$receipt = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-epinel-lobby-golden-restore-finalization/v1'
    finalizedAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    restoreUid = $restoreUid
    restoreReceiptSha256 = $expectedRestoreReceiptSha256
    finalizerBindingReceiptSha256 = Get-Sha256Hex $bindingReceiptPath
    observedExtensionFirewallRuleCount =
        $observedExtensionFirewallRuleCount
    extensionFirewallRemoved = $true
    databaseSha256 = $expectedDatabaseSha256
    outerWrapperSha256 = $expectedWrapperSha256
    innerStartSha256 = $expectedInnerStartSha256
    hostsSha256 = $expectedHostsSha256
    activeRunPointerPresent = $false
    sqliteRuntimeMemberCount = 0
    goldenBaselineActive = $true
    tutorialRevisionActive = $false
    officialOutboundUsed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    validationRunConsumed = $false
    nextStepCode =
        'return_to_samsung_implement_from_golden_lobby_baseline'
}
Write-AtomicUtf8NoBom $finalReceiptPath (
    ($receipt | ConvertTo-Json -Depth 6) + "`n"
)
Move-Item -LiteralPath $pendingPointerPath `
    -Destination $archivedPointerPath

[pscustomobject]@{
    Receipt = $receipt
    ReceiptPath = $finalReceiptPath
    ReceiptByteLength = (Get-Item -LiteralPath $finalReceiptPath).Length
    ReceiptSha256 = Get-Sha256Hex $finalReceiptPath
} | ConvertTo-Json -Depth 8
