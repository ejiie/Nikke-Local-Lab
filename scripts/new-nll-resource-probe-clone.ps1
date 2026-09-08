[CmdletBinding()]
param(
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$Build = '151.8.5',
    [ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedExecutableSha256,
    [ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedAssemblySha256,
    [ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedPlanSha256,
    [switch]$ExecuteApprovedClone
)

# Staging only: no bootstrap, process termination, preferences, hosts, CA, DB or
# network changes. Runtime admission is a separate gate, never this exit code.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-NllClone([bool]$Condition, [string]$Code) {
    if (-not $Condition) { throw ('resource_clone_' + $Code) }
}

function Assert-NllCloneNoReparse([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            Assert-NllClone (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'reparse_rejected'
        }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Get-NllCloneFiles([string]$Root) {
    Assert-NllCloneNoReparse $Root
    Assert-NllClone (Test-Path -LiteralPath $Root -PathType Container) 'source_missing'
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push([IO.Path]::GetFullPath($Root))
    while ($pending.Count -gt 0) {
        foreach ($entry in [IO.DirectoryInfo]::new($pending.Pop()).EnumerateFileSystemInfos()) {
            Assert-NllClone (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'reparse_rejected'
            if ($entry -is [IO.DirectoryInfo]) { $pending.Push($entry.FullName) }
            elseif ($entry.Extension -notin @('.log', '.dmp')) { $entry }
        }
    }
}

function Get-NllCloneSha256([string]$Path) {
    $input = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($input)).ToLowerInvariant() }
    finally { $input.Dispose() }
}

function Get-NllClonePlan([string]$SourceRoot, [string]$ClientBuild) {
    $members = [Collections.Generic.List[object]]::new()
    # Do not copy launcher data, official identities, old .lcv.dat, preferences,
    # logs, dump files, or the obsolete pre-151 cache. No hardlinks/junctions.
    foreach ($relativeRoot in @('NIKKE/game', 'Unity/com_proximabeta_NIKKE/com.shiftup.patch')) {
        $root = Join-Path $SourceRoot $relativeRoot
        foreach ($file in @(Get-NllCloneFiles $root)) {
            $relative = [IO.Path]::GetRelativePath($SourceRoot, $file.FullName).Replace('\', '/')
            Assert-NllClone (-not $relative.StartsWith('../') -and $relative -notmatch '[\t\r\n]') 'relative_path_invalid'
            $members.Add([pscustomobject][ordered]@{ relativePath = $relative; byteLength = $file.Length
                sha256 = Get-NllCloneSha256 $file.FullName })
        }
    }
    Assert-NllClone ($members.Count -gt 0) 'source_empty'
    $members.Sort([Comparison[object]]{ param($left, $right)
        [StringComparer]::Ordinal.Compare($left.relativePath, $right.relativePath) })
    $sorted = $members.ToArray()
    $canonical = $ClientBuild + "`n" + (($sorted | ForEach-Object {
        $_.relativePath + "`t" + $_.byteLength + "`t" + $_.sha256
    }) -join "`n") + "`n"
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
    [pscustomobject]@{ build = $ClientBuild; members = $sorted; planSha256 = $digest
        fileCount = $sorted.Count; byteLength = [long](($sorted | Measure-Object byteLength -Sum).Sum) }
}

function Assert-NllCloneCold {
    $active = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^(nikke|nikke_launcher|EpinelPS|NikkeLocalLab\..*Bootstrap)\.exe$' -or
        ($_.Name -eq 'dotnet.exe' -and $_.CommandLine -match 'EpinelPS')
    })
    Assert-NllClone ($active.Count -eq 0) 'runtime_not_cold'
}

function Write-NllCloneNewJson([string]$Path, [object]$Value) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 8) + "`n")
    $output = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $output.Write($bytes); $output.Flush($true) }
    finally { $output.Dispose() }
}

# Import only the pure/read-only helpers for synthetic tests.
if ($MyInvocation.InvocationName -eq '.') { return }
Assert-NllClone ($PSVersionTable.PSVersion.Major -ge 7) 'powershell7_required'
$sourceRoot = 'C:\NIKKE'
$destinationRoot = 'C:\NLL\Clients\NIKKE-' + $Build + '-ResourceProbe'
Assert-NllCloneNoReparse $sourceRoot
Assert-NllCloneNoReparse $destinationRoot
Assert-NllClone (-not (Test-Path -LiteralPath $destinationRoot)) 'destination_exists'
Assert-NllCloneCold
$exe = Join-Path $sourceRoot 'NIKKE\game\nikke.exe'
# PE ProductVersion is the Unity engine version, not the NIKKE build. The Build
# value is a requested candidate label, not native build/version-binding proof.
Assert-NllClone (-not [string]::IsNullOrEmpty($ExpectedExecutableSha256) -and
    -not [string]::IsNullOrEmpty($ExpectedAssemblySha256)) 'binary_pins_required'
Assert-NllClone ((Get-NllCloneSha256 $exe) -ceq $ExpectedExecutableSha256 -and
    (Get-NllCloneSha256 (Join-Path $sourceRoot 'NIKKE\game\GameAssembly.dll')) -ceq
        $ExpectedAssemblySha256) 'binary_pin_mismatch'
$plan = Get-NllClonePlan $sourceRoot $Build
Assert-NllCloneCold
if (-not $ExecuteApprovedClone) {
    [ordered]@{ status = 'plan_only_no_writes'; build = $Build; planSha256 = $plan.planSha256
        fileCount = $plan.fileCount; byteLength = $plan.byteLength
        destinationRoot = $destinationRoot; buildLabelAuthority = 'operator_requested_candidate'
        nativeBuildBindingVerified = $false; nativeAdmission = 'not_evaluated' } | ConvertTo-Json
    return
}
Assert-NllClone (-not [string]::IsNullOrEmpty($ExpectedPlanSha256) -and
    $ExpectedPlanSha256 -ceq $plan.planSha256) 'plan_drift'
Assert-NllClone ((Get-PSDrive -Name C).Free -gt $plan.byteLength + 10GB) 'insufficient_free_space'
Assert-NllCloneNoReparse 'C:\NLL\Staging\ResourceProbeClones'
$assessment = Join-Path 'C:\NLL\Staging\ResourceProbeClones' ([Guid]::NewGuid().ToString('D'))
New-Item -ItemType Directory -Path $assessment | Out-Null
Write-NllCloneNewJson (Join-Path $assessment 'source.private.json') $plan
Write-NllCloneNewJson (Join-Path $assessment 'rollback.private.json') ([ordered]@{
    destinationRoot = $destinationRoot; sourceRoot = $sourceRoot
    rollback = 'quarantine_only_this_new_clone_after_explicit_target_validation'
    sourceMutation = 'none'; runtimeMutation = 'none'; noAutomaticDeletion = $true
})
New-Item -ItemType Directory -Path $destinationRoot | Out-Null
$done = 0
try {
    foreach ($member in $plan.members) {
        $source = Join-Path $sourceRoot $member.relativePath
        $target = [IO.Path]::GetFullPath((Join-Path $destinationRoot $member.relativePath))
        Assert-NllClone ($target.StartsWith($destinationRoot + '\', [StringComparison]::OrdinalIgnoreCase)) 'target_boundary'
        Assert-NllCloneNoReparse $source
        Assert-NllCloneNoReparse $target
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $input = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            Assert-NllClone ($input.Length -eq $member.byteLength -and
                [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($input)).ToLowerInvariant() -ceq $member.sha256) 'source_drift'
            $input.Position = 0
            $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $input.CopyTo($output, 1048576); $output.Flush($true) }
            finally { $output.Dispose() }
            Assert-NllClone ((Get-NllCloneSha256 $target) -ceq $member.sha256) 'copy_digest_mismatch'
        }
        finally { $input.Dispose() }
        $done++
        if ($done % 250 -eq 0) { Write-Host ('resource_clone_copy_progress: {0}/{1}' -f $done, $plan.fileCount) }
    }
    Assert-NllCloneCold
    $after = Get-NllClonePlan $sourceRoot $Build
    $copy = Get-NllClonePlan $destinationRoot $Build
    Assert-NllClone ($after.planSha256 -ceq $plan.planSha256 -and $copy.planSha256 -ceq $plan.planSha256) 'final_manifest_mismatch'
    $receipt = [ordered]@{ contractId = 'nll/resource-probe-clone/v1'; status = 'sealed_offline_clone'
        planSha256 = $plan.planSha256; build = $Build; fileCount = $done; byteLength = $plan.byteLength
        sourceUnchanged = $true; nativeAdmission = 'not_evaluated'; clientStarted = $false }
    Write-NllCloneNewJson (Join-Path $assessment 'clone.receipt.json') $receipt
    $receipt | ConvertTo-Json
}
catch {
    Write-NllCloneNewJson (Join-Path $assessment 'failure.receipt.json') ([ordered]@{
        status = 'incomplete_not_admitted'; copiedFileCount = $done; automaticCleanupPerformed = $false
        nativeAdmission = 'blocked'; failureCode = 'resource_clone_failed'
    })
    throw 'resource_clone_failed_partial_preserved'
}
