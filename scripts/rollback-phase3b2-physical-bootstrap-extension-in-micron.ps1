[CmdletBinding()]
param(
    [string]$EvidenceRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\p2-preparation-v1',
    [string]$SamsungProtectedRoot =
        'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\Preparation'
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
    'phase3b2_physical_p2_extension_rollback_requires_administrator'
Assert-True ((Get-Partition -DriveLetter C | Get-Disk).FriendlyName -ceq
    'Micron_2200_MTFDHBA512TCK') `
    'phase3b2_physical_p2_extension_rollback_must_run_from_micron'
Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_physical_p2_extension_rollback_runtime_not_cold'

$preparationPath = Join-Path $EvidenceRoot 'preparation.receipt.json'
$rollbackPlanPath = Join-Path $EvidenceRoot 'rollback-plan.json'
Assert-True ((Test-Path -LiteralPath $preparationPath -PathType Leaf) -and
    (Test-Path -LiteralPath $rollbackPlanPath -PathType Leaf)) `
    'phase3b2_physical_p2_extension_rollback_evidence_missing'
$preparation = Get-Content -LiteralPath $preparationPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($preparation.contractId -ceq
        'nll/phase3b2-physical-p2-preparation/v1' -and
    $preparation.rollbackPlanSha256 -ceq (Get-Sha256Hex $rollbackPlanPath)) `
    'phase3b2_physical_p2_extension_rollback_evidence_invalid'

$extensionFirewallGroup = 'NLL Phase3B2 Physical Bootstrap Extension'
$baseFirewallGroup = 'NLL Phase3B2 Physical Isolation'
$rulesBefore = @(Get-NetFirewallRule -Group $extensionFirewallGroup `
    -ErrorAction SilentlyContinue)
Assert-True ($rulesBefore.Count -eq 1) `
    'phase3b2_physical_p2_extension_rollback_rule_shape_invalid'
$rulesBefore | Remove-NetFirewallRule
Assert-True (@(Get-NetFirewallRule -Group $extensionFirewallGroup `
        -ErrorAction SilentlyContinue).Count -eq 0 -and
    @(Get-NetFirewallRule -Group $baseFirewallGroup `
        -ErrorAction SilentlyContinue).Count -eq 17) `
    'phase3b2_physical_p2_extension_rollback_failed'

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-physical-bootstrap-extension-rollback/v1'
    rolledBackAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    preparationReceiptByteLength = (Get-Item $preparationPath).Length
    preparationReceiptSha256 = Get-Sha256Hex $preparationPath
    removedExtensionFirewallRuleCount = $rulesBefore.Count
    extensionFirewallRuleCountAfter = 0
    baseP0FirewallRuleCountAfter = 17
    baseP0Preserved = $true
    primaryInstallModified = $false
    officialLauncherModified = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
$receiptPath = Join-Path $EvidenceRoot 'extension-rollback.receipt.json'
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) `
    'phase3b2_physical_p2_extension_rollback_receipt_already_exists'
Write-AtomicUtf8NoBom $receiptPath `
    (($receipt | ConvertTo-Json -Depth 6) + "`n")
Copy-Item -LiteralPath $receiptPath -Destination $SamsungProtectedRoot
$copyPath = Join-Path $SamsungProtectedRoot (Split-Path -Leaf $receiptPath)
Assert-True ((Get-Sha256Hex $copyPath) -ceq (Get-Sha256Hex $receiptPath)) `
    'phase3b2_physical_p2_extension_rollback_protected_copy_failed'
$receipt | ConvertTo-Json -Depth 7
