# Capture and restore runtime state; gameplay acceptance remains with the operator.
function Invoke-PhaseDRunnerComplete {
    param([object]$Specification,
        [ValidateSet('startup_only','server_selection','catalogue_path','lobby','solo_raid_menu',
            'season26_challenge_squad','season26_challenge_battle','season26_practice_squad','season26_practice_battle','battle_result')]
        [string]$ObservedStageCode = 'startup_only',
        [ValidateSet('success','system_error','operator_abort','client_exit')][string]$OutcomeCode = 'client_exit')
    Assert-PhaseDRunnerSpecification $Specification
    $ServerRoot = Join-Path $Specification.launchRoot 'runtime'
    $EvidenceRoot = Join-Path $Specification.launchRoot 'evidence'
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

    function Write-AtomicUtf8NoBom {
        param([string]$Path, [string]$Text)
        $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText(
            $temporary, $Text, [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    
    function Protect-ServerLog {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
        $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        $pattern = '(?m)^(?<prefix>\s*authtoken:\s*)\S+\s*$'
        $matchCount = [regex]::Matches($text, $pattern).Count
        if ($matchCount -gt 0) {
            $protected = [regex]::Replace(
                $text, $pattern, '${prefix}[REDACTED]'
            )
            Write-AtomicUtf8NoBom $Path $protected
        }
        return $matchCount
    }
    
    $expectedDbSha256 = $Specification.runtimeDbSha256
    $hostPins = Get-PhaseDRunnerHostPins
    $expectedBaseHostsSha256 = $hostPins.base
    $expectedAppliedHostsSha256 = $hostPins.applied
    
    Assert-PhaseDRunnerHost -Phase completion
    
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
    $dbPath = Join-Path $ServerRoot 'db.json'
    $hostsPath = Get-PhaseDRunnerHostsPath
    
    $runStart = Get-Content -LiteralPath $runStartPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True (
        $runStart.contractId -ceq
            'nll/phase3b2-epinel-solo-raid-ranking-prefix-start/v10' -and
        [string]$runStart.runIntentCode -in @('challenge', 'practice') -and
        -not $runStart.historicalReceiptBindingApplied -and
        -not $runStart.selfHashBindingApplied
    ) 'phase3b2_solo_raid_trial_practice_completion_start_shape_invalid'
    
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
    Assert-True ($null -eq (Get-PinnedProcess $clientId 'nikke')) `
        'phase3b2_epinel_minimal_completion_client_still_running_close_game_first'

    Invoke-PhaseDRunnerCapture -Specification $Specification -SourceDatabasePath $dbPath
    
    $redactedServerLogMatchCount = Protect-ServerLog $stdoutPath
    
    # Raw application logs are discarded; battle diagnostics are not cleanup proof.
    $appLogRoot = Join-Path $ServerRoot 'logs'
    foreach ($appLogPath in @(Get-ChildItem -LiteralPath $appLogRoot -Filter 'app-*.log' -File -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $appLogPath.FullName -Force
    }
    $sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
        ForEach-Object { Join-Path $ServerRoot $_ })
    [IO.File]::WriteAllBytes($dbPath, [IO.File]::ReadAllBytes($dbBeforePath))
    foreach ($path in $sqlitePaths) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    [IO.File]::WriteAllBytes(
        $hostsPath, [IO.File]::ReadAllBytes($hostsBeforePath)
    )
    
    Assert-True (
        (Get-Sha256Hex $dbPath) -ceq $expectedDbSha256 -and
        @($sqlitePaths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0 -and
        (Get-Sha256Hex $hostsPath) -ceq $expectedBaseHostsSha256
    ) 'phase3b2_epinel_minimal_completion_rollback_verification_failed'
    
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-solo-raid-ranking-prefix-completion/v10'
        completedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        assessmentUid = [string]$pointer.assessmentUid
        runStartReceiptSha256 = [string]$pointer.runStartReceiptSha256
        runIntentCode = [string]$runStart.runIntentCode
        observedStageCode = $ObservedStageCode
        outcomeCode = $OutcomeCode
        databaseRestored = $true
        sqliteRuntimeRemoved = $true
        hostsRestored = $true
        # The outside Job owner fills this only after verified firewall restoration.
        extensionFirewallRemoved = $false
        redactedServerLogMatchCount = $redactedServerLogMatchCount
    }
    Write-AtomicUtf8NoBom $completionPath `
        (($receipt | ConvertTo-Json -Depth 6) + "`n")
    $archivedPointerPath = Join-Path $runRoot 'active-run.pointer.archived.json'
    Move-Item -LiteralPath $activePointerPath -Destination $archivedPointerPath
    
    $receipt | ConvertTo-Json -Depth 6
}
