[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PrimaryClientRoot,

    [Parameter(Mandatory = $true)]
    [string]$EpinelPsRoot,

    [Parameter(Mandatory = $true)]
    [string]$ProtectedInputRoot,

    [Parameter(Mandatory = $true)]
    [string]$EvidenceRoot,

    [string]$DotNetRoot = "$env:ProgramFiles\dotnet",
    [string]$GitRoot = "$env:ProgramFiles\Git",
    [string]$NuGetPackagesRoot = "$env:USERPROFILE\.nuget\packages",
    [ValidateRange(8192, 32768)]
    [int]$MemoryInMB = 16384,
    [switch]$Launch
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Resolve-RegularDirectory {
    param([string]$Path, [string]$FailureCode)
    Assert-True (Test-Path -LiteralPath $Path -PathType Container) $FailureCode
    $resolved = [System.IO.Path]::GetFullPath((Get-Item -LiteralPath $Path -Force).FullName)
    $item = Get-Item -LiteralPath $resolved -Force
    Assert-True (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) ($FailureCode + "_reparse")
    return $resolved.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
}

function Assert-OutsideRepository {
    param([string]$CandidatePath, [string]$RepositoryRoot)
    $candidate = [System.IO.Path]::GetFullPath($CandidatePath).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $repository = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $prefix = $repository + [System.IO.Path]::DirectorySeparatorChar
    Assert-True (-not $candidate.Equals($repository, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) "phase3b2_sandbox_evidence_inside_repository"
}

function Set-ProtectedDirectoryAcl {
    param([string]$Path)
    $existingAcl = Get-Acl -LiteralPath $Path
    if ($existingAcl.AreAccessRulesProtected) { return }
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemSid = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-18")
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $currentSid, "FullControl", $inheritance, $propagation, $allow))
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $systemSid, "FullControl", $inheritance, $propagation, $allow))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-FileProjection {
    param([string]$RoleCode, [string]$Path)
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) ("phase3b2_sandbox_input_missing_" + $RoleCode)
    $item = Get-Item -LiteralPath $Path -Force
    Assert-True (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) ("phase3b2_sandbox_input_reparse_" + $RoleCode)
    return [ordered]@{
        roleCode = $RoleCode
        byteLength = $item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function ConvertTo-XmlText {
    param([string]$Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDirectory ".."))
$sandboxExecutable = Join-Path $env:WINDIR "System32\WindowsSandbox.exe"
Assert-True (Test-Path -LiteralPath $sandboxExecutable -PathType Leaf) "phase3b2_windows_sandbox_not_installed"
Assert-True ($null -eq (Get-Process -Name WindowsSandbox, WindowsSandboxClient -ErrorAction SilentlyContinue)) "phase3b2_windows_sandbox_already_running"

$primary = Resolve-RegularDirectory $PrimaryClientRoot "phase3b2_primary_client_root_missing"
$epinel = Resolve-RegularDirectory $EpinelPsRoot "phase3b2_epinelps_root_missing"
$inputs = Resolve-RegularDirectory $ProtectedInputRoot "phase3b2_protected_input_root_missing"
$dotnet = Resolve-RegularDirectory $DotNetRoot "phase3b2_dotnet_root_missing"
$git = Resolve-RegularDirectory $GitRoot "phase3b2_git_root_missing"
$nuget = Resolve-RegularDirectory $NuGetPackagesRoot "phase3b2_nuget_root_missing"

Assert-True (Test-Path -LiteralPath (Join-Path $epinel ".git") -PathType Container) "phase3b2_epinelps_git_metadata_missing"
Assert-True (Test-Path -LiteralPath (Join-Path $dotnet "dotnet.exe") -PathType Leaf) "phase3b2_dotnet_executable_missing"
Assert-True (Test-Path -LiteralPath (Join-Path $git "cmd\git.exe") -PathType Leaf) "phase3b2_git_executable_missing"

$inputFiles = @(
    Get-FileProjection "runtime_pack_staticdata" (Join-Path $inputs "staticdata\553116\StaticData.pack")
    Get-FileProjection "source_observation_archive" (Join-Path $inputs "staticdata\553116\StaticData.zip")
    Get-FileProjection "locale_bgm" (Join-Path $inputs "locale\150.6.9\Locale_Bgm.lsc")
    Get-FileProjection "locale_character" (Join-Path $inputs "locale\150.6.9\Locale_Character.lsc")
    Get-FileProjection "locale_costume" (Join-Path $inputs "locale\150.6.9\Locale_CharacterCostume.lsc")
    Get-FileProjection "locale_item" (Join-Path $inputs "locale\150.6.9\Locale_Item.lsc")
)
Assert-True ($inputFiles[0].byteLength -eq 17177168 -and
    $inputFiles[0].sha256 -ceq "8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3") "phase3b2_staticdata_pack_mismatch"
Assert-True ($inputFiles[1].byteLength -eq 17176616 -and
    $inputFiles[1].sha256 -ceq "925762cd3ef56601916b2e2ae58f929d4dd389055b0d8bcd2176e9abd9b29e69") "phase3b2_source_observation_archive_mismatch"

$evidenceBase = [System.IO.Path]::GetFullPath($EvidenceRoot)
Assert-OutsideRepository $evidenceBase $repositoryRoot
New-Item -ItemType Directory -Path $evidenceBase -Force | Out-Null
Set-ProtectedDirectoryAcl $evidenceBase

$assessmentUid = [Guid]::NewGuid().ToString("D").ToLowerInvariant()
$sessionRoot = Join-Path $evidenceBase ("assessment-" + $assessmentUid)
Assert-True (-not (Test-Path -LiteralPath $sessionRoot)) "phase3b2_sandbox_session_collision"
New-Item -ItemType Directory -Path $sessionRoot | Out-Null
Set-ProtectedDirectoryAcl $sessionRoot

$projection = [ordered]@{
    schemaVersion = 1
    contractId = "nll/phase3b2-host-input-projection/v1"
    assessmentUid = $assessmentUid
    targetClientBuild = "150.6.9"
    inputs = $inputFiles
}
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText(
    (Join-Path $sessionRoot "host-input-projection.json"),
    ($projection | ConvertTo-Json -Depth 8),
    $utf8NoBom)

$mappedFolders = @(
    @{ Host = $repositoryRoot; Sandbox = "C:\HostLabRepo"; ReadOnly = "true" }
    @{ Host = $primary; Sandbox = "C:\HostPrimary"; ReadOnly = "true" }
    @{ Host = $epinel; Sandbox = "C:\HostEpinelPS"; ReadOnly = "true" }
    @{ Host = $inputs; Sandbox = "C:\HostInputs"; ReadOnly = "true" }
    @{ Host = $dotnet; Sandbox = "C:\HostDotnet"; ReadOnly = "true" }
    @{ Host = $git; Sandbox = "C:\HostGit"; ReadOnly = "true" }
    @{ Host = $nuget; Sandbox = "C:\HostNuget"; ReadOnly = "true" }
    @{ Host = $sessionRoot; Sandbox = "C:\HostEvidence"; ReadOnly = "false" }
)
$folderXml = [System.Text.StringBuilder]::new()
foreach ($mapping in $mappedFolders) {
    $null = $folderXml.AppendLine("    <MappedFolder>")
    $null = $folderXml.AppendLine("      <HostFolder>$(ConvertTo-XmlText $mapping.Host)</HostFolder>")
    $null = $folderXml.AppendLine("      <SandboxFolder>$($mapping.Sandbox)</SandboxFolder>")
    $null = $folderXml.AppendLine("      <ReadOnly>$($mapping.ReadOnly)</ReadOnly>")
    $null = $folderXml.AppendLine("    </MappedFolder>")
}

$guestCommand = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\HostLabRepo\scripts\prepare-phase3b2-sandbox-guest.ps1 -EvidenceRoot C:\HostEvidence"
$configuration = @"
<Configuration>
  <vGPU>Enable</vGPU>
  <Networking>Disable</Networking>
  <MemoryInMB>$MemoryInMB</MemoryInMB>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <PrinterRedirection>Disable</PrinterRedirection>
  <ProtectedClient>Disable</ProtectedClient>
  <MappedFolders>
$($folderXml.ToString().TrimEnd())
  </MappedFolders>
  <LogonCommand>
    <Command>$(ConvertTo-XmlText $guestCommand)</Command>
  </LogonCommand>
</Configuration>
"@
$configurationPath = Join-Path $sessionRoot "phase3b2-wave1.wsb"
[System.IO.File]::WriteAllText($configurationPath, $configuration, $utf8NoBom)

$configurationHash = (Get-FileHash -LiteralPath $configurationPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($Launch) {
    Start-Process -FilePath $sandboxExecutable -ArgumentList $configurationPath
}

[ordered]@{
    statusCode = if ($Launch) { "sandbox_launch_requested" } else { "sandbox_configuration_ready" }
    assessmentUid = $assessmentUid
    configurationSha256 = $configurationHash
    networkingEnabled = $false
    clientExecutionStarted = $false
    serverExecutionStarted = $false
} | ConvertTo-Json
