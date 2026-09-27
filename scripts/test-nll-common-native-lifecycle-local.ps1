[CmdletBinding()]
param([Parameter(Mandatory)][string]$PreparationReceiptPath,
    [Parameter(Mandatory)][string]$OutputPath)
# Operator-authorized installation rehearsal. Uses prepared common execution
# inputs and the exact isolated clone; never runs the server/bootstrap/game.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$PreparationReceiptPath=[IO.Path]::GetFullPath($PreparationReceiptPath)
$OutputPath=[IO.Path]::GetFullPath($OutputPath)
. (Join-Path $PSScriptRoot 'Nll.PhaseDPreparation.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerContract.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerSeal.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDChildProcess.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDJob.ps1')
. (Join-Path $PSScriptRoot 'Nll.ControlCenterMaintenance.ps1')
function Write-AtomicJson([string]$Path,$Value) {
    $temporary=$Path+'.partial-'+[guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
if (Test-Path -LiteralPath $OutputPath) { throw 'common_native_rehearsal_output_exists' }
$preparation=Get-Content -LiteralPath $PreparationReceiptPath -Raw | ConvertFrom-Json
if ($preparation.contractId -cne 'nll/common-runtime-preparation-rehearsal/v1' -or $preparation.gameStarted -ne $false) {
    throw 'common_native_rehearsal_input_invalid'
}
$maintenance=Enter-NllControlCenterMaintenance 'C:\NLL\ControlCenter' deploy
try {
    if (@(Get-Process -Name nikke,EpinelPS,postgres,NikkeLocalLab.Admin.Api -ErrorAction SilentlyContinue).Count -ne 0) {
        throw 'common_native_rehearsal_not_cold'
    }
    $null=Read-PdRuntimeBundle 'C:\NLL\ControlCenter\runtime-selection.private.json'
    $results=@()
    foreach ($case in $preparation.cases) {
        $launch=Join-Path (Split-Path -Parent $PreparationReceiptPath) $case.launchContextUid
        $bundle=Read-PhaseDRunnerBundle $launch
        $spec=$bundle.specification
        if ($null -eq $spec.executionFx) { continue }
        $timer=[Diagnostics.Stopwatch]::StartNew()
        $job=New-PhaseDExecutionJob $launch $bundle.sha256
        $applied=$false; $restored=$false
        try {
            $result=Invoke-PhaseDChildScript -ExecutionJob $job -ScriptPath $spec.runtimeMaterializer `
                -Arguments ([ordered]@{'-apply-common-native-fx'='true';'-launch-root'=$launch;'-expected-bundle-sha256'=$bundle.sha256}) `
                -TimeoutSeconds 300 -OwnershipPath (Join-Path $launch 'native-rehearsal-apply.identity.json') `
                -StandardOutputPath (Join-Path $launch 'native-rehearsal-apply.stdout.log') `
                -StandardErrorPath (Join-Path $launch 'native-rehearsal-apply.stderr.log')
            if ($result.ExitCode -ne 0) { throw 'common_native_rehearsal_apply_failed' }
            $applied=$true
        }
        finally {
            Stop-PhaseDExecutionJob $launch $bundle.sha256
            # Retry through the same bound cleanup while this original Job
            # handle is still alive. Never recreate the nonce or its proof.
            for ($attempt=1; $attempt -le 3; $attempt++) {
                try { Invoke-PhaseDExecutionFxCleanup $launch $bundle.sha256; break }
                catch {
                    Write-AtomicJson (Join-Path $launch ('native-rehearsal-cleanup-error-'+$attempt+'.json')) @{
                        code=$_.Exception.Message; originalJobRetained=$true
                    }
                    # A timeout leaves its child alive. Wait for that exact
                    # process before any retry; never overlap restore owners.
                    $identityPath=Join-Path $launch 'phase-d-child-fx-retirement.identity.json'
                    if (Test-Path -LiteralPath $identityPath) {
                        $identity=Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
                        $child=Get-PhaseDVerifiedProcess $identity
                        if ($null -ne $child) {
                            try { if (-not $child.WaitForExit(300000)) { throw 'common_native_rehearsal_cleanup_still_running' } }
                            finally { $child.Dispose() }
                        }
                    }
                    if ($attempt -eq 3) { throw }
                }
            }
            Invoke-PhaseDExecutionFxCleanup $launch $bundle.sha256
            $restored=$true
            $job.Dispose()
        }
        $results += [ordered]@{seasonNumber=$case.seasonNumber;weaknessCode=$case.weaknessCode;
            applied=$applied;restored=$restored;repeatedRestoreVerified=$true;elapsedSeconds=[int]$timer.Elapsed.TotalSeconds}
        Write-Output ('FX apply/restore passed: ' + $case.weaknessCode)
    }
    Write-AtomicJson $OutputPath ([ordered]@{contractId='nll/common-native-lifecycle-rehearsal/v1';
        cases=$results;gameStarted=$false;operatingDatabaseTouched=$false;actualGameAcceptanceClaimed=$false})
} finally { $maintenance.Dispose() }
