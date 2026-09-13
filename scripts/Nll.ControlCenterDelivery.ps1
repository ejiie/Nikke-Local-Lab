# App-only deployment transaction. The public wrapper supplies the fixed install
# root, cold-runtime check and protected v6/selection pins. Never starts anything.
. (Join-Path $PSScriptRoot 'Nll.ControlCenterAppPackage.ps1')
. (Join-Path $PSScriptRoot 'Nll.ControlCenterMaintenance.ps1')

function New-NllControlCenterDeliveryPlan([string]$InstallRoot, [string]$AppPackageRoot,
    [string]$AppPackageSha256, [string]$ConfigurationPath, [string]$ConfigurationSha256,
    [string]$StartSource, [string]$OutputRoot, [object[]]$ProtectedPins = @()) {
    $install = Get-NllAppPlainPath $InstallRoot
    $output = Get-NllAppPlainPath $OutputRoot
    $package = Read-NllControlCenterAppPackage $AppPackageRoot $AppPackageSha256
    Assert-NllAppPackage ($package.targetRoot -ceq (Join-Path $install 'app')) 'delivery_target_invalid'
    Assert-NllAppPackage (-not (Test-Path -LiteralPath $output) -and
        [IO.Path]::GetPathRoot($output) -ieq [IO.Path]::GetPathRoot($install)) 'delivery_output_invalid'
    foreach ($inputRoot in @($install,$AppPackageRoot,[IO.Path]::GetDirectoryName($ConfigurationPath))) {
        $inputRoot = Get-NllAppPlainPath $inputRoot
        Assert-NllAppPackage ($inputRoot -ine $output -and
            -not $output.StartsWith($inputRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and
            -not $inputRoot.StartsWith($output + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'output_overlaps_input'
    }
    $configurationPin = Get-NllAppPin $ConfigurationPath
    Assert-NllAppPackage ($configurationPin.sha256 -ceq $ConfigurationSha256) 'delivery_configuration_drifted'
    $startPin = Get-NllAppPin $StartSource
    Assert-NllAppPackage ($null -ne $startPin -and $null -ne (Get-NllAppPin (Join-Path $install 'Start-NLL-ControlCenter.ps1'))) 'delivery_start_missing'
    foreach ($pin in $ProtectedPins) { Assert-NllAppPackage (Test-NllAppPin (Get-NllAppPin $pin.path) $pin.pin) 'protected_drifted' }
    Assert-NllControlCenterDeliveryAppState $package
    $null = [IO.Directory]::CreateDirectory($output)
    $beforeRoot = Join-Path $output 'before'
    $afterRoot = Join-Path $output 'after'
    $null = [IO.Directory]::CreateDirectory($beforeRoot)
    $null = [IO.Directory]::CreateDirectory($afterRoot)
    Copy-NllAppNewFile $StartSource (Join-Path $afterRoot 'Start-NLL-ControlCenter.ps1') $startPin
    Write-NllAppNewJson (Join-Path $afterRoot 'boss-pipeline.active.json') ([ordered]@{
        schemaVersion = 1; contractId = 'nll/boss-pipeline-activation/v1';
        configurationPath = (Get-NllAppPlainPath $ConfigurationPath); configurationSha256 = $ConfigurationSha256 })
    $controls = foreach ($name in @('Start-NLL-ControlCenter.ps1','boss-pipeline.active.json')) {
        $before = Get-NllAppPin (Join-Path $install $name)
        if ($null -ne $before) { Copy-NllAppNewFile (Join-Path $install $name) (Join-Path $beforeRoot $name) $before }
        [ordered]@{ name = $name; before = $before; after = Get-NllAppPin (Join-Path $afterRoot $name) }
    }
    $sources = foreach ($name in @('Nll.ControlCenterDelivery.ps1','Nll.ControlCenterAppPackage.ps1',
        'Nll.ControlCenterMaintenance.ps1','invoke-nll-control-center-delivery.ps1')) {
        $path = Join-Path $PSScriptRoot $name
        [ordered]@{ path = $path; pin = Get-NllAppPin $path }
    }
    $plan = [ordered]@{ schemaVersion = 1; contractId = 'nll/control-center-delivery/v1'; installRoot = $install;
        appPackageRoot = (Get-NllAppPlainPath $AppPackageRoot); appPackageSha256 = $AppPackageSha256;
        configurationPath = (Get-NllAppPlainPath $ConfigurationPath); configurationPin = $configurationPin;
        controls = @($controls); sourcePins = @($sources); protectedPins = @($ProtectedPins);
        operationalDatabaseTouched = $false; nativeClientExecuted = $false }
    Write-NllAppNewJson (Join-Path $output 'plan.private.json') $plan
    [ordered]@{ planRoot = $output; planSha256 = (Get-NllAppPin (Join-Path $output 'plan.private.json')).sha256;
        installedFilesModified = $false; nativeClientExecuted = $false }
}

function Read-NllControlCenterDeliveryPlan([string]$PlanRoot, [string]$PlanSha256) {
    $root = Get-NllAppPlainPath $PlanRoot
    $path = Join-Path $root 'plan.private.json'
    Assert-NllAppPackage ($PlanSha256 -cmatch '^[a-f0-9]{64}$' -and (Get-NllAppPin $path).sha256 -ceq $PlanSha256 -and
        (Get-Item -LiteralPath $path).Length -le 4194304) 'delivery_plan_drifted'
    $plan = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-NllAppPackage ($plan.schemaVersion -eq 1 -and $plan.contractId -ceq 'nll/control-center-delivery/v1' -and
        $plan.operationalDatabaseTouched -eq $false -and $plan.nativeClientExecuted -eq $false -and
        @($plan.controls).Count -eq 2 -and $plan.controls[0].name -ceq 'Start-NLL-ControlCenter.ps1' -and
        $plan.controls[1].name -ceq 'boss-pipeline.active.json') 'delivery_plan_invalid'
    $package = Read-NllControlCenterAppPackage $plan.appPackageRoot $plan.appPackageSha256
    Assert-NllAppPackage ($package.targetRoot -ceq (Join-Path (Get-NllAppPlainPath $plan.installRoot) 'app')) 'delivery_target_invalid'
    foreach ($pin in @($plan.sourcePins) + @($plan.protectedPins)) {
        Assert-NllAppPackage (Test-NllAppPin (Get-NllAppPin $pin.path) $pin.pin) 'delivery_input_drifted'
    }
    Assert-NllAppPackage (Test-NllAppPin (Get-NllAppPin $plan.configurationPath) $plan.configurationPin) 'delivery_configuration_drifted'
    foreach ($row in $plan.controls) {
        foreach ($side in @('before','after')) {
            Assert-NllAppPackage (Test-NllAppPin (Get-NllAppPin (Join-Path (Join-Path $root $side) $row.name)) $row.$side) 'delivery_control_drifted'
        }
    }
    $plan
}

function Set-NllControlCenterDeliveryMember([string]$PlanRoot, [string]$InstallRoot, $Row,
    [ValidateSet('before','after')][string]$Side) {
    $target = Get-NllAppMemberPath $InstallRoot $Row.name
    $current = Get-NllAppPin $target
    $desired = $Row.$Side
    Assert-NllAppPackage ((Test-NllAppPin $current $Row.before) -or (Test-NllAppPin $current $Row.after)) 'delivery_installed_control_drifted'
    if (Test-NllAppPin $current $desired) { return }
    $transfer = Join-Path $PlanRoot ('transfer-' + $Side)
    $null = [IO.Directory]::CreateDirectory($transfer)
    if ($null -eq $desired) {
        # Recoverable retirement of a newly added activation file, never Delete.
        $retired = Join-Path $transfer ($Row.name + '.retired-' + [guid]::NewGuid().ToString('N'))
        Assert-NllAppPackage (Test-NllAppPin (Get-NllAppPin $target) $current) 'delivery_installed_control_drifted'
        [IO.File]::Move($target, $retired)
    } else {
        $temporary = Join-Path $transfer $Row.name
        if (Test-Path -LiteralPath $temporary) {
            Assert-NllAppPackage (Test-NllAppPin (Get-NllAppPin $temporary) $desired) 'delivery_partial_drifted'
        } else { Copy-NllAppNewFile (Join-Path (Join-Path $PlanRoot $Side) $Row.name) $temporary $desired }
        Assert-NllAppPackage (Test-NllAppPin (Get-NllAppPin $target) $current) 'delivery_installed_control_drifted'
        [IO.File]::Move($temporary, $target, $true)
    }
    Assert-NllAppPackage (Test-NllAppPin (Get-NllAppPin $target) $desired) 'delivery_control_mismatch'
}

function Assert-NllControlCenterDeliveryAppState($Package) {
    $before = @{}; $after = @{}
    foreach ($row in $Package.before) { $before[$row.relativePath] = $row.pin }
    foreach ($row in $Package.after) { $after[$row.relativePath] = $row.pin }
    foreach ($row in @(Get-NllAppInventory $Package.targetRoot)) {
        Assert-NllAppPackage ($after.ContainsKey($row.relativePath)) 'unexpected_target_file'
    }
    foreach ($key in $after.Keys) {
        $pin = Get-NllAppPin (Get-NllAppMemberPath $Package.targetRoot $key)
        Assert-NllAppPackage ((Test-NllAppPin $pin $before[$key]) -or (Test-NllAppPin $pin $after[$key])) 'target_drifted'
    }
}

function Invoke-NllControlCenterDelivery([string]$PlanRoot, [string]$PlanSha256,
    [ValidateSet('apply','restore')][string]$Operation, [Parameter(Mandatory)][scriptblock]$AssertCold) {
    $root = Get-NllAppPlainPath $PlanRoot
    $plan = Read-NllControlCenterDeliveryPlan $root $PlanSha256
    $lease = Enter-NllControlCenterMaintenance $plan.installRoot deploy
    try {
        & $AssertCold
        $appPackage = Read-NllControlCenterAppPackage $plan.appPackageRoot $plan.appPackageSha256
        Assert-NllControlCenterDeliveryAppState $appPackage
        foreach ($row in $plan.controls) {
            $pin = Get-NllAppPin (Join-Path $plan.installRoot $row.name)
            Assert-NllAppPackage ((Test-NllAppPin $pin $row.before) -or (Test-NllAppPin $pin $row.after)) 'delivery_installed_control_drifted'
        }
        $pending = Get-NllAppMemberPath $plan.installRoot 'app-update.pending.json'
        if (Test-Path -LiteralPath $pending) {
            Assert-NllAppPackage ((Get-Item -LiteralPath $pending).Length -le 16384) 'delivery_pending_invalid'
            $value = Get-Content -LiteralPath $pending -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-NllAppPackage ($value.contractId -ceq 'nll/control-center-update-pending/v1' -and
                $value.planSha256 -ceq $PlanSha256 -and @($value.PSObject.Properties).Count -eq 2) 'delivery_pending_invalid'
        } else {
            Write-NllAppNewJson $pending ([ordered]@{ contractId = 'nll/control-center-update-pending/v1'; planSha256 = $PlanSha256 })
        }
        if ($Operation -ceq 'apply') {
            # Install the guarded start script before any app DLL changes. The
            # pending marker and held lease then prevent a mixed-version startup.
            Set-NllControlCenterDeliveryMember $root $plan.installRoot $plan.controls[0] after
            & $AssertCold
            $null = Invoke-NllControlCenterAppPackage $plan.appPackageRoot $plan.appPackageSha256 (Join-Path $plan.installRoot 'app') apply
            Set-NllControlCenterDeliveryMember $root $plan.installRoot $plan.controls[1] after
        } else {
            $null = Invoke-NllControlCenterAppPackage $plan.appPackageRoot $plan.appPackageSha256 (Join-Path $plan.installRoot 'app') restore
            Set-NllControlCenterDeliveryMember $root $plan.installRoot $plan.controls[1] before
            & $AssertCold
            Set-NllControlCenterDeliveryMember $root $plan.installRoot $plan.controls[0] before
        }
        & $AssertCold
        $null = Read-NllControlCenterDeliveryPlan $root $PlanSha256
        $side = if ($Operation -ceq 'apply') { 'after' } else { 'before' }
        Assert-NllAppPackage (Test-NllAppInventory $appPackage.$side @(Get-NllAppInventory $appPackage.targetRoot)) 'delivery_app_mismatch'
        foreach ($row in $plan.controls) {
            Assert-NllAppPackage (Test-NllAppPin (Get-NllAppPin (Join-Path $plan.installRoot $row.name)) $row.$side) 'delivery_control_mismatch'
        }
        $receipt = [ordered]@{ contractId = 'nll/control-center-delivery-operation/v1'; planSha256 = $PlanSha256;
            operation = $Operation; statusCode = 'verified'; nativeClientExecuted = $false; operationalDatabaseTouched = $false }
        # Retain this transaction's marker as evidence. No wildcard cleanup.
        [IO.File]::Move($pending, (Join-Path $root ('completed-pending-' + [guid]::NewGuid().ToString('N') + '.json')))
        Write-NllAppNewJson (Join-Path $root ($Operation + '-' + [guid]::NewGuid().ToString('N') + '.receipt.json')) $receipt
        $receipt
    } finally { $lease.Dispose() }
}
