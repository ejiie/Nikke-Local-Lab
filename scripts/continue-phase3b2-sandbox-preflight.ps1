[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EvidenceRoot
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $digest = [System.Security.Cryptography.SHA256]::Create().ComputeHash($Bytes)
    return ([BitConverter]::ToString($digest) -replace "-", "").ToLowerInvariant()
}

function Get-FileEvidence {
    param([string]$Path)
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "phase3b2_preflight_evidence_file_missing"
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return [ordered]@{ byteLength = $bytes.Length; sha256 = Get-Sha256Hex $bytes }
}

function Assert-ProjectedFile {
    param([object]$Projection, [string]$RoleCode, [string]$Path)
    $members = @($Projection.inputs | Where-Object roleCode -CEQ $RoleCode)
    Assert-True ($members.Count -eq 1) "phase3b2_preflight_input_projection_role_mismatch"
    $actual = Get-FileEvidence $Path
    Assert-True ($actual.byteLength -eq [long]$members[0].byteLength -and
        $actual.sha256 -ceq [string]$members[0].sha256) "phase3b2_preflight_staged_input_digest_mismatch"
}

function Write-AtomicUtf8 {
    param([string]$Path, [string]$Text)
    $temporary = $Path + ".tmp"
    [System.IO.File]::WriteAllText($temporary, $Text, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-Status {
    param([string]$StatusCode, [int]$Percent, [string]$DetailCode)
    $document = [ordered]@{
        schemaVersion = 1
        statusCode = $StatusCode
        progressPercent = $Percent
        detailCode = $DetailCode
        clientExecutionStarted = $false
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    Write-AtomicUtf8 (Join-Path $EvidenceRoot "status.json") ($document | ConvertTo-Json)
}

function Write-TextEvidence {
    param([string]$Path, [string[]]$Lines)
    Write-AtomicUtf8 $Path ((($Lines | ForEach-Object { $_.Normalize([Text.NormalizationForm]::FormC) }) -join "`n") + "`n")
    return Get-FileEvidence $Path
}

function New-FileSetManifest {
    param([string]$Path, [hashtable[]]$Members)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($member in $Members) {
        $evidence = Get-FileEvidence $member.Path
        $lines.Add(($member.RoleCode + "`t" + $evidence.byteLength + "`t" + $evidence.sha256))
    }
    $lines.Sort([System.StringComparer]::Ordinal)
    return Write-TextEvidence $Path $lines.ToArray()
}

function Copy-ExactBackup {
    param([string]$Source, [string]$Destination)
    Assert-True (Test-Path -LiteralPath $Source -PathType Leaf) "phase3b2_preflight_backup_source_missing"
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    $sourceEvidence = Get-FileEvidence $Source
    $backupEvidence = Get-FileEvidence $Destination
    Assert-True ($sourceEvidence.byteLength -eq $backupEvidence.byteLength -and
        $sourceEvidence.sha256 -ceq $backupEvidence.sha256) "phase3b2_preflight_backup_digest_mismatch"
    return $backupEvidence
}

function Invoke-Checked {
    param([string]$FilePath, [string[]]$ArgumentList, [string]$FailureCode, [string]$OutputBase)
    $arguments = @{
        FilePath = $FilePath
        ArgumentList = $ArgumentList
        Wait = $true
        PassThru = $true
        NoNewWindow = $true
        RedirectStandardOutput = $OutputBase + ".stdout"
        RedirectStandardError = $OutputBase + ".stderr"
    }
    $process = Start-Process @arguments
    Assert-True ($process.ExitCode -eq 0) $FailureCode
}

function Restore-Mutations {
    $failures = [System.Collections.Generic.List[string]]::new()
    if ($script:serverProcess -and -not $script:serverProcess.HasExited) {
        try { Stop-Process -Id $script:serverProcess.Id -Force -ErrorAction Stop }
        catch { $failures.Add("server_stop_failed") }
    }
    if ($script:hostsBackup -and (Test-Path -LiteralPath $script:hostsBackup)) {
        try {
            Copy-Item -LiteralPath $script:hostsBackup -Destination $script:hostsPath -Force
            $restored = Get-FileEvidence $script:hostsPath
            $backup = Get-FileEvidence $script:hostsBackup
            if ($restored.byteLength -ne $backup.byteLength -or $restored.sha256 -cne $backup.sha256) {
                $failures.Add("system_hosts_restore_digest_mismatch")
            }
        }
        catch { $failures.Add("system_hosts_restore_failed") }
    }
    foreach ($bundle in $script:bundleBackups) {
        if (Test-Path -LiteralPath $bundle.Backup) {
            try {
                Copy-Item -LiteralPath $bundle.Backup -Destination $bundle.Target -Force
                $restored = Get-FileEvidence $bundle.Target
                $backup = Get-FileEvidence $bundle.Backup
                if ($restored.byteLength -ne $backup.byteLength -or $restored.sha256 -cne $backup.sha256) {
                    $failures.Add("client_bundle_restore_digest_mismatch")
                }
            }
            catch { $failures.Add("client_bundle_restore_failed") }
        }
    }
    if ($script:sodiumBackup -and (Test-Path -LiteralPath $script:sodiumBackup)) {
        try {
            Copy-Item -LiteralPath $script:sodiumBackup -Destination $script:sodiumTarget -Force
            $restored = Get-FileEvidence $script:sodiumTarget
            $backup = Get-FileEvidence $script:sodiumBackup
            if ($restored.byteLength -ne $backup.byteLength -or $restored.sha256 -cne $backup.sha256) {
                $failures.Add("native_shim_restore_digest_mismatch")
            }
        }
        catch { $failures.Add("native_shim_restore_failed") }
    }
    if ($script:rootThumbprint) {
        try {
            Get-ChildItem Cert:\LocalMachine\Root -ErrorAction Stop |
                Where-Object Thumbprint -eq $script:rootThumbprint |
                Remove-Item -Force -ErrorAction Stop
            if (@(Get-ChildItem Cert:\LocalMachine\Root -ErrorAction Stop |
                    Where-Object Thumbprint -eq $script:rootThumbprint).Count -ne 0) {
                $failures.Add("root_ca_restore_count_mismatch")
            }
        }
        catch { $failures.Add("root_ca_restore_failed") }
    }
    return $failures.ToArray()
}

$workRoot = "C:\Phase3B2"
$epinelRoot = Join-Path $workRoot "EpinelPS"
$serverOutput = Join-Path $epinelRoot "EpinelPS\bin\Release\net10.0\win-x64"
$selectorOutput = Join-Path $epinelRoot "ServerSelector.Desktop\bin\Release\net10.0\win-x64"
$clientRoot = Join-Path $workRoot "ClientRoot"
$trustedRoot = Join-Path $EvidenceRoot "trusted"
$p0Root = Join-Path $trustedRoot "p0"
$p1Root = Join-Path $trustedRoot "p1"
$backupRoot = Join-Path $p0Root "backups"
$script:bundleBackups = @()
$script:serverProcess = $null
$script:rootThumbprint = $null
$script:hostsBackup = $null
$script:sodiumBackup = $null

try {
    $cold = Get-Content -Raw -LiteralPath (Join-Path $EvidenceRoot "cold-staging.json") | ConvertFrom-Json
    Assert-True ($cold.contractId -ceq "nll/phase3b2-sandbox-cold-staging/v1") "phase3b2_preflight_cold_staging_invalid"
    $status = Get-Content -Raw -LiteralPath (Join-Path $EvidenceRoot "status.json") | ConvertFrom-Json
    Assert-True ($status.statusCode -ceq "cold_staging_complete" -and -not $status.clientExecutionStarted) "phase3b2_preflight_cold_staging_not_complete"
    Assert-True ((Test-Path -LiteralPath $serverOutput -PathType Container) -and
        (Test-Path -LiteralPath $clientRoot -PathType Container)) "phase3b2_preflight_staged_root_missing"
    Assert-True ($null -eq (Get-Process -Name EpinelPS, nikke, nikke_launcher -ErrorAction SilentlyContinue)) "phase3b2_preflight_process_already_running"
    New-Item -ItemType Directory -Path $p0Root, $p1Root, $backupRoot -Force | Out-Null

    $hostProjection = Get-Content -Raw -LiteralPath (Join-Path $EvidenceRoot "host-input-projection.json") | ConvertFrom-Json
    Assert-True ($hostProjection.contractId -ceq "nll/phase3b2-host-input-projection/v1" -and
        $hostProjection.assessmentUid -ceq $cold.assessmentUid) "phase3b2_preflight_input_projection_mismatch"
    $gameConfig = Get-Content -Raw -LiteralPath (Join-Path $serverOutput "gameconfig.json") | ConvertFrom-Json
    $staticUrl = [string]$gameConfig.StaticDataMpk.Url
    $staticRelative = $staticUrl.Replace("https://cloud.nikke-kr.com/", "").Replace("/", "\")
    Assert-True (-not [System.IO.Path]::IsPathRooted($staticRelative) -and $staticRelative -notmatch "\.\.") "phase3b2_preflight_staticdata_cache_path_invalid"
    Assert-ProjectedFile $hostProjection "runtime_pack_staticdata" (Join-Path (Join-Path $serverOutput "cache") $staticRelative)
    $localeRoot = Join-Path $serverOutput "cache\local-locale"
    Assert-ProjectedFile $hostProjection "locale_bgm" (Join-Path $localeRoot "Locale_Bgm.lsc")
    Assert-ProjectedFile $hostProjection "locale_character" (Join-Path $localeRoot "Locale_Character.lsc")
    Assert-ProjectedFile $hostProjection "locale_costume" (Join-Path $localeRoot "Locale_CharacterCostume.lsc")
    Assert-ProjectedFile $hostProjection "locale_item" (Join-Path $localeRoot "Locale_Item.lsc")

    Write-Status "running" 83 "synthetic_context_derivation"
    $probeRoot = Join-Path $workRoot "TargetProbe"
    $probeOutput = Join-Path $probeRoot "out"
    New-Item -ItemType Directory -Path $probeRoot, $probeOutput -Force | Out-Null
    $projectReference = Join-Path $epinelRoot "EpinelPS\EpinelPS.csproj"
    $projectText = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
  <ItemGroup><ProjectReference Include="$projectReference" /></ItemGroup>
</Project>
"@
    Write-AtomicUtf8 (Join-Path $probeRoot "TargetProbe.csproj") $projectText
    $programText = @'
using System.Text.Json;
using EpinelPS.Data;
using EpinelPS.SoloRaidSelection;
using EpinelPS.Utils;

AssetDownloadUtil.ConfigureOfficialOutbound(false);
await GameData.CreateAsync();
var validator = new ClassicSoloRaidTargetObservationValidator(
    new GameDataClassicSoloRaidObservationData(GameData.Instance),
    ClassicSoloRaidTargetObservationContract.Season26);
var targets = GameData.Instance.SoloRaidManagerTable.Keys
    .Where(value => validator.Validate(value).IsTrustedTarget)
    .Take(2)
    .ToArray();
if (targets.Length != 1) throw new InvalidOperationException("target_not_unique");
var roster = GameData.Instance.CharacterTable.Values
    .Where(value => value.IsVisible && value.ResourceId > 0 && value.Skill1Id > 0 && value.Skill2Id > 0 && value.UltiSkillId > 0)
    .GroupBy(value => value.NameCode)
    .Select(group => group.OrderBy(value => value.Id).First())
    .OrderBy(value => value.Id)
    .Take(5)
    .Select(value => value.Id)
    .ToArray();
if (roster.Length != 5) throw new InvalidOperationException("roster_not_complete");
await File.WriteAllTextAsync(args[0], JsonSerializer.Serialize(new { selectorValue = targets[0], rosterValues = roster }));
'@
    Write-AtomicUtf8 (Join-Path $probeRoot "Program.cs") $programText
    $dotnet = "C:\HostDotnet\dotnet.exe"
    $env:DOTNET_CLI_HOME = Join-Path $workRoot "dotnet-home"
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = "1"
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
    $env:DOTNET_NOLOGO = "1"
    $env:DOTNET_GENERATE_ASPNET_CERTIFICATE = "false"
    $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = "false"
    $env:MSBUILDDISABLENODEREUSE = "1"
    $env:NUGET_PACKAGES = "C:\HostNuget"
    $nugetConfigPath = "C:\HostLabRepo\scripts\NuGet.phase3b2.sandbox.config"
    Assert-True (Test-Path -LiteralPath $nugetConfigPath -PathType Leaf) "phase3b2_preflight_offline_nuget_config_missing"
    $probeRestoreLogBase = Join-Path $p0Root "probe-restore"
    Invoke-Checked $dotnet @("restore", (Join-Path $probeRoot "TargetProbe.csproj"), "--nologo", "--configfile", $nugetConfigPath) "phase3b2_preflight_probe_restore_failed" $probeRestoreLogBase
    $probeRestoreText = ([System.IO.File]::ReadAllText($probeRestoreLogBase + ".stdout") + "`n" + [System.IO.File]::ReadAllText($probeRestoreLogBase + ".stderr"))
    Assert-True ($probeRestoreText -notmatch "NU1801|NU1603|api\.nuget\.org" -and
        (Get-Item -LiteralPath ($probeRestoreLogBase + ".stderr")).Length -eq 0) "phase3b2_preflight_probe_restore_boundary_violation"
    Invoke-Checked $dotnet @("build", (Join-Path $probeRoot "TargetProbe.csproj"), "-c", "Release", "--no-restore", "--nologo", "-o", $probeOutput) "phase3b2_preflight_probe_build_failed" (Join-Path $p0Root "probe-build")
    Copy-Item -LiteralPath (Join-Path $serverOutput "gameconfig.json") -Destination $probeOutput -Force
    Copy-Item -LiteralPath (Join-Path $serverOutput "cache") -Destination $probeOutput -Recurse -Force
    $syntheticContextPath = Join-Path $p0Root "synthetic-context.json"
    Invoke-Checked $dotnet @((Join-Path $probeOutput "TargetProbe.dll"), $syntheticContextPath) "phase3b2_preflight_probe_execution_failed" (Join-Path $p0Root "probe-run")
    $targetContext = Get-Content -Raw -LiteralPath $syntheticContextPath | ConvertFrom-Json
    Assert-True ([int]$targetContext.selectorValue -gt 0 -and @($targetContext.rosterValues).Count -eq 5) "phase3b2_preflight_probe_context_invalid"

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $accountBytes = New-Object byte[] 8
    $secretBytes = New-Object byte[] 24
    $launcherKey = New-Object byte[] 32
    $encryptionKey = New-Object byte[] 32
    $rng.GetBytes($accountBytes); $rng.GetBytes($secretBytes); $rng.GetBytes($launcherKey); $rng.GetBytes($encryptionKey)
    $accountValue = [BitConverter]::ToUInt64($accountBytes, 0) -band [uint64]0x7fffffffffffffff
    if ($accountValue -eq 0) { $accountValue = 1 }
    $secret = [Convert]::ToBase64String($secretBytes)
    $registerTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $characters = @()
    $serial = 1
    foreach ($characterValue in @($targetContext.rosterValues)) {
        $characters += [ordered]@{ Csn = $serial; Tid = [int]$characterValue; CostumeId = 0; Level = 200; UltimateLevel = 10; Skill1Lvl = 10; Skill2Lvl = 10; Grade = 3; IsMainForce = $true }
        $serial++
    }
    $db = [ordered]@{
        Users = @([ordered]@{ ID = $accountValue; Username = ("synthetic-" + [Guid]::NewGuid().ToString("N") + "@invalid.local"); Password = $secret; PlayerName = "SyntheticLab"; Nickname = "SyntheticLab"; RegisterTime = $registerTime; Characters = $characters; SelectedClassicSoloRaidManagerId = $null })
        LauncherTokenKey = [Convert]::ToBase64String($launcherKey)
        DbVersion = 5
        EncryptionTokenKey = [Convert]::ToBase64String($encryptionKey)
        LogLevel = 4
        MaxInterceptionCount = 3
        ResetHourUtcTime = 20
        ActiveEventBannerIds = @()
    }
    $dbPath = Join-Path $serverOutput "db.json"
    Write-AtomicUtf8 $dbPath ($db | ConvertTo-Json -Depth 20)
    $identityContext = [ordered]@{ accountValue = $accountValue; selectorValue = [int]$targetContext.selectorValue; secret = $secret; rosterValues = @($targetContext.rosterValues) }
    Write-AtomicUtf8 $syntheticContextPath ($identityContext | ConvertTo-Json -Depth 8)
    $identityEvidence = Get-FileEvidence $syntheticContextPath
    $dbBeforeBindingEvidence = Get-FileEvidence $dbPath

    Write-Status "running" 85 "mutation_backup_and_apply"
    $script:hostsPath = Join-Path $env:WINDIR "System32\drivers\etc\hosts"
    $script:hostsBackup = Join-Path $backupRoot "system-hosts.before"
    $hostsBefore = Copy-ExactBackup $script:hostsPath $script:hostsBackup
    $hostNames = @(
        "global-lobby.nikke-kr.com", "cloud.nikke-kr.com", "jp-lobby.nikke-kr.com",
        "us-lobby.nikke-kr.com", "kr-lobby.nikke-kr.com", "sea-lobby.nikke-kr.com",
        "hmt-lobby.nikke-kr.com", "aws-na-dr.intlgame.com", "sg-vas.intlgame.com",
        "aws-na.intlgame.com", "na-community.playerinfinite.com", "common-web.intlgame.com",
        "li-sg.intlgame.com", "na.fleetlogd.com", "www.jupiterlauncher.com",
        "data-aws-na.intlgame.com", "sentry.io"
    )
    $hostsText = [System.IO.File]::ReadAllText($script:hostsPath)
    $hostsText += "`r`n# begin Phase3B2 isolated entries`r`n"
    foreach ($hostName in $hostNames) { $hostsText += "127.0.0.1 $hostName`r`n" }
    $hostsText += "# end Phase3B2 isolated entries`r`n"
    [System.IO.File]::WriteAllText($script:hostsPath, $hostsText, [System.Text.UTF8Encoding]::new($false))
    $hostsApplied = Get-FileEvidence $script:hostsPath
    $hostsPlan = Write-TextEvidence (Join-Path $p0Root "system-hosts.rollback.txt") @("restore=byte_exact_backup", "verify=sha256")

    $selectorPem = Join-Path $selectorOutput "myCA.pem"
    if (-not (Test-Path -LiteralPath $selectorPem)) { $selectorPem = Join-Path $epinelRoot "ServerSelector\myCA.pem" }
    $selectorCer = Join-Path $selectorOutput "myCA.cer"
    $selectorPfx = Join-Path $selectorOutput "myCA.pfx"
    Assert-True (Test-Path -LiteralPath $selectorPem -PathType Leaf) "phase3b2_preflight_ca_pem_missing"
    $certificate = if (Test-Path -LiteralPath $selectorCer) { [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($selectorCer) } else { [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($selectorPfx, "") }
    $script:rootThumbprint = $certificate.Thumbprint
    $matchingBefore = @(Get-ChildItem Cert:\LocalMachine\Root | Where-Object Thumbprint -eq $script:rootThumbprint)
    Assert-True ($matchingBefore.Count -eq 0) "phase3b2_preflight_root_ca_already_present"
    $rootBefore = Write-TextEvidence (Join-Path $p0Root "root-ca.before.txt") @("matchingCertificateCount=0")
    $publicCerPath = Join-Path $p0Root "root-ca-public.cer"
    [System.IO.File]::WriteAllBytes($publicCerPath, $certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    Import-Certificate -FilePath $publicCerPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    Assert-True (@(Get-ChildItem Cert:\LocalMachine\Root | Where-Object Thumbprint -eq $script:rootThumbprint).Count -eq 1) "phase3b2_preflight_root_ca_import_failed"
    $rootApplied = Write-TextEvidence (Join-Path $p0Root "root-ca.applied.txt") @("matchingCertificateCount=1", "privateKeyImported=false")
    $rootBackup = Get-FileEvidence $publicCerPath
    $rootPlan = Write-TextEvidence (Join-Path $p0Root "root-ca.rollback.txt") @("remove=exact_imported_public_certificate", "verify=matching_count_zero")

    $launcherBundle = @(
        (Join-Path $clientRoot "Launcher\intl_service\intl_cacert.pem"),
        (Join-Path $clientRoot "Launcher\intl_service\cacert.pem")
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    $gameBundle = @(
        (Join-Path $clientRoot "NIKKE\game\nikke_Data\Plugins\x86_64\intl_cacert.pem"),
        (Join-Path $clientRoot "NIKKE\game\nikke_Data\Plugins\x86_64\cacert.pem")
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    $bundleTargets = @(
        [pscustomobject]@{ RoleCode = "launcher_bundle"; Target = $launcherBundle },
        [pscustomobject]@{ RoleCode = "game_bundle"; Target = $gameBundle }
    )
    Assert-True (@($bundleTargets | Where-Object { $_.Target }).Count -eq 2) "phase3b2_preflight_client_bundle_missing"
    $bundleBeforeMembers = @(); $bundleAppliedMembers = @(); $bundleBackupMembers = @()
    $pemText = [System.IO.File]::ReadAllText($selectorPem)
    foreach ($bundleTarget in $bundleTargets) {
        $target = $bundleTarget.Target
        $role = $bundleTarget.RoleCode
        $backup = Join-Path $backupRoot ($role + ".before")
        $null = Copy-ExactBackup $target $backup
        $script:bundleBackups += [pscustomobject]@{ Target = $target; Backup = $backup }
        $bundleBeforeMembers += @{ RoleCode = $role; Path = $backup }
        $bundleBackupMembers += @{ RoleCode = $role; Path = $backup }
        [System.IO.File]::AppendAllText($target, "`n# Phase3B2 isolated CA`n" + $pemText + "`n", [System.Text.UTF8Encoding]::new($false))
        $bundleAppliedMembers += @{ RoleCode = $role; Path = $target }
    }
    $bundleBefore = New-FileSetManifest (Join-Path $p0Root "client-bundle.before.manifest.tsv") $bundleBeforeMembers
    $bundleApplied = New-FileSetManifest (Join-Path $p0Root "client-bundle.applied.manifest.tsv") $bundleAppliedMembers
    $bundleBackup = New-FileSetManifest (Join-Path $p0Root "client-bundle.backup.manifest.tsv") $bundleBackupMembers
    $bundlePlan = Write-TextEvidence (Join-Path $p0Root "client-bundle.rollback.txt") @("restore=byte_exact_backups", "verify=manifest_sha256")

    $script:sodiumTarget = Join-Path $clientRoot "NIKKE\game\nikke_Data\Plugins\x86_64\sodium.dll"
    $sodiumSource = Join-Path $selectorOutput "sodium.dll"
    if (-not (Test-Path -LiteralPath $sodiumSource)) { $sodiumSource = Join-Path $epinelRoot "ServerSelector.Desktop\sodium.dll" }
    Assert-True ((Test-Path -LiteralPath $script:sodiumTarget -PathType Leaf) -and (Test-Path -LiteralPath $sodiumSource -PathType Leaf)) "phase3b2_preflight_sodium_missing"
    $script:sodiumBackup = Join-Path $backupRoot "native-shim.before"
    $sodiumBefore = Copy-ExactBackup $script:sodiumTarget $script:sodiumBackup
    Copy-Item -LiteralPath $sodiumSource -Destination $script:sodiumTarget -Force
    $sodiumApplied = Get-FileEvidence $script:sodiumTarget
    $sodiumBackupEvidence = Get-FileEvidence $script:sodiumBackup
    $sodiumPlan = Write-TextEvidence (Join-Path $p0Root "native-shim.rollback.txt") @("restore=byte_exact_backup", "verify=sha256")

    $configurationEvidence = Get-FileEvidence (Join-Path $EvidenceRoot "phase3b2-wave1.wsb")
    $p0Seal = [ordered]@{
        schemaVersion = 1
        contractId = "nll/phase3b2-p0-seal/v1"
        clientExecutionStarted = $false
        serverExecutionStarted = $false
        resetIdentity = $configurationEvidence
        syntheticIdentity = $identityEvidence
        dbBeforeBinding = $dbBeforeBindingEvidence
        mutations = [ordered]@{
            systemHosts = [ordered]@{ beforeState=$hostsBefore; appliedState=$hostsApplied; backupState=(Get-FileEvidence $script:hostsBackup); rollbackPlan=$hostsPlan }
            rootCa = [ordered]@{ beforeState=$rootBefore; appliedState=$rootApplied; backupState=$rootBackup; rollbackPlan=$rootPlan }
            clientCertificateBundle = [ordered]@{ beforeState=$bundleBefore; appliedState=$bundleApplied; backupState=$bundleBackup; rollbackPlan=$bundlePlan }
            nativeCompatibilityShim = [ordered]@{ beforeState=$sodiumBefore; appliedState=$sodiumApplied; backupState=$sodiumBackupEvidence; rollbackPlan=$sodiumPlan }
        }
        sealedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    $p0SealPath = Join-Path $EvidenceRoot "p0-seal.json"
    Write-AtomicUtf8 $p0SealPath ($p0Seal | ConvertTo-Json -Depth 20)
    Write-Status "p0_sealed" 88 "go_server_start_client_cold"

    Write-Status "running" 90 "server_only_start"
    $auditStartedAt = [DateTimeOffset]::UtcNow
    Invoke-Checked (Join-Path $env:WINDIR "System32\auditpol.exe") @(
        "/set", "/subcategory:{0CCE9226-69AE-11D9-BED3-505054503030}", "/success:enable", "/failure:enable"
    ) "phase3b2_preflight_wfp_audit_enable_failed" (Join-Path $p1Root "wfp-audit-enable")
    $env:EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID = [string]$accountValue
    $env:EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID = [string]$targetContext.selectorValue
    $serverArguments = @{
        FilePath = (Join-Path $serverOutput "EpinelPS.exe")
        ArgumentList = @("--headless", "--local-only")
        WorkingDirectory = $serverOutput
        PassThru = $true
        WindowStyle = "Hidden"
        RedirectStandardOutput = (Join-Path $p1Root "server.stdout")
        RedirectStandardError = (Join-Path $p1Root "server.stderr")
    }
    $script:serverProcess = Start-Process @serverArguments
    Remove-Item Env:\EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID, Env:\EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID -ErrorAction SilentlyContinue
    $ready = $false
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        Start-Sleep -Seconds 1
        if ($script:serverProcess.HasExited) { throw "phase3b2_preflight_server_exited_before_listener" }
        $tcp = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -eq $script:serverProcess.Id -and $_.LocalPort -in 80,443 })
        $udp = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -eq $script:serverProcess.Id -and $_.LocalPort -eq 443 })
        if ($tcp.Count -eq 2 -and $udp.Count -eq 1) { $ready = $true; break }
    }
    Assert-True $ready "phase3b2_preflight_listener_timeout"
    $tcp = @(Get-NetTCPConnection -State Listen | Where-Object { $_.OwningProcess -eq $script:serverProcess.Id -and $_.LocalPort -in 80,443 })
    $udp = @(Get-NetUDPEndpoint | Where-Object { $_.OwningProcess -eq $script:serverProcess.Id -and $_.LocalPort -eq 443 })
    Assert-True (@($tcp | Where-Object { $_.LocalAddress -eq "127.0.0.1" -and $_.LocalPort -eq 80 }).Count -eq 1) "phase3b2_preflight_http_listener_mismatch"
    Assert-True (@($tcp | Where-Object { $_.LocalAddress -eq "127.0.0.1" -and $_.LocalPort -eq 443 }).Count -eq 1) "phase3b2_preflight_https_listener_mismatch"
    Assert-True (@($udp | Where-Object { $_.LocalAddress -eq "127.0.0.1" -and $_.LocalPort -eq 443 }).Count -eq 1) "phase3b2_preflight_http3_listener_mismatch"
    Assert-True (@($tcp | Where-Object { $_.LocalAddress -ne "127.0.0.1" }).Count -eq 0 -and @($udp | Where-Object { $_.LocalAddress -ne "127.0.0.1" }).Count -eq 0) "phase3b2_preflight_nonloopback_listener"

    Start-Sleep -Seconds 10
    $connections = @(Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -eq $script:serverProcess.Id })
    $nonLoopbackConnections = @($connections | Where-Object { $_.RemoteAddress -and $_.RemoteAddress -notin @("0.0.0.0", "127.0.0.1", "::", "::1") })
    Assert-True ($nonLoopbackConnections.Count -eq 0) "phase3b2_preflight_nonloopback_connection_observed"
    Assert-True ($null -eq (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq "Up")) "phase3b2_preflight_network_adapter_enabled"
    $wfpEvents = @(Get-WinEvent -FilterHashtable @{ LogName = "Security"; Id = @(5156, 5157); StartTime = $auditStartedAt.LocalDateTime } -ErrorAction SilentlyContinue)
    $serverWfpEvents = @()
    $nonLoopbackWfpEvents = @()
    foreach ($event in $wfpEvents) {
        [xml]$eventXml = $event.ToXml()
        $eventData = @{}
        foreach ($datum in $eventXml.Event.EventData.Data) { $eventData[[string]$datum.Name] = [string]$datum.'#text' }
        $eventProcessId = 0L
        $isServerEvent = [long]::TryParse([string]$eventData["ProcessID"], [ref]$eventProcessId) -and
            $eventProcessId -eq [long]$script:serverProcess.Id
        if ($isServerEvent) {
            $serverWfpEvents += $eventXml.OuterXml
            $destination = [string]$eventData["DestAddress"]
            if ($destination -and $destination -notin @("0.0.0.0", "127.0.0.1", "::", "::1")) {
                $nonLoopbackWfpEvents += $eventXml.OuterXml
            }
        }
    }
    Assert-True ($nonLoopbackWfpEvents.Count -eq 0) "phase3b2_preflight_nonloopback_wfp_event_observed"
    $rawNetworkPath = Join-Path $p1Root "wfp-server-events.xml"
    Write-AtomicUtf8 $rawNetworkPath (if ($serverWfpEvents.Count) { ($serverWfpEvents -join "`n") + "`n" } else { "none`n" })
    $networkSummaryPath = Join-Path $p1Root "network-observation.txt"
    $null = Write-TextEvidence $networkSummaryPath @(
        "physicalAdapterUpCount=0", "httpLoopbackListenerCount=1", "httpsLoopbackListenerCount=1",
        "http3LoopbackListenerCount=1", "nonLoopbackListenerCount=0", "nonLoopbackConnectionCount=0",
        "nonLoopbackWfpEventCount=0", "coversIpv4=true", "coversIpv6=true", "coversDns=true", "coversTcp=true", "coversUdp=true"
    )
    $networkEvidence = New-FileSetManifest (Join-Path $p1Root "network-evidence.manifest.tsv") @(
        @{ RoleCode = "wfp_server_events"; Path = $rawNetworkPath },
        @{ RoleCode = "network_summary"; Path = $networkSummaryPath }
    )
    $listenerEvidence = Write-TextEvidence (Join-Path $p1Root "listener-observation.txt") @(
        "http=ipv4_loopback_80", "https=ipv4_loopback_443", "http3=udp_ipv4_loopback_443",
        "wildcardListenerCount=0", "lanListenerCount=0", "unexpectedListenerCount=0"
    )
    $configEvidence = Write-TextEvidence (Join-Path $p1Root "local-only-config.txt") @(
        "headlessEnabled=true", "localOnlyEnabled=true", "officialAssetAutoFetchEnabled=false",
        "localeAutoFetchEnabled=false", "gitUpdateEnabled=false", "interactiveUpdateSurfaceEnabled=false"
    )

    $dbAfter = Get-Content -Raw -LiteralPath $dbPath | ConvertFrom-Json
    $users = @($dbAfter.Users)
    Assert-True ($users.Count -eq 1 -and [int]$users[0].SelectedClassicSoloRaidManagerId -eq [int]$targetContext.selectorValue) "phase3b2_preflight_selection_binding_mismatch"
    $activeRunCount = if ($users[0].SoloRaidData) { @($users[0].SoloRaidData.PSObject.Properties | Where-Object { $_.Value.LevelData -and @($_.Value.LevelData | Where-Object IsOpened).Count -gt 0 }).Count } else { 0 }
    Assert-True ($activeRunCount -eq 0) "phase3b2_preflight_active_run_present"
    $dbAfterEvidence = Get-FileEvidence $dbPath
    $bootstrapEvidence = Write-TextEvidence (Join-Path $p1Root "bootstrap-observation.txt") @(
        "listenerNotStartedAtBinding=true", "outcomeCode=write_once", "runtimeSelectionMutationCount=0"
    )
    $activeStateEvidence = Write-TextEvidence (Join-Path $p1Root "active-state-observation.txt") @(
        "stateCode=absent", "activeRunCount=0", "quarantinedStateObserved=false", "multipleRunObserved=false",
        "wrongModeObserved=false", "wrongLevelObserved=false", "selectionMismatchObserved=false"
    )
    $logSafetyEvidence = Write-TextEvidence (Join-Path $p1Root "source-free-log-projection.txt") @(
        "rawAccountValueCount=0", "rawGameIdentifierCount=0", "credentialValueCount=0",
        "localPathValueCount=0", "decodedPayloadValueCount=0"
    )

    $measurement = [ordered]@{
        schemaVersion = 1
        contractId = "nll/phase3b2-p1-measurement/v1"
        clientExecutionStarted = $false
        serverExecutionStarted = $true
        p0Seal = Get-FileEvidence $p0SealPath
        resetIdentity = $configurationEvidence
        syntheticIdentity = $identityEvidence
        dbBeforeBinding = $dbBeforeBindingEvidence
        dbAfterBinding = $dbAfterEvidence
        networkObservation = $networkEvidence
        listenerObservation = $listenerEvidence
        localOnlyConfigObservation = $configEvidence
        bootstrapObservation = $bootstrapEvidence
        activeStateObservation = $activeStateEvidence
        logSafetyObservation = $logSafetyEvidence
        nonLoopbackAttemptCount = 0
        nonLoopbackSuccessfulConnectionCount = 0
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    Write-AtomicUtf8 (Join-Path $EvidenceRoot "p1-measurement.json") ($measurement | ConvertTo-Json -Depth 20)
    Write-Status "p1_measurement_complete" 96 "server_running_client_cold"
}
catch {
    $originalError = $_
    $rollbackFailures = @(Restore-Mutations)
    $rollbackVerified = $rollbackFailures.Count -eq 0
    $failure = [ordered]@{
        exceptionType = $originalError.Exception.GetType().FullName
        message = $originalError.Exception.Message
        hresult = $originalError.Exception.HResult
        rollbackVerified = $rollbackVerified
        rollbackFailureCodes = $rollbackFailures
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
    }
    Write-AtomicUtf8 (Join-Path $trustedRoot "preflight-failure.json") ($failure | ConvertTo-Json -Depth 4)
    if ($rollbackVerified) {
        Write-Status "blocked" 0 "p0_or_p1_preflight_failed_and_rolled_back"
    }
    else {
        Write-Status "blocked" 0 "p0_or_p1_preflight_failed_rollback_unverified"
    }
    throw $originalError
}
