[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Evidence {
    param([string]$Path)
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) `
        "phase3b2_credential_v3_expected_output_missing"
    return [ordered]@{
        byteLength = (Get-Item -LiteralPath $Path).Length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$toolRoot = "C:\NLL\Tools"
$trustedRoot = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted"
$repairScript = Join-Path $toolRoot `
    "repair-phase3b2-synthetic-launcher-credential-in-vm.ps1"
$adapterVerificationScript = Join-Path $toolRoot `
    "verify-phase3b2-profile-adapter-launcher-credential-in-vm.ps1"
$p0VerificationScript = Join-Path $toolRoot `
    "verify-phase3b2-p0-launcher-credential-applied-in-vm.ps1"
foreach ($script in @($repairScript, $adapterVerificationScript,
        $p0VerificationScript)) {
    Assert-True (Test-Path -LiteralPath $script -PathType Leaf) `
        "phase3b2_credential_v3_tool_missing"
}
Assert-True ($null -eq (Get-Process -Name EpinelPS, nikke_launcher, nikke `
        -ErrorAction SilentlyContinue)) "phase3b2_credential_v3_runtime_not_cold"

& $repairScript | Out-Null
& $adapterVerificationScript | Out-Null
& $p0VerificationScript | Out-Null

$repairPath = Join-Path $trustedRoot `
    "identity\launcher-credential-v1\repair.receipt.json"
$adapterPath = Join-Path $trustedRoot `
    "identity\launcher-credential-v1\profile-adapter-build.receipt.json"
$p0Path = Join-Path $trustedRoot `
    "p0\applied-verification-private-v3.receipt.json"
$repairEvidence = Get-Evidence $repairPath
$adapterEvidence = Get-Evidence $adapterPath
$p0Evidence = Get-Evidence $p0Path
$p0 = Get-Content -LiteralPath $p0Path -Raw -Encoding UTF8 | ConvertFrom-Json
$repair = Get-Content -LiteralPath $repairPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($p0.contractId -ceq
        "nll/phase3b2-p0-private-applied-verification/v3" -and
    [bool]$p0.p0AppliedVerified -and
    [bool]$p0.launcherPasswordRepresentationVerified -and
    -not [bool]$p0.serverExecutionStarted -and
    -not [bool]$p0.clientExecutionStarted) `
    "phase3b2_credential_v3_p0_invalid"
Assert-True ([int]$repair.sqliteBaselineMemberCount -eq 3 -and
    [int]$repair.sqliteStateMutationCount -eq 0 -and
    [int]$p0.sqliteBaselineMemberCount -eq 3 -and
    [int]$p0.sqliteStateMutationCount -eq 0) `
    "phase3b2_credential_v3_sqlite_baseline_invalid"

[ordered]@{
    contractId = "nll/phase3b2-launcher-credential-v3-preparation/v1"
    preparedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    credentialRepairReceiptByteLength = [long]$repairEvidence.byteLength
    credentialRepairReceiptSha256 = [string]$repairEvidence.sha256
    profileAdapterBuildReceiptByteLength = [long]$adapterEvidence.byteLength
    profileAdapterBuildReceiptSha256 = [string]$adapterEvidence.sha256
    p0V3ReceiptByteLength = [long]$p0Evidence.byteLength
    p0V3ReceiptSha256 = [string]$p0Evidence.sha256
    launcherPasswordPlaintextLength = 20
    launcherPasswordStorageLength = 32
    launcherPasswordStorageSchemeCode =
        "md5_lower_hex_legacy_launcher_compatibility"
    launcherPasswordRepresentationVerified = $true
    sqliteBaselineMemberCount = 3
    sqliteStateMutationCount = 0
    rawCredentialEmitted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
} | ConvertTo-Json
