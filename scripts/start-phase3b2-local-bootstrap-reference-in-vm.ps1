[CmdletBinding()]
param(
    [string]$AssessmentUid = "",

    [string]$ReadyReceiptPath = "",

    [long]$ReadyReceiptByteLength = 0,

    [string]$ReadyReceiptSha256 = ""
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    "administrator_required"

$trustedRoot = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted"
$p0Path = Join-Path $trustedRoot `
    "p0\applied-verification-private-v5.receipt.json"
$p1Root = Join-Path $trustedRoot "p1-private-v5"
$p1Path = Join-Path $p1Root "server-only-measurement.receipt.json"
$serverPidPath = Join-Path $p1Root "server.pid"
$projectionPath = Join-Path $trustedRoot `
    "ready-seal-private-v5\hyperv-ready-projection.json"
$runRoot = Join-Path $trustedRoot "reference-local-bootstrap-v1"
$admissionPath = Join-Path $runRoot "reference-start-admission.receipt.json"
$bootstrapStartPath = Join-Path $runRoot "bootstrap-start.receipt.json"
$bootstrapFailurePath = Join-Path $runRoot "bootstrap-failure.receipt.json"
$bootstrapExitPath = Join-Path $runRoot "bootstrap-exit.receipt.json"
$bootstrapPath = `
    "C:\NLL\LocalBootstrap\v1\NikkeLocalLab.Phase3B2.LocalBootstrap.exe"

if ([string]::IsNullOrEmpty($ReadyReceiptPath)) {
    $readyCandidates = @(Get-ChildItem -LiteralPath `
            "C:\NLL\Staging\Ready-v5" -File -Filter *.ready.json `
            -ErrorAction Stop)
    Assert-True ($readyCandidates.Count -eq 1) `
        "phase3b2_local_bootstrap_ready_receipt_selection_invalid"
    $ReadyReceiptPath = $readyCandidates[0].FullName
}
if ($ReadyReceiptByteLength -eq 0) {
    $ReadyReceiptByteLength = (Get-Item -LiteralPath $ReadyReceiptPath).Length
}
if ([string]::IsNullOrEmpty($ReadyReceiptSha256)) {
    $ReadyReceiptSha256 = Get-Sha256Hex $ReadyReceiptPath
}
Assert-True ($ReadyReceiptSha256 -cmatch "^[0-9a-f]{64}$") `
    "phase3b2_local_bootstrap_ready_receipt_sha_invalid"
Assert-True ((Get-Item -LiteralPath $ReadyReceiptPath).Length -eq
        $ReadyReceiptByteLength -and
    (Get-Sha256Hex $ReadyReceiptPath) -ceq $ReadyReceiptSha256) `
    "phase3b2_local_bootstrap_ready_receipt_drift"
$ready = Get-Content -LiteralPath $ReadyReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
if ([string]::IsNullOrEmpty($AssessmentUid)) {
    $AssessmentUid = [string]$ready.assessmentUid
}
Assert-True ($AssessmentUid -cmatch
        "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$") `
    "phase3b2_local_bootstrap_assessment_uid_invalid"
$p0 = Get-Content -LiteralPath $p0Path -Raw -Encoding UTF8 | ConvertFrom-Json
$p1 = Get-Content -LiteralPath $p1Path -Raw -Encoding UTF8 | ConvertFrom-Json
$projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 |
    ConvertFrom-Json

Assert-True ($ready.contractId -ceq
        "nll/season26-classic-live-preflight/v1" -and
    $ready.assessmentUid -ceq $AssessmentUid -and
    $ready.verdict -ceq
        "ready_to_start_isolated_season26_reference_run" -and
    $ready.measuredEvidence.statusCode -ceq "measured_complete" -and
    -not [bool]$ready.environment.clientExecutionStarted -and
    -not [bool]$ready.remainingBoundary.referenceRunExecuted) `
    "phase3b2_local_bootstrap_ready_receipt_invalid"
Assert-True ($projection.contractId -ceq
        "nll/phase3b2-hyperv-ready-projection/v1" -and
    $projection.assessmentUid -ceq $AssessmentUid -and
    $projection.clientBootstrapModeCode -ceq
        "source_built_sail_abi_local_bootstrap" -and
    $projection.networkModeCode -ceq "private_vm_only_no_gateway" -and
    $projection.serverRunning -and
    -not $projection.clientExecutionStarted) `
    "phase3b2_local_bootstrap_projection_invalid"
Assert-True ($p0.contractId -ceq
        "nll/phase3b2-p0-private-applied-verification/v5" -and
    $p0.p0AppliedVerified -and
    $p0.clientBootstrapModeCode -ceq
        "source_built_sail_abi_local_bootstrap" -and
    -not [bool]$p0.officialLauncherExecutionPermitted -and
    -not [bool]$p0.antiCheatSubstitutionApplied -and
    [int]$p0.firewallRuleCount -eq 17 -and
    -not [bool]$p0.clientExecutionStarted) `
    "phase3b2_local_bootstrap_p0_invalid"
Assert-True ($p1.contractId -ceq
        "nll/phase3b2-p1-private-server-only-measurement/v5" -and
    $p1.serverRunning -and
    $p1.clientBootstrapModeCode -ceq
        "source_built_sail_abi_local_bootstrap" -and
    -not [bool]$p1.officialLauncherExecutionPermitted -and
    -not [bool]$p1.antiCheatSubstitutionApplied -and
    [int]$p1.httpIpv4LoopbackListenerCount -eq 1 -and
    [int]$p1.httpsIpv4LoopbackListenerCount -eq 1 -and
    [int]$p1.nonLoopbackAttemptCount -eq 0 -and
    [int]$p1.nonLoopbackSuccessfulConnectionCount -eq 0 -and
    -not [bool]$p1.clientExecutionStarted) `
    "phase3b2_local_bootstrap_p1_invalid"

$serverPid = [int](Get-Content -LiteralPath $serverPidPath -Raw).Trim()
$server = @(Get-Process -Name EpinelPS -ErrorAction SilentlyContinue)
$runtime = @(Get-Process -Name nikke_launcher, nikke,
        NikkeLocalLab.Phase3B2.LocalBootstrap -ErrorAction SilentlyContinue)
Assert-True ($server.Count -eq 1 -and $server[0].Id -eq $serverPid -and
    $runtime.Count -eq 0) `
    "phase3b2_local_bootstrap_reference_runtime_shape_invalid"
$tcp = @(Get-NetTCPConnection -OwningProcess $serverPid -State Listen `
        -ErrorAction Stop)
Assert-True (@($tcp | Where-Object {
            $_.LocalAddress -ceq "127.0.0.1" -and $_.LocalPort -eq 80
        }).Count -eq 1 -and
    @($tcp | Where-Object {
            $_.LocalAddress -ceq "127.0.0.1" -and $_.LocalPort -eq 443
        }).Count -eq 1 -and
    @($tcp | Where-Object LocalAddress -CNE "127.0.0.1").Count -eq 0 -and
    @(Get-NetUDPEndpoint -OwningProcess $serverPid `
            -ErrorAction SilentlyContinue | Where-Object LocalPort -EQ 443).Count -eq 0) `
    "phase3b2_local_bootstrap_reference_listener_shape_invalid"
Assert-True (@(Get-NetRoute -AddressFamily IPv4 `
            -DestinationPrefix "0.0.0.0/0" `
            -ErrorAction SilentlyContinue).Count -eq 0 -and
    @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" `
            -ErrorAction SilentlyContinue).Count -eq 0 -and
    @(Get-NetFirewallRule -Group "NLL Phase3B2 Isolation" `
            -ErrorAction Stop).Count -eq 17) `
    "phase3b2_local_bootstrap_reference_network_shape_invalid"
Assert-True ((Test-Path -LiteralPath $bootstrapPath -PathType Leaf) -and
    (Get-FileHash -LiteralPath $bootstrapPath -Algorithm SHA256).Hash `
        -ceq "4B6A8C844F291BDC956D0907F5898CB4B4FD54B0D95671EE1A75873867012773" -and
    -not (Test-Path -LiteralPath $runRoot)) `
    "phase3b2_local_bootstrap_reference_evidence_shape_invalid"

New-Item -ItemType Directory -Path $runRoot | Out-Null
$admission = [ordered]@{
    contractId = "nll/phase3b2-local-bootstrap-reference-admission/v1"
    admittedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    assessmentUid = $AssessmentUid
    readyReceiptByteLength = $ReadyReceiptByteLength
    readyReceiptSha256 = $ReadyReceiptSha256
    clientBootstrapModeCode = "source_built_sail_abi_local_bootstrap"
    serverProcessContinuityVerified = $true
    privateNetworkNoDefaultRouteVerified = $true
    officialLauncherExecutionPermitted = $false
    antiCheatSubstitutionApplied = $false
    retryPerformed = $false
    clientExecutionStarted = $false
}
Write-Utf8NoBom $admissionPath (($admission | ConvertTo-Json) + "`n")

$oldAssessmentUid = [Environment]::GetEnvironmentVariable(
    "NLL_PHASE3B2_ASSESSMENT_UID", "Process")
try {
    [Environment]::SetEnvironmentVariable(
        "NLL_PHASE3B2_ASSESSMENT_UID", $AssessmentUid, "Process")
    $bootstrap = Start-Process -FilePath $bootstrapPath `
        -WorkingDirectory (Split-Path -Parent $bootstrapPath) -PassThru
}
finally {
    [Environment]::SetEnvironmentVariable(
        "NLL_PHASE3B2_ASSESSMENT_UID", $oldAssessmentUid, "Process")
}

for ($attempt = 0; $attempt -lt 600; $attempt++) {
    if (Test-Path -LiteralPath $bootstrapStartPath -PathType Leaf) { break }
    if (Test-Path -LiteralPath $bootstrapFailurePath -PathType Leaf) { break }
    $bootstrap.Refresh()
    if ($bootstrap.HasExited -and
        -not (Test-Path -LiteralPath $bootstrapExitPath -PathType Leaf)) { break }
    Start-Sleep -Milliseconds 250
}

if (Test-Path -LiteralPath $bootstrapFailurePath -PathType Leaf) {
    $failure = Get-Content -LiteralPath $bootstrapFailurePath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    throw "phase3b2_local_bootstrap_reference_failed:$($failure.failedStageCode):$($failure.reasonCode)"
}
Assert-True (Test-Path -LiteralPath $bootstrapStartPath -PathType Leaf) `
    "phase3b2_local_bootstrap_client_start_not_observed"
$start = Get-Content -LiteralPath $bootstrapStartPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($start.contractId -ceq
        "nll/phase3b2-local-bootstrap-client-start/v1" -and
    $start.assessmentUid -ceq $AssessmentUid -and
    $start.bootstrapModeCode -ceq
        "source_built_sail_abi_local_bootstrap" -and
    $start.accountLoginAccepted -and
    $start.intlAuthenticationAccepted -and
    $start.sailSharedMemoryCreated -and
    $start.sailNamedPipeConnected -and
    [int]$start.clientProcessCount -eq 1 -and
    $start.clientExecutionStarted -and
    -not $start.officialLauncherExecutionStarted -and
    -not $start.antiCheatSubstitutionApplied -and
    -not $start.officialIdentityPersisted -and
    -not $start.officialCredentialPersisted) `
    "phase3b2_local_bootstrap_client_start_receipt_invalid"
$start | ConvertTo-Json
