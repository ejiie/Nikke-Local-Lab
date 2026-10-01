# Per-execution code closure. No imports, runtime mutations or fallback on read.
function Get-PhaseDRunnerCodeMembers {
    param([ValidateSet(1,2)][int]$Version = 1)
    @('invoke-nll-phase-d-runner.ps1', 'Nll.PhaseDRunnerSeal.ps1',
      'Nll.PhaseDRunnerContract.ps1', 'Nll.PhaseDRunnerOperations.ps1',
      'Nll.PhaseDRunnerStart.ps1', 'Nll.PhaseDRunnerComplete.ps1',
      'watch-nll-phase-d-execution.ps1', 'recover-nll-phase-d-orphaned-execution.ps1',
      'Nll.PhaseDProcessIdentity.ps1', 'Nll.PhaseDProcessHandle.ps1',
      'Nll.PhaseDChildProcess.ps1', 'Nll.PhaseDCompletion.ps1')
    if ($Version -eq 2) { @('Nll.PhaseDJob.ps1','Nll.PhaseDJob.cs','Nll.PhaseDSharedIsolation.ps1','Nll.PhaseDRuntimeBundle.ps1') }
}

function Get-PhaseDRunnerHash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PhaseDRunnerRuntimeCode([string]$LaunchRoot) {
    @(Get-ChildItem -LiteralPath (Join-Path $LaunchRoot 'runtime') -File | Where-Object {
        $_.Extension -in @('.dll','.exe') -or $_.Name -match '\.(deps|runtimeconfig)\.json$'
    } | Sort-Object Name)
}

# Metadata-only identity check. No file contents are read and no shared attributes
# are changed. A replacement copy or symlink cannot use an installed bundle pin.
function Initialize-PhaseDRuntimeFileIdentity {
    if (-not ('Nll.PhaseD.RuntimeFileIdentity' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Nll.PhaseD {
    public static class RuntimeFileIdentity {
        [StructLayout(LayoutKind.Sequential)]
        private struct Info {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint mode, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle file, out Info info);
        private static Info Read(string path) {
            using (var file = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero)) {
                Info info;
                if (file.IsInvalid || !GetFileInformationByHandle(file, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
                return info;
            }
        }
        public static uint LinkCount(string path) { return Read(path).Links; }
        public static bool Same(string path, string source, long length) {
            if (String.Equals(Path.GetFullPath(path), Path.GetFullPath(source), StringComparison.OrdinalIgnoreCase)) return false;
            var a = Read(path); var b = Read(source);
            return (a.Attributes & 0x410) == 0 && (b.Attributes & 0x410) == 0 && a.Links > 1 &&
                a.Volume == b.Volume && a.IndexHigh == b.IndexHigh && a.IndexLow == b.IndexLow &&
                (((long)a.SizeHigh << 32) | a.SizeLow) == length;
        }
    }
}
'@
    }
}
function Get-PhaseDRunnerLinkCount([string]$Path) {
    Initialize-PhaseDRuntimeFileIdentity
    [Nll.PhaseD.RuntimeFileIdentity]::LinkCount($Path)
}
function Test-PhaseDRunnerHardlink([string]$Path, [string]$Source, [long]$Length) {
    Initialize-PhaseDRuntimeFileIdentity
    [Nll.PhaseD.RuntimeFileIdentity]::Same($Path, $Source, $Length)
}

function Assert-PhaseDNativeFxRetirement {
    param([string]$LaunchRoot, [object]$Specification)
    if ($null -eq $Specification.executionFx) { return }
    $root=Join-Path $LaunchRoot 'runtime/execution-fx'
    $manifestPath=Join-Path $root 'manifest.private.json'
    if ((Get-PhaseDRunnerHash $manifestPath) -cne $Specification.executionFx.manifestSha256) { throw 'phase_d_job_fx_manifest_drifted' }
    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.contractId -cne 'nll/common-native-fx-execution/v2') { return }
    $receipt=Get-Content -LiteralPath (Join-Path $root 'retired.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $range=$receipt.rangeReceipt
    $bytes=0L
    foreach ($patch in $manifest.patches) { $bytes += [long]$patch.before.length }
    if ($receipt.contractId -cne 'nll/common-native-fx-retired/v2' -or
        $receipt.manifestSha256 -cne $Specification.executionFx.manifestSha256 -or
        $receipt.terminationReceiptSha256 -cne (Get-PhaseDRunnerHash (Join-Path $LaunchRoot 'job-zero.receipt.json')) -or
        $receipt.actualGameAcceptanceClaimed -ne $false -or
        $range.contractId -cne 'nll/common-native-fx-range-receipt/v2' -or
        $range.validationScope -cne 'patched_ranges' -or $range.state -cne 'restored' -or
        $range.executionUid -cne $Specification.launchContextUid -or
        $range.planSha256 -cne $manifest.rangePlanSha256 -or $range.planSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $bytes -le 0 -or $bytes -gt 67108864 -or $range.selectedBytes -ne $bytes -or
        $range.bytesRead -lt $bytes -or $range.bytesRead -gt (2*$bytes) -or
        $range.bytesWritten -lt 0 -or $range.bytesWritten -gt $bytes) { throw 'phase_d_job_fx_range_retirement_invalid' }
}

function Read-PhaseDRunnerCleanupCheckpoint {
    param([string]$LaunchRoot, [object]$Bundle)
    $path=Join-Path $LaunchRoot 'physical-cleanup.receipt.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $value=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($value.contractId -cne 'nll/phase-d-physical-cleanup/v1' -or $value.launchContextUid -cne $Bundle.specification.launchContextUid -or
        $value.runnerBundleSha256 -cne $Bundle.sha256 -or $value.jobNonce -cne $Bundle.specification.jobNonce -or
        $value.cleanupKind -cnotin @('completion','rollback') -or
        (Test-Path -LiteralPath (Join-Path $LaunchRoot 'evidence/active-run.pointer.json'))) { throw 'phase_d_job_checkpoint_invalid' }
    $pins=@{
        'job-zero.receipt.json'=$value.terminationSha256
    }
    if ($null -ne $value.startIdentitySha256) { $pins['phase-d-child-start.identity.json']=$value.startIdentitySha256 }
    if ($value.cleanupKind -ceq 'completion') {
        if ($value.completionRelativePath -cnotmatch '^evidence/[0-9a-f-]{36}/completion\.receipt\.json$') { throw 'phase_d_job_checkpoint_invalid' }
        $pins['hosts-restoration.receipt.json']=$value.hostsSha256
        $pins[[string]$value.completionRelativePath]=$value.completionSha256
    } else {
        if ($value.runtimeDatabaseSha256 -cne $Bundle.specification.runtimeDbSha256) { throw 'phase_d_job_checkpoint_invalid' }
        $pins['runtime/db.json']=$value.runtimeDatabaseSha256
        $pins['control-center-hosts.before.bin']=$value.hostsBackupSha256
        if ($null -ne $value.archiveRelativePath) {
            if ($value.archiveRelativePath -cnotmatch '^evidence/[0-9a-f-]{36}/active-run\.pointer\.[a-z0-9T.Z-]+\.json$') { throw 'phase_d_job_checkpoint_invalid' }
            $pins[[string]$value.archiveRelativePath]=$value.archiveSha256
        } elseif ($null -ne $value.archiveSha256) { throw 'phase_d_job_checkpoint_invalid' }
    }
    if ($null -ne $Bundle.specification.executionFx) {
        $pins['runtime/execution-fx/manifest.private.json']=$Bundle.specification.executionFx.manifestSha256
        $pins['runtime/execution-fx/retired.json']=$value.fxRetiredSha256
    } elseif ($null -ne $value.fxRetiredSha256) { throw 'phase_d_job_checkpoint_invalid' }
    foreach ($relative in $pins.Keys) {
        if ($pins[$relative] -cnotmatch '^[0-9a-f]{64}$' -or (Get-PhaseDRunnerHash (Join-Path $LaunchRoot $relative)) -cne $pins[$relative]) { throw 'phase_d_job_checkpoint_drifted' }
    }
    Assert-PhaseDNativeFxRetirement $LaunchRoot $Bundle.specification
    # This authorizes PG/pending replay ONLY. It cannot enter a physical cleanup
    # callback, restore hosts/runtime, adopt a lease, or recreate an absent Job.
    $value
}

function Test-PhaseDRunnerTerminalCleanup([string]$LaunchRoot, [object]$Bundle) {
    $path=Join-Path $LaunchRoot 'execution-state.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $state=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.contractId -cne 'nll/phase-d-execution-state/v1' -or
        $state.launchContextUid -cne $Bundle.specification.launchContextUid) { throw 'phase_d_runner_state_invalid' }
    if ($state.statusCode -cnotin @('completed','failed','rolled_back')) { return $false }
    $null -ne (Read-PhaseDRunnerCleanupCheckpoint $LaunchRoot $Bundle)
}

function Remove-PhaseDRunnerHardlinks([string]$LaunchRoot) {
    $bundle=Get-Variable PhaseDVerifiedRunnerBundle -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $bundle -or $null -eq $bundle.PSObject.Properties['runtimeCode']) { return }
    $linked=@($bundle.runtimeCode | Where-Object { $null -ne $_.PSObject.Properties['hardlinkSource'] })
    if ($linked.Count -eq 0) { return }
    if ([IO.Path]::GetFullPath($LaunchRoot) -cne [IO.Path]::GetFullPath($bundle.specification.launchRoot)) { throw 'phase_d_runner_binding_invalid' }
    if (-not (Test-PhaseDRunnerTerminalCleanup $LaunchRoot $bundle)) { return }
    $runtimeRoot=Join-Path $LaunchRoot 'runtime'
    if ((Get-Item -LiteralPath $runtimeRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'phase_d_runner_runtime_path_invalid' }
    foreach ($member in $linked) {
        if ($member.name -cnotmatch '^[A-Za-z0-9_.-]+$') { throw 'phase_d_runner_hardlink_drifted' }
        $path=Join-Path (Join-Path $LaunchRoot 'runtime') $member.name
        if (-not (Test-Path -LiteralPath $path)) { continue } # replay/partial unlink
        if (-not (Test-PhaseDRunnerHardlink $path $member.hardlinkSource $member.length)) { throw 'phase_d_runner_hardlink_drifted' }
        [IO.File]::Delete($path) # no -Force/attribute mutation on the shared file
    }
}

function New-PhaseDRunnerBundle {
    param([object]$Specification, [string]$ScriptsRoot, [hashtable]$RuntimeCodePins = @{})
    Assert-PhaseDRunnerSpecification $Specification
    $root = Join-Path $Specification.launchRoot 'tools/runner'
    if (Test-Path -LiteralPath $root) { throw 'phase_d_runner_bundle_exists' }
    $null = New-Item -ItemType Directory -Path $root
    $members = @()
    $version = 2
    foreach ($name in Get-PhaseDRunnerCodeMembers -Version $version) {
        $source = Join-Path $ScriptsRoot $name
        $hash = Get-PhaseDRunnerHash $source
        Copy-Item -LiteralPath $source -Destination (Join-Path $root $name)
        if ((Get-PhaseDRunnerHash (Join-Path $root $name)) -cne $hash) { throw 'phase_d_runner_copy_drifted' }
        $members += [ordered]@{ name=$name; sha256=$hash }
    }
    $profilePath = Join-Path $root 'runner.profile.json'
    if ((Get-PhaseDRunnerHash $Specification.bossRuntimeVariantProfile) -cne $Specification.bossRuntimeVariantProfileSha256) { throw 'phase_d_runner_profile_drifted' }
    Copy-Item -LiteralPath $Specification.bossRuntimeVariantProfile -Destination $profilePath
    if ((Get-PhaseDRunnerHash $profilePath) -cne $Specification.bossRuntimeVariantProfileSha256) { throw 'phase_d_runner_profile_drifted' }
    $Specification.bossRuntimeVariantProfile = $profilePath
    $members += [ordered]@{ name='runner.profile.json'; sha256=$Specification.bossRuntimeVariantProfileSha256 }
    $inputPath = Join-Path $root 'runner.input.json'
    [IO.File]::WriteAllText($inputPath, (($Specification | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
    $members += [ordered]@{ name='runner.input.json'; sha256=(Get-PhaseDRunnerHash $inputPath) }
    $runtimeCode = @(Get-PhaseDRunnerRuntimeCode $Specification.launchRoot | ForEach-Object {
        if ($RuntimeCodePins.ContainsKey($_.Name)) {
            $pin = $RuntimeCodePins[$_.Name]
            if ($_.Name -ieq 'EpinelPS.dll' -or $pin.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
                -not (Test-PhaseDRunnerHardlink $_.FullName $pin.path $pin.length)) { throw 'phase_d_runner_hardlink_drifted' }
            [ordered]@{ name=$_.Name; sha256=$pin.sha256; hardlinkSource=$pin.path; length=$pin.length }
        } else {
            [ordered]@{ name=$_.Name; sha256=(Get-PhaseDRunnerHash $_.FullName) }
        }
    })
    if ($runtimeCode.Count -eq 0) { throw 'phase_d_runner_runtime_closure_empty' }
    $manifest = [ordered]@{
        schemaVersion=1; contractId=('nll/phase-d-runner-bundle/v' + $version); engineCode='parameterized/v1'
        launchContextUid=$Specification.launchContextUid; members=$members; runtimeCode=$runtimeCode
    }
    $path = Join-Path $root 'runner.bundle.json'
    [IO.File]::WriteAllText($path, (($manifest | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
    $script:PhaseDVerifiedRunnerBundle = [pscustomobject]@{
        root=$root; manifestPath=$path; sha256=(Get-PhaseDRunnerHash $path); specification=$Specification
        runtimeCode=@($runtimeCode | ForEach-Object { [pscustomobject]$_ })
    }
    $script:PhaseDVerifiedRunnerBundle
}

function Read-PhaseDRunnerBundle {
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256 = '', [switch]$AllowRetiredRuntime)
    try {
        $LaunchRoot = [IO.Path]::GetFullPath($LaunchRoot)
        $root = Join-Path $LaunchRoot 'tools/runner'
        $manifestPath = Join-Path $root 'runner.bundle.json'
        # The context already pins tool.manifest.tsv for both engines. A new-engine
        # marker with missing/invalid proof is NOT an old run and cannot fall back.
        $toolPath = Join-Path $LaunchRoot 'tool.manifest.tsv'
        $rows = @(if (Test-Path -LiteralPath $toolPath -PathType Leaf) {
            Import-Csv -LiteralPath $toolPath -Delimiter "`t" | Where-Object { $_.role_code -ceq 'runner_bundle' }
        })
        if (-not (Test-Path -LiteralPath $root) -and $rows.Count -eq 0 -and -not $ExpectedBundleSha256) { return $null }
        $context = Get-Content -LiteralPath (Join-Path $LaunchRoot 'launch-context.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($context.contractId -cne 'nll/launch-context/v1' -or
            $context.launchContextUid -cne [IO.Path]::GetFileName($LaunchRoot) -or
            $context.toolManifestSha256 -cne (Get-PhaseDRunnerHash $toolPath) -or $rows.Count -ne 1 -or
            $rows[0].sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            ($ExpectedBundleSha256 -and $ExpectedBundleSha256 -cne $rows[0].sha256) -or
            (Get-PhaseDRunnerHash $manifestPath) -cne $rows[0].sha256) { throw 'invalid' }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($manifest.schemaVersion -ne 1 -or $manifest.contractId -cnotin @('nll/phase-d-runner-bundle/v1','nll/phase-d-runner-bundle/v2') -or
            $manifest.engineCode -cne 'parameterized/v1' -or $manifest.launchContextUid -cne $context.launchContextUid) { throw 'invalid' }
        $version = if ($manifest.contractId -ceq 'nll/phase-d-runner-bundle/v2') { 2 } else { 1 }
        $expected = @(Get-PhaseDRunnerCodeMembers -Version $version) + @('runner.input.json','runner.profile.json')
        # Older sealed runs carry their own pre-lifecycle Job/reader code. Keep
        # dispatching recovery to that exact closure; never rewrite historical runs.
        if ($version -eq 2 -and 'Nll.PhaseDSharedIsolation.ps1' -cnotin @($manifest.members.name)) {
            $expected = @($expected | Where-Object { $_ -cne 'Nll.PhaseDSharedIsolation.ps1' })
        }
        if ($version -eq 2 -and 'Nll.PhaseDRuntimeBundle.ps1' -cnotin @($manifest.members.name)) {
            $expected = @($expected | Where-Object { $_ -cne 'Nll.PhaseDRuntimeBundle.ps1' })
        }
        if (@($manifest.members).Count -ne $expected.Count -or
            @($manifest.members.name | Select-Object -Unique).Count -ne $expected.Count) { throw 'invalid' }
        foreach ($member in $manifest.members) {
            if ($member.name -cnotin $expected -or $member.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
                (Get-PhaseDRunnerHash (Join-Path $root $member.name)) -cne $member.sha256) { throw 'invalid' }
        }
        $spec = Get-Content -LiteralPath (Join-Path $root 'runner.input.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if (($version -eq 2) -ne ($spec.contractId -ceq 'nll/phase-d-runner-input/v3')) { throw 'invalid' }
        if ($spec.launchContextUid -cne $context.launchContextUid -or
            [IO.Path]::GetFullPath($spec.launchRoot) -cne $LaunchRoot -or
            [IO.Path]::GetFullPath($spec.runtimeMaterializer) -cne
                [IO.Path]::GetFullPath((Join-Path $LaunchRoot 'runtime/NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'))) { throw 'invalid' }
        if ([IO.Path]::GetFullPath($spec.bossRuntimeVariantProfile) -cne [IO.Path]::GetFullPath((Join-Path $root 'runner.profile.json')) -or
            $spec.bossRuntimeVariantProfileSha256 -cne (Get-PhaseDRunnerHash $spec.bossRuntimeVariantProfile)) { throw 'invalid' }
        $bundle=[pscustomobject]@{ root=$root; specification=$spec; sha256=$rows[0].sha256; runtimeCode=$manifest.runtimeCode; runtimeCodeRetired=$false }
        $linked=@($manifest.runtimeCode | Where-Object { $null -ne $_.PSObject.Properties['hardlinkSource'] })
        $retired=$AllowRetiredRuntime -and $linked.Count -gt 0 -and (Test-PhaseDRunnerTerminalCleanup $LaunchRoot $bundle)
        $runtimeCode = @(Get-PhaseDRunnerRuntimeCode $LaunchRoot)
        if ($runtimeCode.Count -eq 0 -or @($manifest.runtimeCode.name | Select-Object -Unique).Count -ne @($manifest.runtimeCode).Count -or
            @($runtimeCode | Where-Object { $_.Name -cnotin @($manifest.runtimeCode.name) }).Count -gt 0) { throw 'invalid' }
        foreach ($member in $manifest.runtimeCode) {
            if ($member.name -cnotmatch '^[A-Za-z0-9_.-]+$' -or $member.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'invalid' }
            $path = Join-Path (Join-Path $LaunchRoot 'runtime') $member.name
            if ($null -ne $member.PSObject.Properties['hardlinkSource']) {
                if ($member.name -ieq 'EpinelPS.dll') { throw 'invalid' }
                if ($retired -and -not (Test-Path -LiteralPath $path)) { continue }
                if ($member.name -cnotin @($runtimeCode.Name) -or
                    -not (Test-PhaseDRunnerHardlink $path $member.hardlinkSource $member.length)) { throw 'invalid' }
            } elseif ($member.name -cnotin @($runtimeCode.Name) -or (Get-PhaseDRunnerHash $path) -cne $member.sha256) { throw 'invalid' }
        }
        $bundle.runtimeCodeRetired=$retired
        $bundle
    } catch { throw 'phase_d_runner_bundle_invalid' }
}

function Assert-PhaseDRunnerStartDependencies {
    param([object]$Specification)
    $pins = @(
        @{path=$Specification.bossRuntimeVariantProfile; hash=$Specification.bossRuntimeVariantProfileSha256},
        @{path=(Join-Path $Specification.launchRoot 'source.manifest.tsv'); hash=$Specification.derivedSourceManifestSha256}
    )
    if ($Specification.staticDataVariantRequired) {
        $pins += @{path=$Specification.variantStaticDataPack; hash=$Specification.variantStaticDataSha256}
    }

    foreach ($pin in $pins) {
        if ((Get-PhaseDRunnerHash $pin.path) -cne $pin.hash) { throw 'phase_d_runner_dependency_drifted' }
    }

}
