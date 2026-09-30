# Executes fixed Start/Complete functions, with every OS/service/process boundary
# replaced. All file paths and all bytes are synthetic, including Player.log root.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'test-nll-phase-d-runner-contract.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerSeal.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDSharedIsolation.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerStart.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerComplete.ps1')
function Assert-PhaseDRunnerHost { param($Phase) }
function Get-PhaseDRunnerHostsPath { Join-Path $caseRoot 'synthetic.hosts' }
function Get-PhaseDRunnerHostPins { $script:hostPins }
function Get-PhaseDRunnerContextPath { Join-Path $caseRoot 'synthetic-context.json' }
function Get-PhaseDRunnerBootstrapEvidenceRoot { param($Lane) Join-Path $caseRoot 'bootstrap-evidence' }
function New-PhaseDRunnerStopwatch { $script:clock }
function Start-Sleep { param($Seconds, $Milliseconds) if ($Seconds) { $script:clock.Elapsed = $script:clock.Elapsed.Add([TimeSpan]::FromSeconds($Seconds)) } }
function Get-Process {
    param($Id, $Name, $ErrorAction)
    if ($null -ne $Id -and $script:processes.ContainsKey([int]$Id)) { return $script:processes[[int]$Id] }
    if ($null -ne $Name) { @($script:processes.Values | Where-Object { $_.ProcessName -in $Name }) }
}
function Stop-Process { param($Id, [switch]$Force, $ErrorAction) $script:processes.Remove([int]$Id) }
function Get-NetFirewallRule {
    param($Group, $ErrorAction)
    if ($Group -eq 'NLL Phase3B2 Physical Isolation') {
        1..17 | ForEach-Object { [pscustomobject]@{Direction='Outbound';Action='Block';Enabled='True'} }
    } else { @($script:rules.Values) }
}
function New-NetFirewallRule {
    param($Name,$DisplayName,$Group,$Direction,$Action,$Enabled,$Profile,$Program,$ErrorAction)
    $script:rules[$Name] = [pscustomobject]@{ Name=$Name; Program=$Program; Direction=$Direction; Action=$Action; Enabled=$Enabled }
}
function Get-NetFirewallApplicationFilter {
    [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$InputObject)
    process { [pscustomobject]@{ Program=$InputObject.Program } }
}
function Remove-NetFirewallRule {
    [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$InputObject)
    process { $script:rules.Remove($InputObject.Name) }
}
function Get-NetTCPConnection {
    param($OwningProcess, $State, $ErrorAction)
    if ($State -eq 'Listen' -and $case -ne 'listener-failure') {
        @(80,443) | ForEach-Object { [pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=$_} }
    }
    if ($State -eq 'Established' -and $case -eq 'network-failure') { [pscustomobject]@{RemoteAddress='192.0.2.1'} }
}
function Get-NetUDPEndpoint { param($OwningProcess,$ErrorAction) }
function Start-PhaseDRunnerBootstrap {
    param($Specification,$Path)
    Start-Process -FilePath $Path -WorkingDirectory (Split-Path -Parent $Path) -PassThru -WindowStyle Hidden
}
function Assert-PhaseDRunnerJobProcess {
    param($Specification,$ProcessId)
    Assert-Test ($ProcessId -in @(901,902,903))
    $script:membershipChecks.Add($ProcessId)
}
function Write-TestJson($Path,$Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 8)) }
function Start-Process {
    param($FilePath,$ArgumentList,$WorkingDirectory,[switch]$PassThru,[switch]$NoNewWindow,$WindowStyle,$RedirectStandardOutput,$RedirectStandardError)
    if ([IO.Path]::GetFileName($FilePath) -eq 'EpinelPS.exe') {
        Assert-Test ($env:EPINELPS_CLASSIC_SOLO_RAID_MANAGER_SELECTION -ceq 'profile_trusted_unique/v1')
        Assert-Test ($env:EPINELPS_CLASSIC_SOLO_RAID_TARGET_PROFILE_PATH -ceq $spec.bossRuntimeVariantProfile)
        Assert-Test (($env:EPINELPS_CLIENT_STATIC_DATA_VARIANT_PATH -ceq $spec.variantStaticDataPack) -or (-not $spec.staticDataVariantRequired))
        Assert-Test (($ArgumentList -join ' ') -ceq '--headless --local-only')
        $p = [pscustomobject]@{Id=901;ProcessName='EpinelPS';Responding=$true}
        $script:processes[901]=$p
        [IO.File]::WriteAllText($RedirectStandardOutput, 'synthetic-server')
        [IO.File]::WriteAllText($RedirectStandardError, '')
        return $p
    }
    Assert-Test ([IO.Path]::GetFileName($FilePath) -ceq 'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe')
    Assert-Test ($WindowStyle -ceq 'Hidden')
    $p = [pscustomobject]@{Id=902;ProcessName='NikkeLocalLab.Phase3B2.PhysicalBootstrap';Responding=$true}
    $script:processes[902]=$p
    $bootstrapEvidence = Join-Path (Get-PhaseDRunnerBootstrapEvidenceRoot) $env:NLL_PHASE3B2_ASSESSMENT_UID
    $null = New-Item -ItemType Directory -Path $bootstrapEvidence
    if ($case -eq 'bootstrap-failure') {
        Write-TestJson (Join-Path $bootstrapEvidence 'bootstrap-failure.receipt.json') @{reasonCode='synthetic_failure'}
    } else {
        $script:processes[903]=[pscustomobject]@{Id=903;ProcessName='nikke';Responding=$true}
        Write-TestJson (Join-Path $bootstrapEvidence 'bootstrap-start.receipt.json') @{
            contractId='nll/phase3b2-physical-bootstrap-client-start/v1'; assessmentUid=$env:NLL_PHASE3B2_ASSESSMENT_UID
            clientProcessId=903; sailNamedPipeConnected=$true; sailNamedPipePayloadWritten=$true
            sailNamedPipeClosedAfterPayload=$true; sailSharedMemoryRetainedForClientLifetime=$true
        }
    }
    return $p
}
function Invoke-PhaseDRunnerCapture {
    param($Specification,$SourceDatabasePath)
    Assert-Test ($script:processes.Count -eq 0)
    Assert-Test (([IO.File]::ReadAllText($SourceDatabasePath)) -ceq '{"Users":[],"changed":true}')
    Assert-Test ((Get-PhaseDRunnerHash (Get-PhaseDRunnerHostsPath)) -ceq $script:hostPins.applied)
    if ($case -eq 'capture-failure') { throw 'phase_d_synthetic_capture_failed' }
    $script:captureCalled=$true
}
$originalSpec = $spec
$previousProfile = $env:USERPROFILE
$environmentNames = @('EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID','EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID',
    'EPINELPS_CLASSIC_SOLO_RAID_MANAGER_SELECTION','EPINELPS_CLASSIC_SOLO_RAID_TARGET_PROFILE_PATH',
    'EPINELPS_CLIENT_STATIC_DATA_VARIANT_PATH','EPINELPS_CLIENT_STATIC_DATA_VARIANT_SHA256',
    'NLL_PHASE3B2_ASSESSMENT_UID','NLL_PHASE3B2_EVIDENCE_LANE')
$previousEnvironment=@{}
foreach ($name in $environmentNames) { $previousEnvironment[$name]=[Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name,$null) }
$count=0
try {
    $env:USERPROFILE=$root
    foreach ($build in @('build_151.8.5','build_152.8.11')) {
      foreach ($variant in @($false,$true)) {
       foreach ($case in @('early-exit','observed-exit','digest-failure','listener-failure','bootstrap-failure','network-failure','capture-failure')) {
        $caseRoot=Join-Path $root "$build-$variant-$case"
        $spec=[ordered]@{}; foreach ($key in $originalSpec.Keys) { $spec[$key]=$originalSpec[$key] }
        $spec.launchRoot=Join-Path $caseRoot $id
        $script:membershipChecks=[Collections.Generic.List[int]]::new()
        $spec.contractId='nll/phase-d-runner-input/v3'; $spec.jobNonce=[guid]::NewGuid().ToString('N')
        $spec.executionFx=$null; $spec.weaknessCode='iron'
        $spec.clientBuildCode=$build; $spec.staticDataVariantRequired=$variant

        if ($variant) { $spec.variantStaticDataPack=Join-Path $caseRoot 'variant'; $spec.variantStaticDataSha256='a'*64 }
        $runtimeRoot=Join-Path $spec.launchRoot 'runtime'
        $spec.bootstrapRoot=Join-Path $caseRoot 'bootstrap'
        $null=New-Item -ItemType Directory -Path $runtimeRoot,(Join-Path $spec.bootstrapRoot 'artifact')
        $db=Join-Path $runtimeRoot 'db.json'
        [IO.File]::WriteAllText($db,'{"Users":[]}')
        foreach ($binding in @(@{name='EpinelPS.exe';field='serverExeSha256'},@{name='EpinelPS.dll';field='serverDllSha256'})) {
            $path=Join-Path $runtimeRoot $binding.name; [IO.File]::WriteAllText($path,'not executable'); $spec[$binding.field]=Get-PhaseDRunnerHash $path
        }
        $path=Join-Path $spec.bootstrapRoot 'artifact/NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe'
        [IO.File]::WriteAllText($path,'not executable'); $spec.bootstrapSha256=Get-PhaseDRunnerHash $path
        $spec.runtimeDbSha256=Get-PhaseDRunnerHash $db
        Write-TestJson (Get-PhaseDRunnerContextPath) @{contractId='nll/phase3b2-synthetic-runtime-context/v1'; accountId=1;managerId=2}
        $hosts=Get-PhaseDRunnerHostsPath
        [IO.File]::WriteAllText($hosts,"# synthetic`r`n# end NLL Phase3B2 Physical entries",[Text.UTF8Encoding]::new($false))
        $baseHash=Get-PhaseDRunnerHash $hosts
        [IO.File]::WriteAllText($hosts,"# synthetic`r`n127.0.0.1 global-match.nikke-kr.com`r`n# end NLL Phase3B2 Physical entries",[Text.UTF8Encoding]::new($true))
        $script:hostPins=@{base=$baseHash;applied=(Get-PhaseDRunnerHash $hosts)}
        [IO.File]::WriteAllText($hosts,"# synthetic`r`n# end NLL Phase3B2 Physical entries",[Text.UTF8Encoding]::new($false))
        $script:processes=@{}; $script:rules=@{}; $script:captureCalled=$false
        $script:clock=[pscustomobject]@{Elapsed=[TimeSpan]::Zero}
        if ($case -eq 'digest-failure') { $spec.serverDllSha256='0'*64 }
        $failed=$false
        try { Enter-PhaseDRunnerIsolation $spec; $start=Invoke-PhaseDRunnerStart $spec | ConvertFrom-Json } catch { $failed=$true; $errorCode=$_.Exception.Message }
        $shouldFail=$case -in @('digest-failure','listener-failure','bootstrap-failure','network-failure')
        if ($failed -and -not $shouldFail) { throw $errorCode }
        Assert-Test ($failed -eq $shouldFail)
        foreach ($name in $environmentNames) { Assert-Test ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name))) }
        if ($shouldFail) {
            if ($case -eq 'digest-failure') {
                Assert-Test ((Get-PhaseDRunnerHash $hosts) -ceq $baseHash -and $script:rules.Count -eq 2)
                Assert-Test ($script:processes.Count -eq 0)
            }
            Assert-Test ((Get-PhaseDRunnerHash $db) -ceq $spec.runtimeDbSha256)
            if ($case -eq 'digest-failure') {
                Assert-Test ($errorCode -ceq 'phase3b2_epinel_minimal_start_digest_invalid')
                Assert-Test (-not (Test-Path -LiteralPath (Join-Path $spec.launchRoot 'evidence')))
                $count++; continue
            }
            $failurePath=@(Get-ChildItem -LiteralPath $spec.launchRoot -Recurse -Filter run-failure.receipt.json)[0].FullName
            $failure=Get-Content -LiteralPath $failurePath -Raw | ConvertFrom-Json
            Assert-Test (-not $failure.automaticRollbackCompleted -and $failure.recoveryOwnerCode -ceq 'outside_execution_job')
            Assert-Test ($script:processes.Count -gt 0 -and $script:rules.Count -gt 0)
            $journal=Get-Content -LiteralPath (Join-Path $spec.launchRoot 'evidence/active-run.pointer.json') -Raw | ConvertFrom-Json
            Assert-Test ($journal.databaseBeforeSha256 -ceq $spec.runtimeDbSha256 -and
                (Get-PhaseDRunnerHash $hosts) -ceq $script:hostPins.applied)
            $count++; continue
        }
        Assert-Test ($script:rules.Count -eq 2)
 Assert-Test (($script:membershipChecks -join ',') -ceq '901,902,903')
        Assert-Test (-not $start.requiredLocalCatalogPreflightPerformed -and -not $start.officialOutboundFallbackUsed)
        $script:processes.Remove(903) # operator closes the synthetic client
 $script:processes.Clear() # outside Job owner has proven zero before completion entry
        [IO.File]::WriteAllText($db,'{"Users":[],"changed":true}')
        if ($case -eq 'observed-exit') {
            $null=New-Item -ItemType Directory -Path (Join-Path $runtimeRoot 'logs')
            [IO.File]::WriteAllText((Join-Path $runtimeRoot 'logs/app-test.log'),'NLL_BATTLE_RESULT_OBSERVATION/v1 utc=2026-09-08T00:00:00Z sequence=1 route=soloraid_trial_setdamage battleResult=1')
        }
        $failed=$false
        try { $completion=Invoke-PhaseDRunnerComplete $spec | ConvertFrom-Json } catch { $failed=$true; $errorCode=$_.Exception.Message }
        if ($failed -and $case -ne 'capture-failure') { throw $errorCode }
        Assert-Test ($failed -eq ($case -eq 'capture-failure'))
        $pointerPath=Join-Path $spec.launchRoot 'evidence/active-run.pointer.json'
        if ($failed) {
            Assert-Test ($errorCode -ceq 'phase_d_synthetic_capture_failed')
            Assert-Test (Test-Path -LiteralPath $pointerPath)
            Assert-Test (([IO.File]::ReadAllText($db)) -ceq '{"Users":[],"changed":true}')
            Assert-Test ((Get-PhaseDRunnerHash $hosts) -ceq $script:hostPins.applied)
        } else {
            Assert-Test $script:captureCalled
            Assert-Test ((Get-PhaseDRunnerHash $db) -ceq $spec.runtimeDbSha256 -and (Get-PhaseDRunnerHash $hosts) -ceq $baseHash)
            Assert-Test ($script:rules.Count -eq 0 -and -not (Test-Path -LiteralPath $pointerPath))
            Assert-Test ($completion.diagnosticObservationStatus -ceq $(if ($case -eq 'observed-exit') {'observed'} else {'not_observed'}))
            Assert-Test (-not $completion.scoreProjectionVerified -and -not $completion.damageSourceObservationComplete)
        }
        $count++
       }
      }
    }
} finally {
    $env:USERPROFILE=$previousProfile
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name,$previousEnvironment[$name]) }
    $resolved=[IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -notlike 'nll-runner-contract-*') { throw 'unsafe_test_cleanup' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
"Runner behavior: $count full Start/Complete synthetic cases passed; no OS/game/service mutations."
