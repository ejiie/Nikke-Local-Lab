param(
    [string]$ServerRoot =
        'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64',
    [string]$BackupRoot =
        'C:\NLL\Backups\Phase3B2\EpinelMinimalDeployment-v1',
    [string]$EvidenceRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\epinel-minimal-deployment-v1'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True (
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
) 'phase3b2_epinel_minimal_rollback_requires_administrator'

$runtimeProcesses = @(
    Get-Process -Name EpinelPS, nikke, nikke_launcher,
        NikkeLocalLab.Phase3B2.PhysicalBootstrap -ErrorAction SilentlyContinue
)
Assert-True ($runtimeProcesses.Count -eq 0) `
    'phase3b2_epinel_minimal_rollback_runtime_not_cold'

$deploymentReceiptPath = Join-Path $EvidenceRoot 'deployment.receipt.json'
$serverRootBefore = Join-Path $BackupRoot 'server-root-before'
$deployedQuarantine = Join-Path $BackupRoot `
    'deployed-server-root-before-rollback'
$rollbackReceiptPath = Join-Path $EvidenceRoot 'rollback.receipt.json'

Assert-True (
    (Test-Path -LiteralPath $deploymentReceiptPath -PathType Leaf) -and
    (Test-Path -LiteralPath $serverRootBefore -PathType Container) -and
    (Test-Path -LiteralPath $ServerRoot -PathType Container) -and
    -not (Test-Path -LiteralPath $deployedQuarantine) -and
    -not (Test-Path -LiteralPath $rollbackReceiptPath)
) 'phase3b2_epinel_minimal_rollback_shape_invalid'

$deployment = Get-Content -LiteralPath $deploymentReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $deployment.contractId -ceq `
        'nll/phase3b2-epinel-minimal-offline-deployment/v1' -and
    $deployment.deploymentApplied -and
    $deployment.serverExecutionStarted -eq $false -and
    $deployment.clientExecutionStarted -eq $false
) 'phase3b2_epinel_minimal_rollback_receipt_invalid'

$deployedDllPath = Join-Path $ServerRoot 'EpinelPS.dll'
$priorDllPath = Join-Path $serverRootBefore 'EpinelPS.dll'
Assert-True (
    (Get-Sha256Hex $deployedDllPath) -ceq `
        ([string]$deployment.deployedServerDllSha256) -and
    (Get-Sha256Hex $priorDllPath) -ceq `
        ([string]$deployment.priorServerDllSha256)
) 'phase3b2_epinel_minimal_rollback_binary_drift'

$deployedMoved = $false
$priorRestored = $false
try {
    Move-Item -LiteralPath $ServerRoot -Destination $deployedQuarantine
    $deployedMoved = $true
    Move-Item -LiteralPath $serverRootBefore -Destination $ServerRoot
    $priorRestored = $true

    Assert-True (
        (Get-Sha256Hex (Join-Path $ServerRoot 'EpinelPS.dll')) -ceq `
            ([string]$deployment.priorServerDllSha256)
    ) 'phase3b2_epinel_minimal_rollback_restore_digest_mismatch'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-minimal-rollback/v1'
        rolledBackAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        deploymentReceiptSha256 = Get-Sha256Hex $deploymentReceiptPath
        priorServerDllSha256 = [string]$deployment.priorServerDllSha256
        deployedServerRootPreserved = $true
        deployedServerRootQuarantine = $deployedQuarantine
        priorServerRootRestored = $true
        databaseAndCacheRestoredWithPriorRoot = $true
        serverExecutionStarted = $false
        clientExecutionStarted = $false
    }
    Write-Utf8NoBom $rollbackReceiptPath `
        (($receipt | ConvertTo-Json -Depth 5) + "`n")
    $receipt | ConvertTo-Json -Depth 5
}
catch {
    if ($priorRestored -and (Test-Path -LiteralPath $ServerRoot) -and
        -not (Test-Path -LiteralPath $serverRootBefore)) {
        Move-Item -LiteralPath $ServerRoot -Destination $serverRootBefore
    }
    if ($deployedMoved -and (Test-Path -LiteralPath $deployedQuarantine) -and
        -not (Test-Path -LiteralPath $ServerRoot)) {
        Move-Item -LiteralPath $deployedQuarantine -Destination $ServerRoot
    }
    throw
}
