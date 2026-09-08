[CmdletBinding()]
param(
    [string]$EpinelRoot = 'C:\NLL\EpinelPS',
    [string]$RuntimeRoot = 'C:\NLL\Runtime\PhysicalBootstrap-v1',
    [string]$P2EvidenceRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\p2-client-start-v1',
    [string]$SamsungProtectedRoot =
        'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\Runs'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-PathDigest {
    param([string]$Path, [long]$ByteLength, [string]$Sha256)
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporaryPath, $Text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-ExactExecutableProcesses {
    param([string]$ExecutablePath)
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath.Equals(
                $ExecutablePath, [StringComparison]::OrdinalIgnoreCase)
        })
}

function Stop-ExactExecutableProcesses {
    param([string]$ExecutablePath, [switch]$TryGraceful)
    $members = @(Get-ExactExecutableProcesses $ExecutablePath)
    if ($TryGraceful) {
        foreach ($member in $members) {
            $process = Get-Process -Id ([int]$member.ProcessId) `
                -ErrorAction SilentlyContinue
            if ($null -ne $process -and $process.MainWindowHandle -ne 0) {
                $null = $process.CloseMainWindow()
            }
        }
        if ($members.Count -gt 0) { Start-Sleep -Seconds 10 }
    }
    foreach ($member in @(Get-ExactExecutableProcesses $ExecutablePath)) {
        Stop-Process -Id ([int]$member.ProcessId) -Force `
            -ErrorAction SilentlyContinue
    }
}

function Get-PinnedProcess {
    param([int]$ProcessId, [string]$ExpectedName)
    if ($ProcessId -le 0) { return $null }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process -or
        $process.ProcessName -cne $ExpectedName) { return $null }
    return $process
}

function Stop-PinnedProcess {
    param([int]$ProcessId, [string]$ExpectedName, [switch]$TryGraceful)
    $process = Get-PinnedProcess $ProcessId $ExpectedName
    if ($null -eq $process) { return }
    if ($TryGraceful -and $process.MainWindowHandle -ne 0) {
        $null = $process.CloseMainWindow()
        Start-Sleep -Seconds 10
    }
    $process = Get-PinnedProcess $ProcessId $ExpectedName
    if ($null -ne $process) {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_physical_p2_complete_requires_administrator'
Assert-True ((Get-Partition -DriveLetter C | Get-Disk).FriendlyName -ceq
    'Micron_2200_MTFDHBA512TCK') `
    'phase3b2_physical_p2_complete_must_run_from_micron'
Assert-True ((Get-Partition -DriveLetter E | Get-Disk).FriendlyName -ceq
    'Samsung SSD 980 1TB') `
    'phase3b2_physical_p2_complete_samsung_volume_missing'

$activePointerPath = Join-Path $P2EvidenceRoot 'active-run.pointer.json'
Assert-True (Test-Path -LiteralPath $activePointerPath -PathType Leaf) `
    'phase3b2_physical_p2_active_pointer_missing'
$active = Get-Content -LiteralPath $activePointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$parsedAssessmentUid = [Guid]::Empty
Assert-True ($active.contractId -ceq
        'nll/phase3b2-physical-p2-active-run-pointer/v1' -and
    [Guid]::TryParse([string]$active.assessmentUid,
        [ref]$parsedAssessmentUid) -and
    $active.serverRunning -and $active.clientExecutionStarted -and
    [int]$active.clientProcessId -gt 0) `
    'phase3b2_physical_p2_active_pointer_invalid'

$assessmentUid = [string]$active.assessmentUid
$runRoot = Join-Path $P2EvidenceRoot $assessmentUid
$protectedRunRoot = Join-Path $SamsungProtectedRoot $assessmentUid
$runStartPath = Join-Path $runRoot 'run-start.receipt.json'
$databaseBeforePath = Join-Path $runRoot 'db.before.bin'
$databaseAfterPath = Join-Path $runRoot 'db.after-run.bin'
$sqliteObservationPath = Join-Path $runRoot 'sqlite-after-run.json'
$completionPath = Join-Path $runRoot 'run-completion.receipt.json'
$latestCompletionPath = Join-Path $P2EvidenceRoot `
    'latest-completion.pointer.json'
Assert-True ((Test-Path -LiteralPath $runStartPath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $completionPath) -and
    (Test-Path -LiteralPath $protectedRunRoot -PathType Container)) `
    'phase3b2_physical_p2_completion_evidence_shape_invalid'
$runStart = Get-Content -LiteralPath $runStartPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($runStart.contractId -ceq
        'nll/phase3b2-physical-p2-client-start/v1' -and
    $runStart.assessmentUid -ceq $assessmentUid -and
    $runStart.sailNamedPipeConnected -and
    $runStart.clientExecutionStarted -and
    -not $runStart.officialLauncherExecutionStarted) `
    'phase3b2_physical_p2_run_start_receipt_invalid'
Assert-True (Test-PathDigest $databaseBeforePath 413327L `
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194') `
    'phase3b2_physical_p2_database_backup_invalid'

$serverRoot = Join-Path $EpinelRoot 'EpinelPS\bin\Release\net10.0\win-x64'
$serverPath = Join-Path $serverRoot 'EpinelPS.exe'
$dbPath = Join-Path $serverRoot 'db.json'
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal') |
    ForEach-Object { Join-Path $serverRoot $_ }
$bootstrapPath = Join-Path $RuntimeRoot `
    'artifact\NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe'
$clientPath =
    'C:\NLL\Clients\NIKKE-150.6.9-Physical\NIKKE\game\nikke.exe'
$contextPath =
    'C:\NLL\Evidence\Phase3B2\Physical\server-profile-v1\identity\synthetic-context.json'

$observedProcessIds = @(
    [int]$active.serverProcessId,
    [int]$active.bootstrapProcessId,
    [int]$active.clientProcessId
)
$connectionsBeforeStop = @(Get-NetTCPConnection -ErrorAction SilentlyContinue |
    Where-Object OwningProcess -In $observedProcessIds)
$successfulNonLoopback = @($connectionsBeforeStop | Where-Object {
    $_.State -eq 'Established' -and $_.RemoteAddress -and
    $_.RemoteAddress -notin @('0.0.0.0', '127.0.0.1', '::', '::1')
})
$clientWasRunning = $null -ne (Get-PinnedProcess `
    ([int]$active.clientProcessId) 'nikke')
$bootstrapWasRunning = $null -ne (Get-PinnedProcess `
    ([int]$active.bootstrapProcessId) `
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap')
$serverWasRunning = $null -ne (Get-PinnedProcess `
    ([int]$active.serverProcessId) 'EpinelPS')
$officialLauncherRunning = @(Get-Process -Name nikke_launcher `
    -ErrorAction SilentlyContinue).Count -gt 0

# Runtime shutdown is intentionally completed before any verdict assertion.
Stop-PinnedProcess ([int]$active.clientProcessId) 'nikke' -TryGraceful
for ($attempt = 0; $attempt -lt 40; $attempt++) {
    if (Test-Path -LiteralPath (Join-Path $runRoot `
            'bootstrap-exit.receipt.json') -PathType Leaf) { break }
    if ($null -eq (Get-PinnedProcess ([int]$active.bootstrapProcessId) `
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap')) { break }
    Start-Sleep -Milliseconds 250
}
Stop-PinnedProcess ([int]$active.bootstrapProcessId) `
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
Stop-PinnedProcess ([int]$active.serverProcessId) 'EpinelPS'
Stop-ExactExecutableProcesses $clientPath
Stop-ExactExecutableProcesses $bootstrapPath
Stop-ExactExecutableProcesses $serverPath
Start-Sleep -Milliseconds 750

Assert-True ($null -eq (Get-PinnedProcess `
        ([int]$active.clientProcessId) 'nikke') -and
    $null -eq (Get-PinnedProcess ([int]$active.bootstrapProcessId) `
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap') -and
    $null -eq (Get-PinnedProcess `
        ([int]$active.serverProcessId) 'EpinelPS')) `
    'phase3b2_physical_p2_runtime_stop_failed'

Assert-True (Test-Path -LiteralPath $dbPath -PathType Leaf) `
    'phase3b2_physical_p2_database_after_run_missing'
[IO.File]::WriteAllBytes($databaseAfterPath, [IO.File]::ReadAllBytes($dbPath))
$sqliteMembers = @($sqlitePaths | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    } | ForEach-Object {
        [ordered]@{
            roleCode = switch ([IO.Path]::GetFileName($_)) {
                'epinelps.db' { 'sqlite_main' }
                'epinelps.db-shm' { 'sqlite_shared_memory' }
                'epinelps.db-wal' { 'sqlite_write_ahead_log' }
            }
            byteLength = (Get-Item -LiteralPath $_).Length
            sha256 = Get-Sha256Hex $_
        }
    })
$sqliteObservation = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-physical-p2-sqlite-after-run/v1'
    observedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    assessmentUid = $assessmentUid
    memberCount = $sqliteMembers.Count
    members = $sqliteMembers
    cleanupCompleted = $false
}
Write-AtomicUtf8NoBom $sqliteObservationPath `
    (($sqliteObservation | ConvertTo-Json -Depth 7) + "`n")
foreach ($path in $sqlitePaths) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
    }
}
Assert-True (@($sqlitePaths | Where-Object {
            Test-Path -LiteralPath $_
        }).Count -eq 0) 'phase3b2_physical_p2_sqlite_cleanup_failed'
[IO.File]::WriteAllBytes(
    $dbPath, [IO.File]::ReadAllBytes($databaseBeforePath))
Assert-True (Test-PathDigest $dbPath 413327L `
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194') `
    'phase3b2_physical_p2_database_restore_failed'

$extensionFirewallGroup = 'NLL Phase3B2 Physical Bootstrap Extension'
$extensionRules = @(Get-NetFirewallRule -Group $extensionFirewallGroup `
    -ErrorAction SilentlyContinue)
Assert-True ($extensionRules.Count -eq 1) `
    'phase3b2_physical_p2_extension_firewall_shape_invalid'
$extensionRules | Remove-NetFirewallRule
Assert-True (@(Get-NetFirewallRule -Group $extensionFirewallGroup `
        -ErrorAction SilentlyContinue).Count -eq 0 -and
    @(Get-NetFirewallRule -Group 'NLL Phase3B2 Physical Isolation' `
        -ErrorAction SilentlyContinue).Count -eq 17) `
    'phase3b2_physical_p2_firewall_restore_failed'

$context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$md5 = [Security.Cryptography.MD5]::Create()
try {
    $passwordHash = (($md5.ComputeHash(
        [Text.Encoding]::ASCII.GetBytes([string]$context.password)) |
        ForEach-Object { $_.ToString('x2') }) -join '')
}
finally { $md5.Dispose() }
$serverStdoutPath = Join-Path $runRoot 'server.stdout.log'
$serverStderrPath = Join-Path $runRoot 'server.stderr.log'
$logText = ''
foreach ($path in @($serverStdoutPath, $serverStderrPath)) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $logText += [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    }
}
$sensitiveValues = @(
    [string]$context.accountId,
    [string]$context.managerId,
    [string]$context.username,
    [string]$context.password,
    $passwordHash,
    'C:\NLL',
    'C:\NIKKE',
    'E:\Recovered_OldSSD'
)
$rawSensitiveLogMatchCount = @($sensitiveValues | Where-Object {
    $_ -and $logText.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0
}).Count

$completion = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-physical-p2-client-completion/v1'
    completedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    assessmentUid = $assessmentUid
    p0AssessmentUid = '73f05d4f-b0e6-411d-b471-072b8ef3158b'
    p1AssessmentUid = '0e71964a-f07b-49e1-81de-78439e4b5b9e'
    runStartReceiptByteLength = (Get-Item $runStartPath).Length
    runStartReceiptSha256 = Get-Sha256Hex $runStartPath
    clientWasRunningAtCompletion = $clientWasRunning
    physicalBootstrapWasRunningAtCompletion = $bootstrapWasRunning
    serverWasRunningAtCompletion = $serverWasRunning
    officialLauncherRunningAtCompletion = $officialLauncherRunning
    successfulNonLoopbackConnectionCount = $successfulNonLoopback.Count
    databaseAfterRunByteLength = (Get-Item $databaseAfterPath).Length
    databaseAfterRunSha256 = Get-Sha256Hex $databaseAfterPath
    sqliteObservedMemberCount = $sqliteMembers.Count
    sqliteObservationByteLength = (Get-Item $sqliteObservationPath).Length
    sqliteObservationSha256 = Get-Sha256Hex $sqliteObservationPath
    rawSensitiveLogMatchCount = $rawSensitiveLogMatchCount
    runtimeStopped = $true
    databaseRestored = $true
    sqliteRuntimeRemoved = $true
    bootstrapExtensionFirewallRolledBack = $true
    baseP0Preserved = $true
    fullP0RollbackRequiredForWave2Closure = $true
    primaryInstallModified = $false
    officialLauncherModified = $false
    officialLauncherExecutionStarted = $false
    antiCheatSubstitutionApplied = $false
    clientExecutionStarted = $true
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    verdict = if ($successfulNonLoopback.Count -eq 0 -and
        $rawSensitiveLogMatchCount -eq 0 -and -not $officialLauncherRunning) {
        'physical_original_client_run_completed_runtime_restored'
    }
    else { 'physical_original_client_run_completed_with_safety_observation_failure' }
    nextStepCode = 'return_to_samsung_and_classify_original_client_observations'
}
Write-AtomicUtf8NoBom $completionPath `
    (($completion | ConvertTo-Json -Depth 8) + "`n")

$protectedMembers = @($runStartPath, $databaseBeforePath,
    $databaseAfterPath, $sqliteObservationPath, $completionPath,
    $serverStdoutPath, $serverStderrPath,
    (Join-Path $runRoot 'bootstrap-start.receipt.json'),
    (Join-Path $runRoot 'bootstrap-exit.receipt.json'),
    (Join-Path $runRoot 'bootstrap-failure.receipt.json'))
foreach ($path in $protectedMembers) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Copy-Item -LiteralPath $path -Destination $protectedRunRoot -Force
        $copy = Join-Path $protectedRunRoot (Split-Path -Leaf $path)
        Assert-True ((Get-Sha256Hex $copy) -ceq (Get-Sha256Hex $path)) `
            'phase3b2_physical_p2_completion_protected_copy_failed'
    }
}
$latest = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-physical-p2-completion-pointer/v1'
    assessmentUid = $assessmentUid
    completionReceiptByteLength = (Get-Item $completionPath).Length
    completionReceiptSha256 = Get-Sha256Hex $completionPath
    verdict = $completion.verdict
    runtimeStopped = $true
    databaseRestored = $true
    clientExecutionStarted = $true
}
Write-AtomicUtf8NoBom $latestCompletionPath `
    (($latest | ConvertTo-Json -Depth 6) + "`n")
Copy-Item -LiteralPath $latestCompletionPath -Destination $protectedRunRoot -Force
Remove-Item -LiteralPath $activePointerPath -Force

Assert-True ($successfulNonLoopback.Count -eq 0 -and
    $rawSensitiveLogMatchCount -eq 0 -and -not $officialLauncherRunning) `
    'phase3b2_physical_p2_safety_observation_failed'
$completion | ConvertTo-Json -Depth 9
