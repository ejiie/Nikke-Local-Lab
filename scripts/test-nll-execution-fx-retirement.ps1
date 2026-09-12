[CmdletBinding()]
param([string]$AutomationAssemblyPath = '', [string]$MaterializerPath = '')
# Actual Windows Job API and synthetic private FX only; never a game, DB or installed path.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($PSVersionTable.PSEdition -ne 'Core' -or -not $IsWindows) { throw 'fx_retirement_test_windows_pwsh_required' }
$repository = Split-Path -Parent $PSScriptRoot
if (-not $AutomationAssemblyPath) {
    $AutomationAssemblyPath = Join-Path $repository 'src/NikkeLocalLab.Automation/bin/Release/net8.0/NikkeLocalLab.Automation.dll'
}
Add-Type -Path $AutomationAssemblyPath
. (Join-Path $PSScriptRoot 'Nll.PhaseDJob.ps1')
Initialize-PhaseDJobType
function Hash($Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Json($Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false)) }
function Check($Value) { if (-not $Value) { throw 'fx_retirement_test_assertion_failed' } }
function Pin($Path) { @{ sha256=(Hash $Path); byteLength=(Get-Item -LiteralPath $Path).Length } }
function Invoke-Retirement {
    if ($MaterializerPath) {
        & $MaterializerPath --retire-execution-fx true --launch-root $launch --expected-bundle-sha256 $bundleSha --expected-termination-sha256 $proofSha | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'fx_retirement_cli_rejected' }
    } else { [NikkeLocalLab.Automation.ExecutionAssetRetirement]::Retire($launch, $bundleSha, $proofSha) }
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('nll-fx-retirement-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$passed = 0
try {
    foreach ($scenario in @('live','absent','closed','valid','code_drift','receipt_drift','binding_drift','foreign','lease_drift')) {
        $id = [guid]::NewGuid().ToString('D')
        $nonce = [guid]::NewGuid().ToString('N')
        $launch = Join-Path $root $id
        $runtime = Join-Path $launch 'runtime'
        $runner = Join-Path $launch 'tools/runner'
        $fxRoot = Join-Path $runtime 'execution-fx'
        $null = New-Item -ItemType Directory -Path $fxRoot, $runner
        $original = Join-Path $fxRoot 'original.bundle'
        $overlay = Join-Path $fxRoot 'overlay.bundle'
        [IO.File]::WriteAllText($original, 'synthetic original')
        [IO.File]::WriteAllText($overlay, 'synthetic derived')
        [IO.File]::WriteAllBytes((Join-Path $fxRoot '.lease'), [byte[]]@())
        $fxManifest = Join-Path $fxRoot 'manifest.private.json'
        Json $fxManifest @{schemaVersion=1; contractId='nll/execution-fx-delivery/v1'; executionCode=$id.Replace('-','');
            candidateSealSha256=('a'*64); profileSha256=('b'*64); weaknessCode='water'; bossElementCode='fire';
            requestPath='/PC/synthetic/fx.bundle'; original=(Pin $original); overlay=(Pin $overlay); runtimeAdmissionStatusCode='not_assessed'}
        $spec = @{contractId='nll/phase-d-runner-input/v3'; launchRoot=$launch; launchContextUid=$id; jobNonce=$nonce;
            weaknessCode='water'; bossRuntimeVariantProfileSha256=('b'*64);
            executionFx=@{manifestSha256=(Hash $fxManifest); candidateSealSha256=('a'*64); profileSha256=('b'*64); weaknessCode='water'}}
        Json (Join-Path $runner 'runner.input.json') $spec
        # Self-authored closure fixture: these files are NEVER executed.
        foreach ($name in @('Nll.PhaseDJob.cs','Nll.PhaseDJob.ps1')) { [IO.File]::WriteAllText((Join-Path $runner $name), 'synthetic code pin') }
        [IO.File]::WriteAllText((Join-Path $runtime 'synthetic.dll'), 'synthetic not executable')
        $members = @(Get-ChildItem -LiteralPath $runner -File | ForEach-Object { @{name=$_.Name; sha256=(Hash $_.FullName)} })
        $bundlePath = Join-Path $runner 'runner.bundle.json'
        Json $bundlePath @{contractId='nll/phase-d-runner-bundle/v2'; engineCode='parameterized/v1'; launchContextUid=$id;
            members=$members; runtimeCode=@(@{name='synthetic.dll'; sha256=(Hash (Join-Path $runtime 'synthetic.dll'))})}
        $bundleSha = Hash $bundlePath
        $proofPath = Join-Path $launch 'job-zero.receipt.json'
        Json $proofPath @{contractId='nll/phase-d-job-zero/v1'; launchContextUid=$id; runnerBundleSha256=$bundleSha;
            jobNonce=$nonce; activeProcesses=0; runtimeRoot=$runtime}
        $proofSha = Hash $proofPath
        $job = $null
        $child = $null
        try {
            if ($scenario -ne 'absent') {
                $job = [Nll.PhaseD.ExecutionJob]::Create('Local\NLL.PhaseD.' + $nonce)
                $child = $job.Start((Join-Path $PSHOME 'pwsh.exe'), '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"')
                Check ($job.Contains($child.Id))
                if ($scenario -ne 'live') { $job.TerminateAndWait(10000) }
                if ($scenario -eq 'closed') { $job.Dispose(); $job=$null }
            }
            switch ($scenario) {
                'code_drift' { [IO.File]::WriteAllText((Join-Path $runner 'Nll.PhaseDJob.cs'), 'drift') }
                'receipt_drift' { [IO.File]::WriteAllText($proofPath, 'drift') }
                'binding_drift' {
                    $proof = Get-Content -LiteralPath $proofPath -Raw | ConvertFrom-Json
                    $proof.launchContextUid=[guid]::NewGuid().ToString('D'); Json $proofPath $proof; $proofSha=Hash $proofPath
                }
                'foreign' { [IO.File]::WriteAllText((Join-Path $fxRoot 'foreign.txt'), 'retain') }
                'lease_drift' { [IO.File]::WriteAllText((Join-Path $fxRoot '.lease'), 'foreign') }
            }
            $rejected = $false
            try { Invoke-Retirement } catch { $rejected=$true }
            if ($scenario -eq 'valid') {
                Check (-not $rejected)
                Invoke-Retirement # Immutable receipt permits exact idempotent retry.
                Check (-not (Test-Path -LiteralPath $overlay) -and (Test-Path -LiteralPath (Join-Path $fxRoot 'retired.json')))
            } else {
                Check $rejected
                Check ((Test-Path -LiteralPath $original) -and (Test-Path -LiteralPath $overlay) -and (Test-Path -LiteralPath (Join-Path $fxRoot '.lease')))
                Check (-not (Test-Path -LiteralPath (Join-Path $fxRoot '.retiring')))
            }
            $passed++
        } finally {
            if ($null -ne $job) { $job.TerminateAndWait(10000); $job.Dispose() }
            if ($null -ne $child) { Check ($child.WaitForExit(10000)); $child.Dispose() }
        }
    }
} finally {
    $full = [IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($full).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($full) -notlike 'nll-fx-retirement-*') { throw 'unsafe_test_cleanup' }
    Remove-Item -LiteralPath $full -Recurse -Force
}
"Execution FX retirement: $passed actual Windows Job/closure/lease checks passed; synthetic private copies only."
