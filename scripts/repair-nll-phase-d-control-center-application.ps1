[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\NLL\ControlCenter',
    [string]$PreparedAppRoot =
        'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\artifacts\phase-d\control-center',
    [string]$PreparedDesktopRoot =
        'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\artifacts\phase-d\control-center-desktop',
    [string]$PreparedPresentationAssetsRoot =
        'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\artifacts\phase-d\presentation-assets',
    [string]$MaterializerBuildRoot =
        'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\tools\NikkeLocalLab.PhaseD.RuntimeMaterializer\bin\Release\net10.0\win-x64',
    [string]$WeaknessVariantServerBuildRoot =
        'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\.external\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64',
    [string]$WeaknessVariantSourceManifestPath =
        'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\scripts\phase-d-weakness-variant-v10.source.manifest.tsv',
    [string]$PinnedRuntimeRoot =
        'C:\NLL\Runtime\EpinelPS-SoloRaidRankingPrefix-v9',
    [string]$RepositoryRoot =
        'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab',
    [ValidateRange(1024, 65535)] [int]$DatabasePort = 55433,
    [ValidateRange(1024, 65535)] [int]$AdminPort = 17878
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security

function Assert-Repair {
    param([bool]$Condition, [string]$Code)
    if (-not $Condition) { throw $Code }
}
function Get-Sha256Lower {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Test-RepairPort {
    param([int]$Port)
    $client = New-Object Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync('127.0.0.1', $Port)
        return $task.Wait(800) -and $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}
function Invoke-RepairPgCtl {
    param([string[]]$Arguments)
    $process = Start-Process -FilePath 'C:\NLL\Runtime\PostgreSQL-17-native\bin\pg_ctl.exe' `
        -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    $process.WaitForExit()
    $process.ExitCode
}
function Write-RepairJson {
    param([string]$Path, [object]$Value)
    $temporary = $Path + '.partial-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText(
        $temporary,
        (($Value | ConvertTo-Json -Depth 8) + "`n"),
        (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) {
        $backup = $Path + '.backup-' + [guid]::NewGuid().ToString('N')
        try { [IO.File]::Replace($temporary, $Path, $backup) }
        finally {
            if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        }
    }
    else { Move-Item -LiteralPath $temporary -Destination $Path }
}
function Unprotect-RepairSecret {
    param([string]$Path)
    $protected = [IO.File]::ReadAllBytes($Path)
    $entropy = [Text.Encoding]::UTF8.GetBytes('nll/control-center/dpapi/v1')
    try {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect(
            $protected, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        try { [Text.Encoding]::UTF8.GetString($plain) }
        finally { [Array]::Clear($plain, 0, $plain.Length) }
    }
    finally {
        [Array]::Clear($protected, 0, $protected.Length)
        [Array]::Clear($entropy, 0, $entropy.Length)
    }
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
Assert-Repair `
    ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase_d_application_repair_requires_administrator'
Assert-Repair `
    ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'nlloperator') `
    'phase_d_application_repair_wrong_operator_or_boot'
Assert-Repair `
    ([IO.Path]::GetFullPath($InstallRoot).TrimEnd('\') -ceq 'C:\NLL\ControlCenter') `
    'phase_d_application_repair_target_invalid'
Assert-Repair `
    (@(Get-Process -Name postgres,EpinelPS,nikke -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase_d_application_repair_runtime_not_cold'
Assert-Repair `
    (-not (Test-RepairPort $DatabasePort) -and -not (Test-RepairPort $AdminPort)) `
    'phase_d_application_repair_port_in_use'

$deploymentPath = Join-Path $InstallRoot 'deployment.receipt.json'
$deployment = Get-Content -LiteralPath $deploymentPath -Raw | ConvertFrom-Json
Assert-Repair `
    ($deployment.contractId -ceq 'nll/phase-d-control-center-deployment/v1') `
    'phase_d_application_repair_deployment_invalid'

$preparedDll = Join-Path $PreparedAppRoot 'NikkeLocalLab.Admin.Api.dll'
$preparedPdb = Join-Path $PreparedAppRoot 'NikkeLocalLab.Admin.Api.pdb'
$preparedEditor = Join-Path $PreparedAppRoot 'wwwroot\editor'
$preparedDesktopExe = Join-Path $PreparedDesktopRoot 'NLL Control Center.exe'
$sourceDesktopIcon = Join-Path $RepositoryRoot `
    'tools\NikkeLocalLab.ControlCenter.Desktop\Assets\kamibot.ico'
$preparedAssetReceipt = Join-Path $PreparedPresentationAssetsRoot 'assets.receipt.json'
$preparedCharacterAssets = Join-Path $PreparedPresentationAssetsRoot 'characters'
$preparedBossAssets = Join-Path $PreparedPresentationAssetsRoot 'bosses'
$preparedUiAssets = Join-Path $PreparedPresentationAssetsRoot 'ui'
$materializerExe = Join-Path $MaterializerBuildRoot 'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
$materializerArtifactRoot = Join-Path $RepositoryRoot 'artifacts\phase-d\runtime-materializer'
$weaknessVariantArtifactRoot = Join-Path $RepositoryRoot `
    'artifacts\phase-d\weakness-variant-server'
$weaknessVariantServerDll = Join-Path $WeaknessVariantServerBuildRoot 'EpinelPS.dll'
$expectedWeaknessVariantServerDllSha256 =
    'a364b9211efc1b60d23efc50075e101b0212f09b96a311b167743d01583939e6'
$expectedWeaknessVariantServerDllByteLength = 15406592L
$expectedWeaknessVariantSourceManifestSha256 =
    '0ebd23987384fde1537b88efcfdd5b19fc18176f185d9cd1e9fa743914d24bbf'
$expectedWeaknessVariantSourceManifestByteLength = 3270L
$materializerLeaves = @(
    'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe',
    'NikkeLocalLab.PhaseD.RuntimeMaterializer.dll',
    'NikkeLocalLab.PhaseD.RuntimeMaterializer.deps.json',
    'NikkeLocalLab.PhaseD.RuntimeMaterializer.runtimeconfig.json'
)
$sourceStart = Join-Path $RepositoryRoot 'scripts\start-nll-phase-d-control-center.ps1'
$sourceStop = Join-Path $RepositoryRoot 'scripts\stop-nll-phase-d-control-center.ps1'
$sourceRecovery = Join-Path $RepositoryRoot `
    'scripts\recover-nll-phase-d-orphaned-execution.ps1'
$installedDll = Join-Path $InstallRoot 'app\NikkeLocalLab.Admin.Api.dll'
$installedPdb = Join-Path $InstallRoot 'app\NikkeLocalLab.Admin.Api.pdb'
$installedStart = Join-Path $InstallRoot 'Start-NLL-ControlCenter.ps1'
$installedStop = Join-Path $InstallRoot 'Stop-NLL-ControlCenter.ps1'
foreach ($path in @($preparedDll,$preparedDesktopExe,$sourceDesktopIcon,$preparedAssetReceipt,$materializerExe,$weaknessVariantServerDll,$WeaknessVariantSourceManifestPath,$sourceStart,$sourceStop,$sourceRecovery,$installedDll,$installedStart,$installedStop)) {
    Assert-Repair (Test-Path -LiteralPath $path -PathType Leaf) `
        'phase_d_application_repair_member_missing'
}
Assert-Repair `
    ((Get-Item -LiteralPath $weaknessVariantServerDll).Length -eq `
        $expectedWeaknessVariantServerDllByteLength -and
     (Get-Sha256Lower $weaknessVariantServerDll) -ceq `
        $expectedWeaknessVariantServerDllSha256 -and
     (Get-Item -LiteralPath $WeaknessVariantSourceManifestPath).Length -eq `
        $expectedWeaknessVariantSourceManifestByteLength -and
     (Get-Sha256Lower $WeaknessVariantSourceManifestPath) -ceq `
        $expectedWeaknessVariantSourceManifestSha256) `
    'phase_d_application_repair_weakness_variant_artifact_invalid'
$externalSourceRoot = [IO.Path]::GetFullPath(
    (Join-Path $RepositoryRoot '.external\EpinelPS')).TrimEnd('\') + '\'
$weaknessVariantSourceRows = @(Get-Content `
    -LiteralPath $WeaknessVariantSourceManifestPath -Encoding UTF8)
Assert-Repair ($weaknessVariantSourceRows.Count -eq 25) `
    'phase_d_application_repair_weakness_variant_manifest_invalid'
foreach ($row in $weaknessVariantSourceRows) {
    $parts = @($row -split "`t")
    Assert-Repair `
        ($parts.Count -eq 3 -and
         $parts[0] -cmatch '^(EpinelPS|tests)/[A-Za-z0-9._/-]+$' -and
         $parts[1] -cmatch '^[1-9][0-9]*$' -and
         $parts[2] -cmatch '^[0-9a-f]{64}$') `
        'phase_d_application_repair_weakness_variant_manifest_invalid'
    $sourcePath = [IO.Path]::GetFullPath(
        (Join-Path $externalSourceRoot $parts[0].Replace('/', '\')))
    Assert-Repair `
        ($sourcePath.StartsWith(
            $externalSourceRoot, [StringComparison]::OrdinalIgnoreCase) -and
         (Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
         (Get-Item -LiteralPath $sourcePath).Length -eq [long]$parts[1] -and
         (Get-Sha256Lower $sourcePath) -ceq $parts[2]) `
        'phase_d_application_repair_weakness_variant_source_drifted'
}
foreach ($leaf in $materializerLeaves) {
    Assert-Repair (Test-Path -LiteralPath (Join-Path $MaterializerBuildRoot $leaf) -PathType Leaf) `
        'phase_d_application_repair_materializer_member_missing'
}
foreach ($path in @($preparedEditor,$preparedCharacterAssets,$preparedBossAssets,$preparedUiAssets,(Join-Path $PinnedRuntimeRoot 'cache\local-locale'))) {
    Assert-Repair (Test-Path -LiteralPath $path -PathType Container) `
        'phase_d_application_repair_member_missing'
}
$assetReceipt = Get-Content -LiteralPath $preparedAssetReceipt -Raw | ConvertFrom-Json
$preparedCharacterAssetCount = @(Get-ChildItem -LiteralPath $preparedCharacterAssets -File -Filter '*.png').Count
$preparedBossAssetCount = @(Get-ChildItem -LiteralPath $preparedBossAssets -File -Filter '*.png').Count
$preparedUiAssetCount = @(Get-ChildItem -LiteralPath $preparedUiAssets -File -Filter '*.png').Count
Assert-Repair `
    ($assetReceipt.contractId -ceq 'nll/phase-d-presentation-assets/v1' -and
     $assetReceipt.rawGameResourceIdentifierPersisted -eq $false -and
     $assetReceipt.officialInstallModified -eq $false -and
     $preparedCharacterAssetCount -eq [int]$assetReceipt.characterAssetCount -and
     $preparedBossAssetCount -eq 3 -and
     $preparedUiAssetCount -eq [int]$assetReceipt.uiAssetCount -and
     $preparedUiAssetCount -ge 25) `
    'phase_d_application_repair_presentation_assets_invalid'
$startText = Get-Content -LiteralPath $sourceStart -Raw
Assert-Repair `
    ($startText.Contains("'--phase-d-control-center','true'")) `
    'phase_d_application_repair_start_mode_missing'

$repairUid = [guid]::NewGuid().ToString('D')
$repairRoot = Join-Path $InstallRoot ('staging\application-repairs\' + $repairUid)
$beforeRoot = Join-Path $repairRoot 'before'
$receiptRoot = Join-Path $InstallRoot ('source-free\application-repairs\' + $repairUid)
New-Item -ItemType Directory -Path $beforeRoot,$receiptRoot -Force | Out-Null
Copy-Item -LiteralPath $installedDll -Destination (Join-Path $beforeRoot 'NikkeLocalLab.Admin.Api.dll')
Copy-Item -LiteralPath $installedStart -Destination (Join-Path $beforeRoot 'Start-NLL-ControlCenter.ps1')
Copy-Item -LiteralPath $installedStop -Destination (Join-Path $beforeRoot 'Stop-NLL-ControlCenter.ps1')
if (Test-Path -LiteralPath (Join-Path $InstallRoot 'app\wwwroot\editor')) {
    Copy-Item -LiteralPath (Join-Path $InstallRoot 'app\wwwroot\editor') `
        -Destination (Join-Path $beforeRoot 'editor') -Recurse
}
if (Test-Path -LiteralPath $installedPdb -PathType Leaf) {
    Copy-Item -LiteralPath $installedPdb -Destination (Join-Path $beforeRoot 'NikkeLocalLab.Admin.Api.pdb')
}
$materializerBeforeRoot = Join-Path $beforeRoot 'runtime-materializer'
New-Item -ItemType Directory -Path $materializerBeforeRoot -Force | Out-Null
foreach ($leaf in $materializerLeaves) {
    $currentMaterializerMember = Join-Path $materializerArtifactRoot $leaf
    if (Test-Path -LiteralPath $currentMaterializerMember -PathType Leaf) {
        Copy-Item -LiteralPath $currentMaterializerMember -Destination $materializerBeforeRoot
    }
}
$weaknessVariantBeforeRoot = Join-Path $beforeRoot 'weakness-variant-server'
if (Test-Path -LiteralPath $weaknessVariantArtifactRoot -PathType Container) {
    Copy-Item -LiteralPath $weaknessVariantArtifactRoot `
        -Destination $weaknessVariantBeforeRoot -Recurse
}

$priorDllSha256 = Get-Sha256Lower $installedDll
$priorStartSha256 = Get-Sha256Lower $installedStart
$priorStopSha256 = Get-Sha256Lower $installedStop
$priorMaterializerSha256 = if (Test-Path -LiteralPath (Join-Path $materializerArtifactRoot $materializerLeaves[0]) -PathType Leaf) {
    Get-Sha256Lower (Join-Path $materializerArtifactRoot $materializerLeaves[0])
}
else { $null }
Get-ChildItem -LiteralPath $PreparedAppRoot -Force | Copy-Item `
    -Destination (Join-Path $InstallRoot 'app') -Recurse -Force
Copy-Item -LiteralPath $sourceStart -Destination $installedStart -Force
Copy-Item -LiteralPath $sourceStop -Destination $installedStop -Force
New-Item -ItemType Directory -Path $materializerArtifactRoot -Force | Out-Null
foreach ($leaf in $materializerLeaves) {
    Copy-Item -LiteralPath (Join-Path $MaterializerBuildRoot $leaf) `
        -Destination $materializerArtifactRoot -Force
}
New-Item -ItemType Directory -Path $weaknessVariantArtifactRoot -Force | Out-Null
Copy-Item -LiteralPath $weaknessVariantServerDll `
    -Destination (Join-Path $weaknessVariantArtifactRoot 'EpinelPS.dll') -Force
Copy-Item -LiteralPath $WeaknessVariantSourceManifestPath `
    -Destination (Join-Path $weaknessVariantArtifactRoot 'source.manifest.tsv') -Force
Assert-Repair `
    ((Get-Sha256Lower (Join-Path $weaknessVariantArtifactRoot 'EpinelPS.dll')) -ceq `
        $expectedWeaknessVariantServerDllSha256 -and
     (Get-Sha256Lower (Join-Path $weaknessVariantArtifactRoot 'source.manifest.tsv')) -ceq `
        $expectedWeaknessVariantSourceManifestSha256) `
    'phase_d_application_repair_weakness_variant_copy_failed'

$pgCtl = 'C:\NLL\Runtime\PostgreSQL-17-native\bin\pg_ctl.exe'
$pgData = Join-Path $InstallRoot 'postgresql\data'
$pgLog = Join-Path $InstallRoot 'logs\postgresql.log'
$databasePassword = Unprotect-RepairSecret (Join-Path $InstallRoot 'secrets\database-password.dpapi')
$identitySecret = Unprotect-RepairSecret (Join-Path $InstallRoot 'secrets\identity-secret.dpapi')
$presentationRoot = Join-Path $repairRoot 'presentation-exporter'
$presentationOutput = Join-Path $repairRoot 'presentation.json'
$presentationSupportAssets = Join-Path $repairRoot 'support-assets'
$presentationExitCode = $null
$presentationCharacterCount = 0
$presentationConsoleKindCount = 0
$postgresStarted = $false
try {
    New-Item -ItemType Directory -Path $presentationRoot -Force | Out-Null
    Get-ChildItem -LiteralPath $MaterializerBuildRoot -File | Copy-Item -Destination $presentationRoot -Force
    Get-ChildItem -LiteralPath $PinnedRuntimeRoot -File -Filter '*.dll' | Copy-Item -Destination $presentationRoot -Force
    Copy-Item -LiteralPath (Join-Path $PinnedRuntimeRoot 'gameconfig.json') -Destination $presentationRoot -Force
    $presentationLocale = Join-Path $presentationRoot 'cache\local-locale'
    New-Item -ItemType Directory -Path $presentationLocale -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $presentationRoot 'cache\prdenv') `
        -Target (Join-Path $PinnedRuntimeRoot 'cache\prdenv') | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $PinnedRuntimeRoot 'cache\local-locale') -File | Copy-Item -Destination $presentationLocale
    $cubeLocaleRoot = 'C:\NLL\Clients\NIKKE-150.6.9-Physical\Unity\com_proximabeta_NIKKE\saus\saus\lss'
    foreach ($leaf in @('Locale_Skill.lsc', 'Locale_System.lsc')) {
        Copy-Item -LiteralPath (Join-Path $cubeLocaleRoot $leaf) -Destination $presentationLocale -Force
    }
    $env:NIKKE_LAB_DB = "Host=127.0.0.1;Port=$DatabasePort;Database=nll_control_center;Username=nll_control_center;Password=$databasePassword;SSL Mode=Disable;Include Error Detail=false"
    $env:NIKKE_LAB_ID_SECRET = $identitySecret
    $pgStartExit = Invoke-RepairPgCtl @('start','-D',$pgData,'-l',$pgLog,'-w','-t','60')
    Assert-Repair ($pgStartExit -eq 0) 'phase_d_application_repair_postgresql_start_failed'
    $postgresStarted = $true
    $presentationStdout = Join-Path $repairRoot 'presentation-export.stdout.log'
    $presentationStderr = Join-Path $repairRoot 'presentation-export.stderr.log'
    $presentationProcess = Start-Process `
        -FilePath (Join-Path $presentationRoot 'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe') `
        -ArgumentList @(
            '--export-presentation-catalog', $presentationOutput,
            '--presentation-support-asset-root', $presentationSupportAssets,
            '--connection-string-env', 'NIKKE_LAB_DB',
            '--identity-secret-env', 'NIKKE_LAB_ID_SECRET') `
        -RedirectStandardOutput $presentationStdout `
        -RedirectStandardError $presentationStderr `
        -WindowStyle Hidden -PassThru
    $presentationProcess.WaitForExit()
    $presentationProcess.Refresh()
    $presentationExitCode = $presentationProcess.ExitCode
    # Windows PowerShell 5.1 can leave ExitCode unavailable ($null) for this
    # redirected self-contained child even after WaitForExit/Refresh. Treat it
    # as advisory and admit only after the catalog and support-asset contracts
    # below have all passed.
    Assert-Repair (Test-Path -LiteralPath $presentationOutput -PathType Leaf) `
        'phase_d_application_repair_presentation_export_failed'
    $presentation = Get-Content -LiteralPath $presentationOutput -Raw | ConvertFrom-Json
    $presentationCharacterCount = @($presentation.characters).Count
    $presentationConsoleKindCount = @($presentation.consoles.coordinateCode | Sort-Object -Unique).Count
    Assert-Repair `
        ($presentation.contractId -ceq 'nll/control-center-presentation/v1' -and
         $presentationCharacterCount -gt 0 -and
         $presentationConsoleKindCount -eq 9 -and
         $presentation.rawSourceIdentifierPersisted -eq $false -and
         $presentation.officialOutboundUsed -eq $false) `
        'phase_d_application_repair_presentation_contract_invalid'
    Assert-Repair ($presentationCharacterCount -eq $preparedCharacterAssetCount) `
        'phase_d_application_repair_presentation_asset_count_mismatch'
    $supportAssetReceiptPath = Join-Path $presentationSupportAssets 'support-assets.receipt.json'
    Assert-Repair (Test-Path -LiteralPath $supportAssetReceiptPath -PathType Leaf) `
        'phase_d_application_repair_support_asset_receipt_missing'
    $supportAssetReceipt = Get-Content -LiteralPath $supportAssetReceiptPath -Raw | ConvertFrom-Json
    $presentationSupportAssetCount = `
        @(Get-ChildItem -LiteralPath $presentationSupportAssets -File -Filter '*.webp' -Recurse).Count
    Assert-Repair `
        ($supportAssetReceipt.contractId -ceq 'nll/phase-d-presentation-support-assets/v1' -and
         $supportAssetReceipt.rawGameResourceIdentifierPersisted -eq $false -and
         $presentationSupportAssetCount -eq [int]$supportAssetReceipt.assetCount -and
         $presentationSupportAssetCount -gt 0) `
        'phase_d_application_repair_support_assets_invalid'
}
finally {
    if ($postgresStarted) {
        $pgStopExit = Invoke-RepairPgCtl @('stop','-D',$pgData,'-m','fast','-w','-t','60')
        Assert-Repair ($pgStopExit -eq 0) 'phase_d_application_repair_postgresql_stop_failed'
    }
    foreach ($name in @('NIKKE_LAB_DB','NIKKE_LAB_ID_SECRET')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    $databasePassword = $null
    $identitySecret = $null
}
Copy-Item -LiteralPath $presentationOutput `
    -Destination (Join-Path $InstallRoot 'app\wwwroot\editor\presentation.json') -Force
$installedAssetRoot = Join-Path $InstallRoot 'app\wwwroot\editor\assets'
New-Item -ItemType Directory `
    -Path (Join-Path $installedAssetRoot 'characters'),(Join-Path $installedAssetRoot 'bosses'),(Join-Path $installedAssetRoot 'ui'),(Join-Path $installedAssetRoot 'equipment'),(Join-Path $installedAssetRoot 'collections') `
    -Force | Out-Null
Get-ChildItem -LiteralPath $preparedCharacterAssets -File -Filter '*.png' | Copy-Item `
    -Destination (Join-Path $installedAssetRoot 'characters') -Force
Get-ChildItem -LiteralPath $preparedBossAssets -File -Filter '*.png' | Copy-Item `
    -Destination (Join-Path $installedAssetRoot 'bosses') -Force
Get-ChildItem -LiteralPath $preparedUiAssets -File -Filter '*.png' | Copy-Item `
    -Destination (Join-Path $installedAssetRoot 'ui') -Force
Get-ChildItem -LiteralPath (Join-Path $presentationSupportAssets 'equipment') -File -Filter '*.webp' | Copy-Item `
    -Destination (Join-Path $installedAssetRoot 'equipment') -Force
Get-ChildItem -LiteralPath (Join-Path $presentationSupportAssets 'collections') -File -Filter '*.webp' | Copy-Item `
    -Destination (Join-Path $installedAssetRoot 'collections') -Force
New-Item -ItemType Directory -Path (Join-Path $installedAssetRoot 'cubes') -Force | Out-Null
Get-ChildItem -LiteralPath (Join-Path $presentationSupportAssets 'cubes') -File -Filter '*.webp' | Copy-Item `
    -Destination (Join-Path $installedAssetRoot 'cubes') -Force

# Optional for legacy asset packages; the UI keeps text/levels if absent.
# New presentation packages materialize these nine original game item icons.
$preparedConsoleAssets = Join-Path $PreparedPresentationAssetsRoot 'consoles'
if (Test-Path -LiteralPath $preparedConsoleAssets -PathType Container) {
    $installedConsoleAssets = Join-Path $installedAssetRoot 'consoles'
    New-Item -ItemType Directory -Path $installedConsoleAssets -Force | Out-Null
    foreach ($code in @('common','attacker','defender','supporter','elysion','missilis','tetra','pilgrim','abnormal')) {
        $icon = Join-Path $preparedConsoleAssets ($code + '.webp')
        if (Test-Path -LiteralPath $icon -PathType Leaf) {
            Copy-Item -LiteralPath $icon -Destination (Join-Path $installedConsoleAssets ($code + '.webp')) -Force
        }
    }
}

$desktopInstallRoot = Join-Path $InstallRoot 'desktop'
New-Item -ItemType Directory -Path $desktopInstallRoot -Force | Out-Null
Get-ChildItem -LiteralPath $PreparedDesktopRoot -Force | Copy-Item `
    -Destination $desktopInstallRoot -Recurse -Force
$desktopExe = Join-Path $desktopInstallRoot 'NLL Control Center.exe'
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'NLL 지휘관 관리 도구.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $desktopExe
$shortcut.WorkingDirectory = $desktopInstallRoot
$shortcut.Description = 'NLL 지휘관 관리 도구'
$shortcut.IconLocation = $desktopExe + ',0'
$shortcut.Save()

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase-d-control-center-application-repair/v1'
    repairedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    repairUid = $repairUid
    deploymentReceiptSha256 = Get-Sha256Lower $deploymentPath
    causeCode = 'browser_debug_surface_not_operator_usable'
    recoveryCode = 'blabla_style_native_desktop_unified_save_uid_import_and_local_presentation_assets'
    priorAppDllSha256 = $priorDllSha256
    repairedAppDllSha256 = Get-Sha256Lower $installedDll
    priorStartSha256 = $priorStartSha256
    repairedStartSha256 = Get-Sha256Lower $installedStart
    priorStopSha256 = $priorStopSha256
    repairedStopSha256 = Get-Sha256Lower $installedStop
    orphanRecoveryScriptSha256 = Get-Sha256Lower $sourceRecovery
    priorMaterializerSha256 = $priorMaterializerSha256
    repairedMaterializerSha256 = Get-Sha256Lower `
        (Join-Path $materializerArtifactRoot $materializerLeaves[0])
    weaknessVariantServerDllSha256 = Get-Sha256Lower `
        (Join-Path $weaknessVariantArtifactRoot 'EpinelPS.dll')
    weaknessVariantSourceManifestSha256 = Get-Sha256Lower `
        (Join-Path $weaknessVariantArtifactRoot 'source.manifest.tsv')
    weaknessVariantSourceFileCount = $weaknessVariantSourceRows.Count
    repairedEditorSha256 = Get-Sha256Lower (Join-Path $InstallRoot 'app\wwwroot\editor\editor.js')
    presentationCatalogSha256 = Get-Sha256Lower (Join-Path $InstallRoot 'app\wwwroot\editor\presentation.json')
    presentationExporterExitCode = $presentationExitCode
    presentationExporterExitCodeObserved = $null -ne $presentationExitCode
    presentationExporterExitCodeAdvisory = $true
    presentationCompletionAuthority = 'validated_catalog_and_support_asset_contracts'
    presentationCharacterCount = $presentationCharacterCount
    presentationConsoleKindCount = $presentationConsoleKindCount
    presentationAssetReceiptSha256 = Get-Sha256Lower $preparedAssetReceipt
    presentationCharacterAssetCount = $preparedCharacterAssetCount
    presentationBossAssetCount = $preparedBossAssetCount
    presentationUiAssetCount = $preparedUiAssetCount
    presentationSupportAssetCount = $presentationSupportAssetCount
    presentationSupportAssetReceiptSha256 = Get-Sha256Lower (Join-Path $presentationSupportAssets 'support-assets.receipt.json')
    desktopExeSha256 = Get-Sha256Lower $desktopExe
    desktopApplicationIconSourceSha256 = Get-Sha256Lower $sourceDesktopIcon
    desktopShortcutCreated = Test-Path -LiteralPath $shortcutPath -PathType Leaf
    desktopShortcutIconConfigured = $shortcut.IconLocation -ceq ($desktopExe + ',0')
    historicalRaidCatalogModified = $false
    persistentDatabaseModified = $false
    goldenModified = $false
    parentV8Modified = $false
    officialInstallModified = $false
    dBackupModified = $false
    runtimeColdAfterRepair = $true
    supportedSeasonBaseline = 26
    additionalSeasonScope = @(29,34)
    excludedHistoricalSeasons = @(7,13,40)
    rollbackCode = 'restore_app_start_and_materializer_before_images_from_install_staging'
    nextStepCode = 'run_phase_d_control_center_installation_smoke'
}
$receiptPath = Join-Path $receiptRoot 'repair.receipt.json'
Write-RepairJson $receiptPath $receipt
[pscustomobject]@{
    Receipt = $receipt
    ReceiptPath = $receiptPath
    ReceiptSha256 = Get-Sha256Lower $receiptPath
} | ConvertTo-Json -Depth 10
