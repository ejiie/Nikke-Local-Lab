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
function Test-PhaseDRunnerHardlink([string]$Path, [string]$Source, [long]$Length) {
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
    [Nll.PhaseD.RuntimeFileIdentity]::Same($Path, $Source, $Length)
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
    }
    $script:PhaseDVerifiedRunnerBundle
}

function Read-PhaseDRunnerBundle {
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256 = '')
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
        $runtimeCode = @(Get-PhaseDRunnerRuntimeCode $LaunchRoot)
        if ($runtimeCode.Count -eq 0 -or @($manifest.runtimeCode).Count -ne $runtimeCode.Count -or
            @($manifest.runtimeCode.name | Select-Object -Unique).Count -ne $runtimeCode.Count) { throw 'invalid' }
        foreach ($member in $manifest.runtimeCode) {
            if ($member.name -cnotin @($runtimeCode.Name) -or $member.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'invalid' }
            $path = Join-Path (Join-Path $LaunchRoot 'runtime') $member.name
            if ($null -ne $member.PSObject.Properties['hardlinkSource']) {
                if ($member.name -ieq 'EpinelPS.dll' -or
                    -not (Test-PhaseDRunnerHardlink $path $member.hardlinkSource $member.length)) { throw 'invalid' }
            } elseif ((Get-PhaseDRunnerHash $path) -cne $member.sha256) { throw 'invalid' }
        }
        $spec = Get-Content -LiteralPath (Join-Path $root 'runner.input.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if (($version -eq 2) -ne ($spec.contractId -ceq 'nll/phase-d-runner-input/v3')) { throw 'invalid' }
        if ($spec.launchContextUid -cne $context.launchContextUid -or
            [IO.Path]::GetFullPath($spec.launchRoot) -cne $LaunchRoot -or
            [IO.Path]::GetFullPath($spec.runtimeMaterializer) -cne
                [IO.Path]::GetFullPath((Join-Path $LaunchRoot 'runtime/NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'))) { throw 'invalid' }
        if ([IO.Path]::GetFullPath($spec.bossRuntimeVariantProfile) -cne [IO.Path]::GetFullPath((Join-Path $root 'runner.profile.json')) -or
            $spec.bossRuntimeVariantProfileSha256 -cne (Get-PhaseDRunnerHash $spec.bossRuntimeVariantProfile)) { throw 'invalid' }
        [pscustomobject]@{ root=$root; specification=$spec; sha256=$rows[0].sha256 }
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
