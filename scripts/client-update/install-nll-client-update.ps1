param([Parameter(Mandatory)][string]$PlanPath)
# CLIENT_UPDATE step 10c, run once by the operator in an elevated pwsh 7 (through the work folder's run-install-uac.ps1)
# while the game and the Control Center are closed. Applies only what prepare-nll-client-update-install.ps1 sealed:
# client overlay -> firewall programs -> native FX baseline -> database bindings -> registry and runtime selection ->
# app delivery with the new pipeline configuration -> preparation check of every season and weakness.
# Any failure restores the overlay, firewall programs, registry, selection and app delivery. The game is not started.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ClientUpdate.ps1')
$plan = Read-NllClientUpdatePlan $PlanPath
# DbOps (Tool/Secret/Probe, PostgreSQL bin) is the Git-ignored database helper of the common boss database install.
. (Join-Path $plan.repositoryRoot 'artifacts\common-boss-database-20260915\DbOps.ps1')
$repo = $plan.repositoryRoot
$install = 'C:\NLL\ControlCenter'
$work = $plan.workRoot
$runtimeWork = Join-Path $work 'runtime'
$registryRoot = 'C:\NLL\RuntimeInputs\CommonBossExecution\profiles'
$oldClient = $plan.previousClientRoot + '\'
$newClient = $plan.clientRoot + '\'
. (Join-Path $repo 'scripts/Nll.ResourceNative.ps1')
. (Join-Path $repo 'scripts/Nll.PhaseDRuntimeBundle.ps1')
. (Join-Path $repo 'scripts/Nll.PhaseDSharedIsolation.ps1')
. (Join-Path $repo 'scripts/Nll.ControlCenterMaintenance.ps1')
. (Join-Path $repo 'scripts/Nll.ControlCenterDelivery.ps1')
function Json($p, $v) { [IO.File]::WriteAllText($p, ($v | ConvertTo-Json -Depth 60), [Text.UTF8Encoding]::new($false)) }
function ReplaceFile($source, $target) {
    $next = $target + '.client-update-next'
    Need (-not (Test-Path $next)) 'install_temp_exists'
    Copy-Item -LiteralPath $source -Destination $next
    if (Test-Path $target) { [IO.File]::Replace($next, $target, [NullString]::Value) } else { [IO.File]::Move($next, $target) }
    Need ((Hash $source) -ceq (Hash $target)) 'installed_file_drifted'
}
function Progress($stage) { Json "$work/install-progress.json" @{ stage = $stage; atUtc = [DateTime]::UtcNow.ToString('o') } }
function Cold {
    Need (@(Get-Process -Name nikke, nikke_launcher, EpinelPS, postgres, 'NikkeLocalLab.Admin.Api', 'NLL Control Center',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap' -ErrorAction SilentlyContinue).Count -eq 0) 'runtime_not_cold'
    Need (@(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object LocalPort -in 17878, 55433).Count -eq 0) 'listener_present'
    Need (-not (Test-Path "$install/session/session.json")) 'session_present'
}
function Preparation([string]$connection) {
    $registry = Get-Content (Join-Path $registryRoot 'registry.json') -Raw | ConvertFrom-Json
    foreach ($season in @($registry.profiles.seasonNumber | Sort-Object)) {
        foreach ($weakness in @('fire', 'water', 'wind', 'electric', 'iron')) {
            $result = (Tool (Join-Path $PSHOME 'pwsh.exe') @('-NoProfile', '-File', "$repo/scripts/get-nll-phase-d-preparation.ps1",
                '-RepositoryRoot', $repo, '-SeasonNumber', [string]$season, '-WeaknessCode', $weakness) @{ NIKKE_LAB_DB = $connection }) | ConvertFrom-Json
            [ordered]@{ seasonNumber = $season; weaknessCode = $weakness; statusCode = $result.statusCode; failureCode = $result.failureCode
                clientBuildCode = $result.clientBuildCode }
        }
    }
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
Need ($env:USERNAME -ceq 'nlloperator' -and $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'administrator_required'
Need ($PSVersionTable.PSVersion.Major -ge 7) 'pwsh_required'
Cold
$prep = Get-Content "$work/install-preparation.receipt.json" -Raw | ConvertFrom-Json
Need ($prep.build -ceq $plan.build -and (Hash $PlanPath) -ceq $prep.planSha256) 'preparation_plan_mismatch'
Need ((git -C $repo rev-parse HEAD).Trim() -ceq $prep.repositoryHead) 'repository_head_changed'
Need (@(git -C $repo status --porcelain --untracked-files=no).Count -eq 0) 'repository_dirty'
$configPath = Join-Path $runtimeWork 'configuration.private.json'
$paths = [ordered]@{ selectionNext = (Join-Path $runtimeWork 'selection-next.private.json'); bundle = (Join-Path $plan.runtimeRoot 'bundle.private.json')
    configuration = $configPath; catalog = [string]$prep.catalogPath; registryNext = (Join-Path $runtimeWork 'registry-next\registry.json')
    registrationPlan = (Join-Path $runtimeWork 'registration-plan.private.json') }
foreach ($name in $paths.Keys) { Need ((Hash $paths[$name]) -ceq $prep.$name.sha256) ("prepared_input_changed_$name") }
Need ((Hash "$install/runtime-selection.private.json") -ceq $prep.selectionBefore.sha256) 'runtime_selection_changed'
Need ((Hash "$install/boss-pipeline.active.json") -ceq $prep.activationBefore.sha256) 'boss_activation_changed'
Need ((Hash "$registryRoot/registry.json") -ceq $prep.registryBefore.sha256) 'registry_changed'
$selectionNext = $paths.selectionNext
$b = Read-PdRuntimeBundle $selectionNext -BeforeActivation
Need ($b.clientBuildCode -ceq ('build_' + $plan.build)) 'bundle_invalid'
$mat = Join-Path $b.materializerRoot 'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
$rules = @(Get-PhaseDIsolationRules)
Assert-PhaseDIsolationProcessesCold @(@($b.clientPrograms.path) + @($b.blockOnlyPrograms) + @($rules.program))
Need (@($rules | Where-Object { (Test-PhaseDSharedIsolationPath $_.program) -and $_.enabled }).Count -eq 0) 'shared_programs_not_cold'
$expected = @(@($b.clientPrograms.path) + @($b.blockOnlyPrograms) | Sort-Object -Unique)

$backup = Join-Path $work ('installation-backup-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))
New-Item -ItemType Directory -Path $backup | Out-Null
Json "$backup/firewall.json" $rules
$overlayChanges = [Collections.Generic.List[object]]::new()
$ruleChanges = [Collections.Generic.List[object]]::new()
$registryChanged = $false; $selectionChanged = $false; $deliveryApplied = $false; $pgOwned = $false; $completed = $false
$pg = Join-Path $bin 'pg_ctl.exe'; $pgData = "$install/postgresql/data"
$lease = Enter-NllControlCenterMaintenance $install 'deploy'
try {
    Progress 'overlay'
    foreach ($change in $b.overlay) {
        Assert-PdBundlePin $change.before; Assert-PdBundlePin $change.backup; Assert-PdBundlePin $change.replacement
        $overlayChanges.Add($change)
        ReplaceFile $change.replacement.path $change.before.path
    }

    Progress 'firewall'
    foreach ($rule in $rules) {
        $target = if ($rule.program.StartsWith($oldClient, [StringComparison]::OrdinalIgnoreCase)) { $newClient + $rule.program.Substring($oldClient.Length) }
            elseif ($rule.program.StartsWith('C:\NIKKE\', [StringComparison]::OrdinalIgnoreCase)) { $plan.officialRoot + '\' + $rule.program.Substring(9) }
            else { $rule.program }
        Need ($target -in $expected) 'firewall_destination_invalid'
        if ($target -cne $rule.program) {
            $ruleChanges.Add($rule)
            Set-NetFirewallRule -Name $rule.name -Program $target -ErrorAction Stop | Out-Null
        }
    }
    Need ($ruleChanges.Count -gt 0) 'firewall_change_count_invalid'
    # Read back by name; mutation results may describe the pre-call state.
    $after = @(Get-PhaseDIsolationRules -Rules @(Get-NetFirewallRule -Name @($rules.name) -ErrorAction Stop) -Applied)
    Need ($after.Count -eq $rules.Count -and @(Compare-Object $expected @($after.program)).Count -eq 0) 'firewall_readback_invalid'
    foreach ($row in $after) {
        $before = @($rules | Where-Object name -CEQ $row.name)[0]
        Need ($row.enabled -eq $before.enabled) 'firewall_enabled_state_changed'
    }

    Progress 'native_baseline'
    $store = $b.commonNativeStore
    $baselinePath = "C:\NLL\RuntimeInputs\CommonBossExecution\native-fx-$($plan.build)\baseline.private.json"
    if (-not (Test-Path $baselinePath)) {
        $baseline = Tool $mat @('--register-common-native-fx-baseline', 'true', '--store-path', $store.path, '--store-length', [string]$store.length,
            '--store-sha256', $store.sha256, '--installation-id', $plan.installationId, '--client-version', $plan.build)
        Json "$work/native-baseline.receipt.json" ($baseline | ConvertFrom-Json)
    }

    Progress 'database_bindings'
    $password = Secret 'database-password'
    $env:NIKKE_LAB_DB = "Host=127.0.0.1;Port=55433;Database=nll_control_center;Username=nll_control_center;Password=$password;SSL Mode=Disable"
    $env:NIKKE_LAB_ID_SECRET = Secret 'identity-secret'
    $env:NIKKE_LAB_HOME = "$install/runtime-home"
    Need (-not (Test-Path "$pgData/postmaster.pid")) 'database_already_running'
    Tool $pg @('start', '-D', $pgData, '-l', "$install/logs/postgresql.log", '-w', '-t', '60') -NoCapture; $pgOwned = $true
    Tool (Join-Path $bin 'pg_dump.exe') @('-h', '127.0.0.1', '-p', '55433', '-U', 'nll_control_center', '-d', 'nll_control_center', '-Fc', '-f', "$backup/database.dump") @{ PGPASSWORD = $password } | Out-Null
    $password = $null
    $null = Probe $env:NIKKE_LAB_DB 'fingerprint' "$backup/data-before.json"
    $registrations = @()
    foreach ($row in (Get-Content $paths.registrationPlan -Raw | ConvertFrom-Json)) {
        Need ((Hash $row.profilePath) -ceq $row.profileSha256 -and (Hash $row.delivery.path) -ceq $row.delivery.sha256) 'registration_input_changed'
        $arguments = @('--register-common-boss-database', 'true', '--delivery-path', $row.delivery.path, '--delivery-sha256', $row.delivery.sha256,
            '--boss-variant-profile', $row.profilePath, '--connection-string-env', 'NIKKE_LAB_DB')
        # Same behavior graph and references: the existing Challenge history continues under the new profile.
        if ($row.equivalentCombatSource) { $arguments += @('--previous-boss-variant-profile', $row.previousProfilePath) }
        $r = (Tool $mat $arguments) | ConvertFrom-Json
        Need ($r.statusCode -ceq 'registered' -and $r.seasonNumber -eq $row.seasonNumber) 'boss_registration_failed'
        $registrations += $r
    }
    Json "$work/database-bindings.receipt.json" $registrations
    $null = Probe $env:NIKKE_LAB_DB 'fingerprint' "$work/data-after-bindings.json"
    Need ((Hash "$backup/data-before.json") -ceq (Hash "$work/data-after-bindings.json")) 'existing_data_changed'
    Tool $pg @('stop', '-D', $pgData, '-m', 'fast', '-w', '-t', '60') -NoCapture; $pgOwned = $false

    Progress 'registry_and_selection'
    foreach ($file in Get-ChildItem (Split-Path $paths.registryNext -Parent) -File -Filter '*.json' | Where-Object Name -NE 'registry.json') {
        $target = Join-Path $registryRoot $file.Name
        if (Test-Path $target) { Need ((Hash $target) -ceq (Hash $file.FullName)) 'immutable_profile_collision' }
        else { Copy-Item -LiteralPath $file.FullName -Destination $target }
    }
    ReplaceFile $paths.registryNext "$registryRoot/registry.json"; $registryChanged = $true
    ReplaceFile $selectionNext "$install/runtime-selection.private.json"; $selectionChanged = $true
    $null = Read-PdRuntimeBundle "$install/runtime-selection.private.json"
    $lease.Dispose(); $lease = $null

    Progress 'app_and_activation'
    # Keep the replaced season catalog readable as a revision (same records as the 152 installation).
    $previousActivation = Get-Content "$runtimeWork/activation.before.json" -Raw | ConvertFrom-Json
    $previousConfig = Get-Content $previousActivation.configurationPath -Raw | ConvertFrom-Json
    $seasonRoot = [string](Get-Content $configPath -Raw | ConvertFrom-Json).seasonSync.root
    Need (-not (Test-Path (Join-Path $seasonRoot 'current.json'))) 'catalog_revision_changed'
    $retained = Join-Path $seasonRoot ('retained-configurations\' + $previousConfig.catalogSha256 + '.json')
    if (-not (Test-Path $retained)) { Copy-Item -LiteralPath $previousActivation.configurationPath -Destination $retained }
    Need ((Hash $retained) -ceq $previousActivation.configurationSha256) 'retained_catalog_conflict'
    $revision = Join-Path $seasonRoot ('revisions\' + $previousConfig.catalogSha256 + '.json')
    if (-not (Test-Path $revision)) { Json $revision ([ordered]@{ configurationSha256 = (Hash $retained); configurationPath = $retained }) }
    $null = Invoke-NllControlCenterDelivery $prep.deliveryPlanRoot $prep.deliveryPlanSha256 apply { Cold }
    $deliveryApplied = $true
    Need ((Get-NllBossPipelineActivation $install $repo).sha256 -ceq $prep.configuration.sha256) 'activation_not_selected'

    Progress 'preparation'
    Tool $pg @('start', '-D', $pgData, '-l', "$install/logs/postgresql.log", '-w', '-t', '60') -NoCapture; $pgOwned = $true
    $password = Secret 'database-password'
    $readOnly = "Host=127.0.0.1;Port=55433;Database=nll_control_center;Username=nll_control_center;Password=$password;SSL Mode=Disable;Options=-c default_transaction_read_only=on"
    $password = $null
    $checks = @(Preparation $readOnly)
    Json "$work/installed-preparation.json" $checks
    $notReady = @($checks | Where-Object { $_.statusCode -cne 'ready' -or $_.clientBuildCode -cne ('build_' + $plan.build) })
    Need ($notReady.Count -eq 0) ('preparation_not_ready: ' + (($notReady | ForEach-Object { "S$($_.seasonNumber)/$($_.weaknessCode)=$($_.failureCode)" }) -join ', '))
    $null = Probe $readOnly 'fingerprint' "$work/data-after-install.json"
    Need ((Hash "$backup/data-before.json") -ceq (Hash "$work/data-after-install.json")) 'existing_data_changed'
    Tool $pg @('stop', '-D', $pgData, '-m', 'fast', '-w', '-t', '60') -NoCapture; $pgOwned = $false
    Json "$work/installation.receipt.json" ([ordered]@{ status = 'installed'; build = $plan.build; repositoryHead = $prep.repositoryHead
        bundleSha256 = (Hash $b.manifestPath); configurationSha256 = $prep.configuration.sha256; preparationCount = $checks.Count
        firewallProgramsChanged = $ruleChanges.Count; registeredSeasons = @($registrations.seasonNumber); resourceGuidance = 'not_supplied'
        gameStarted = $false; atUtc = [DateTimeOffset]::UtcNow.ToString('o') })
    $completed = $true; Progress 'installed'
} catch {
    $errorCode = if ($_.Exception.Message -cmatch '^[a-z0-9_:/=, -]{3,400}$') { $_.Exception.Message } else { 'installation_failed' }
    Json "$work/installation.failure.json" @{ code = $errorCode; exceptionType = $_.Exception.GetType().FullName; line = $_.InvocationInfo.ScriptLineNumber
        stage = (Get-Content "$work/install-progress.json" -Raw | ConvertFrom-Json).stage }
    throw
} finally {
    foreach ($name in @('NIKKE_LAB_DB', 'NIKKE_LAB_ID_SECRET', 'NIKKE_LAB_HOME')) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
    if ($pgOwned) { Tool $pg @('stop', '-D', $pgData, '-m', 'fast', '-w', '-t', '60') -NoCapture }
    if (-not $completed) {
        if ($deliveryApplied) { $null = Invoke-NllControlCenterDelivery $prep.deliveryPlanRoot $prep.deliveryPlanSha256 restore { Cold } }
        if ($null -eq $lease) { $lease = Enter-NllControlCenterMaintenance $install 'deploy' }
        if ($selectionChanged) { ReplaceFile "$runtimeWork/selection.before.json" "$install/runtime-selection.private.json" }
        if ($registryChanged) { ReplaceFile "$runtimeWork/registry.before.json" "$registryRoot/registry.json" }
        foreach ($rule in $ruleChanges) { Set-NetFirewallRule -Name $rule.name -Program $rule.program -ErrorAction Stop | Out-Null }
        foreach ($change in $overlayChanges) { ReplaceFile $change.backup.path $change.before.path }
    }
    if ($null -ne $lease) { $lease.Dispose() }
}
Get-Content "$work/installation.receipt.json"
