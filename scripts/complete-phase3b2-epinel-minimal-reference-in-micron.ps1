param(
    [ValidateSet(
        'startup_only', 'server_selection', 'catalogue_path', 'lobby',
        'solo_raid_menu', 'season26_challenge_battle', 'battle_result'
    )]
    [string]$ObservedStageCode = 'startup_only',
    [ValidateSet('success', 'system_error', 'operator_abort', 'client_exit')]
    [string]$OutcomeCode = 'client_exit',
    [string]$ServerRoot =
        'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64',
    [string]$EvidenceRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1'
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

function Get-PinnedProcess {
    param([int]$ProcessId, [string]$ExpectedName)
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process -or $process.ProcessName -cne $ExpectedName) {
        return $null
    }
    $process
}

function Stop-PinnedProcess {
    param([int]$ProcessId, [string]$ExpectedName)
    $process = Get-PinnedProcess $ProcessId $ExpectedName
    if ($null -eq $process) { return $false }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        if ($null -eq (Get-PinnedProcess $ProcessId $ExpectedName)) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText(
        $temporary, $Text, [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $Path
}

$expectedDbSha256 = `
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
$expectedBaseHostsSha256 = `
    'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
$expectedAppliedHostsSha256 = `
    '3b0dcc4396373e9e9d623ef05c345f89330427ad5128727290c9f76138e22f64'
$extensionFirewallGroup = 'NLL Phase3B2 Epinel Minimal Extension'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True (
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
) 'phase3b2_epinel_minimal_completion_requires_administrator'
Assert-True ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'nlloperator') `
    'phase3b2_epinel_minimal_completion_wrong_operator_or_boot_boundary'

$activePointerPath = Join-Path $EvidenceRoot 'active-run.pointer.json'
Assert-True (Test-Path -LiteralPath $activePointerPath -PathType Leaf) `
    'phase3b2_epinel_minimal_completion_pointer_missing'
$pointer = Get-Content -LiteralPath $activePointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $pointer.contractId -ceq `
        'nll/phase3b2-epinel-minimal-active-run-pointer/v1' -and
    [Guid]::Parse([string]$pointer.assessmentUid) -ne [Guid]::Empty
) 'phase3b2_epinel_minimal_completion_pointer_invalid'

$runRoot = [string]$pointer.runRoot
$runStartPath = Join-Path $runRoot 'run-start.receipt.json'
$completionPath = Join-Path $runRoot 'completion.receipt.json'
$dbBeforePath = Join-Path $runRoot 'db.before.bin'
$hostsBeforePath = Join-Path $runRoot 'hosts.before.bin'
$stdoutPath = Join-Path $runRoot 'server.stdout.log'
$stderrPath = Join-Path $runRoot 'server.stderr.log'
$dbPath = Join-Path $ServerRoot 'db.json'
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'

Assert-True (
    @($runStartPath, $dbBeforePath, $hostsBeforePath |
        Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }
    ).Count -eq 0 -and
    -not (Test-Path -LiteralPath $completionPath) -and
    (Get-Sha256Hex $runStartPath) -ceq `
        ([string]$pointer.runStartReceiptSha256) -and
    (Get-Sha256Hex $dbBeforePath) -ceq $expectedDbSha256 -and
    (Get-Sha256Hex $hostsBeforePath) -ceq $expectedBaseHostsSha256 -and
    (Get-Sha256Hex $hostsPath) -ceq $expectedAppliedHostsSha256
) 'phase3b2_epinel_minimal_completion_evidence_or_hosts_invalid'

$clientId = [int]$pointer.clientProcessId
$bootstrapId = [int]$pointer.bootstrapProcessId
$serverId = [int]$pointer.serverProcessId
Assert-True ($null -eq (Get-PinnedProcess $clientId 'nikke')) `
    'phase3b2_epinel_minimal_completion_client_still_running_close_game_first'

$bootstrapForcedStop = $false
for ($attempt = 0; $attempt -lt 40; $attempt++) {
    if ($null -eq (Get-PinnedProcess $bootstrapId `
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap')) { break }
    Start-Sleep -Milliseconds 250
}
if ($null -ne (Get-PinnedProcess $bootstrapId `
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap')) {
    $bootstrapForcedStop = Stop-PinnedProcess $bootstrapId `
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
}
$serverForcedStop = Stop-PinnedProcess $serverId 'EpinelPS'
Assert-True (
    $null -eq (Get-PinnedProcess $bootstrapId `
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap') -and
    $null -eq (Get-PinnedProcess $serverId 'EpinelPS')
) 'phase3b2_epinel_minimal_completion_runtime_stop_failed'

$databaseAfterByteLength = (Get-Item -LiteralPath $dbPath).Length
$databaseAfterSha256 = Get-Sha256Hex $dbPath
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
    ForEach-Object { Join-Path $ServerRoot $_ })
$sqliteObservedCount = @($sqlitePaths | Where-Object {
    Test-Path -LiteralPath $_ -PathType Leaf
}).Count

[IO.File]::WriteAllBytes($dbPath, [IO.File]::ReadAllBytes($dbBeforePath))
foreach ($path in $sqlitePaths) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}
[IO.File]::WriteAllBytes(
    $hostsPath, [IO.File]::ReadAllBytes($hostsBeforePath)
)
Get-NetFirewallRule -Group $extensionFirewallGroup `
    -ErrorAction SilentlyContinue | Remove-NetFirewallRule

Assert-True (
    (Get-Sha256Hex $dbPath) -ceq $expectedDbSha256 -and
    @($sqlitePaths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0 -and
    (Get-Sha256Hex $hostsPath) -ceq $expectedBaseHostsSha256 -and
    @(Get-NetFirewallRule -Group $extensionFirewallGroup `
        -ErrorAction SilentlyContinue).Count -eq 0
) 'phase3b2_epinel_minimal_completion_rollback_verification_failed'

$stdoutLength = if (Test-Path -LiteralPath $stdoutPath) {
    (Get-Item -LiteralPath $stdoutPath).Length
} else { 0L }
$stdoutSha256 = if ($stdoutLength -ge 0 -and
    (Test-Path -LiteralPath $stdoutPath)) {
    Get-Sha256Hex $stdoutPath
} else { '' }
$stderrLength = if (Test-Path -LiteralPath $stderrPath) {
    (Get-Item -LiteralPath $stderrPath).Length
} else { 0L }
$stderrSha256 = if ($stderrLength -ge 0 -and
    (Test-Path -LiteralPath $stderrPath)) {
    Get-Sha256Hex $stderrPath
} else { '' }

$playerLogPath = Join-Path $env:USERPROFILE `
    'AppData\LocalLow\com.proximabeta\NIKKE\Player.log'
$playerLogPresent = Test-Path -LiteralPath $playerLogPath -PathType Leaf
$playerLogLength = if ($playerLogPresent) {
    (Get-Item -LiteralPath $playerLogPath).Length
} else { 0L }
$playerLogSha256 = if ($playerLogPresent) {
    Get-Sha256Hex $playerLogPath
} else { '' }

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-minimal-reference-completion/v1'
    completedAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    assessmentUid = [string]$pointer.assessmentUid
    runStartReceiptSha256 = [string]$pointer.runStartReceiptSha256
    observedStageCode = $ObservedStageCode
    outcomeCode = $OutcomeCode
    databaseAfterByteLength = $databaseAfterByteLength
    databaseAfterSha256 = $databaseAfterSha256
    databaseRestored = $true
    sqliteRuntimeObservedMemberCount = $sqliteObservedCount
    sqliteRuntimeRemoved = $true
    hostsRestored = $true
    extensionFirewallRemoved = $true
    clientClosedByOperator = $true
    bootstrapForcedStop = $bootstrapForcedStop
    serverForcedStop = $serverForcedStop
    serverStdoutByteLength = $stdoutLength
    serverStdoutSha256 = $stdoutSha256
    serverStderrByteLength = $stderrLength
    serverStderrSha256 = $stderrSha256
    playerLogPresent = $playerLogPresent
    playerLogByteLength = $playerLogLength
    playerLogSha256 = $playerLogSha256
    rawPlayerLogCopied = $false
    officialLauncherExecutionStarted = $false
    officialOutboundFallbackUsed = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $true
    clientExecutionStarted = $true
    runtimeColdAfterCompletion = $true
    nextStepCode = if ($ObservedStageCode -eq 'battle_result' -and
        $OutcomeCode -eq 'success') {
        'return_to_samsung_and_seal_actual_play_evidence'
    } else {
        'return_to_samsung_classify_without_automatic_retry'
    }
}
Write-AtomicUtf8NoBom $completionPath `
    (($receipt | ConvertTo-Json -Depth 6) + "`n")
$archivedPointerPath = Join-Path $runRoot 'active-run.pointer.archived.json'
Move-Item -LiteralPath $activePointerPath -Destination $archivedPointerPath

$receipt | ConvertTo-Json -Depth 6
