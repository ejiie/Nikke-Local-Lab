# Narrow runtime boundaries, replaced by synthetic test doubles only in offline tests.
function Assert-PhaseDRunnerHost {
    param([ValidateSet('start','completion')][string]$Phase)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw ('phase3b2_epinel_minimal_' + $Phase + '_requires_administrator')
    }
    if ($env:SystemDrive -cne 'C:' -or $env:USERNAME -cne 'nlloperator') {
        throw ('phase3b2_epinel_minimal_' + $Phase + '_wrong_operator_or_boot_boundary')
    }
}
function Get-PhaseDRunnerHostsPath { Join-Path $env:SystemRoot 'System32\drivers\etc\hosts' }
function Get-PhaseDRunnerHostPins {
    @{base='dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'; applied='3b0dcc4396373e9e9d623ef05c345f89330427ad5128727290c9f76138e22f64'}
}
function Get-PhaseDRunnerContextPath { 'C:\NLL\Evidence\Phase3B2\Physical\server-profile-v1\identity\synthetic-context.json' }
function Get-PhaseDRunnerBootstrapEvidenceRoot([string]$Lane) { Join-Path 'C:\NLL\Evidence\Phase3B2\Physical' $Lane }
function New-PhaseDRunnerStopwatch { [Diagnostics.Stopwatch]::StartNew() }
function Start-PhaseDRunnerBootstrap {
    param([object]$Specification, [string]$Path)
    if ($Specification.contractId -cne 'nll/phase-d-runner-input/v3') {
        return Start-Process -FilePath $Path -WorkingDirectory (Split-Path -Parent $Path) -PassThru -WindowStyle Hidden
    }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Path; $info.WorkingDirectory = Split-Path -Parent $Path
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    [Diagnostics.Process]::Start($info)
}
function Assert-PhaseDRunnerJobProcess {
    param([object]$Specification, [int]$ProcessId)
    if ($Specification.contractId -cne 'nll/phase-d-runner-input/v3') { return }
    $bundle = Read-PhaseDRunnerBundle -LaunchRoot $Specification.launchRoot
    $job = Open-PhaseDExecutionJob $Specification.launchRoot $bundle.sha256
    try {
        if (-not $job.Contains($PID) -or -not $job.Contains($ProcessId)) { throw 'phase_d_job_runtime_member_unproven' }
    } finally { $job.Dispose() }
}
function Invoke-PhaseDRunnerResourcePreflight {
    param([object]$Specification)
    if (-not $Specification.resourcePreflightRequired -or $Specification.clientBuildCode -cne 'build_150.6.9') {
        throw 'phase_d_runner_resource_lane_invalid'
    }
    if ((Get-FileHash -LiteralPath $Specification.resourcePreflightHelper -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Specification.resourcePreflightHelperSha256) {
        throw 'phase_d_resource_preflight_helper_drifted'
    }
    . $Specification.resourcePreflightHelper
    Assert-NllResourceTransportBeforeClient -ToolPath $Specification.resourcePreflightTool `
        -ReceiptPath $Specification.resourceCatalogReceiptPath -ReceiptSha256 $Specification.resourceCatalogReceiptSha256 `
        -ToolSha256 $Specification.resourcePreflightToolSha256 `
        -TransportReceiptPath (Join-Path $Specification.launchRoot 'resource-loopback-preflight.receipt.json')
}
function Invoke-PhaseDRunnerCapture {
    param([object]$Specification, [string]$SourceDatabasePath)
    $scopeArguments = @()
    if ($Specification.contractId -cin @('nll/phase-d-runner-input/v2','nll/phase-d-runner-input/v3')) {
        $scopeArguments = @('--weakness-code', [string]$Specification.weaknessCode)
    }
    $captureOutput = @(& $Specification.runtimeMaterializer --capture-solo-raid-state true `
        --source-db $SourceDatabasePath --pending-payload $Specification.soloRaidPendingPath `
        --receipt $Specification.soloRaidCaptureReceiptPath --account-uid $Specification.accountUid `
        --account-revision-set-sha256 $Specification.accountRevisionSetSha256 --season-number ([string]$Specification.seasonNumber) `
        --raid-snapshot-uid $Specification.raidSnapshotUid --raid-snapshot-sha256 $Specification.raidSnapshotSha256 `
        --client-build-code $Specification.clientBuildCode --client-executable-sha256 $Specification.clientExecutableSha256 `
        --launch-context-uid $Specification.launchContextUid --expected-head-revision-uid $Specification.expectedSoloRaidHeadRevisionUid `
        --identity-secret-env $Specification.secretEnvironmentVariable @scopeArguments 2>&1)
    $captureExitCode = $LASTEXITCODE
    if ($captureExitCode -ne 0) {
        $failureCode = @($captureOutput | ForEach-Object { [string]$_ } | Where-Object { $_ -cmatch '^phase_d_[a-z0-9._-]{3,128}$' }) | Select-Object -Last 1
        if ([string]::IsNullOrWhiteSpace([string]$failureCode)) { $failureCode = 'phase_d_raid_state_capture_failed' }
        throw [string]$failureCode
    }
    if (-not (Test-Path -LiteralPath $Specification.soloRaidPendingPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $Specification.soloRaidCaptureReceiptPath -PathType Leaf)) {
        throw 'phase_d_raid_state_capture_output_missing'
    }
}
