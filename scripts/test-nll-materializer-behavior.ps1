[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundlePath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedBundleSha256,
    [switch]$MutationChecks
)

# Local-only gate: builds into a NEW ignored artifact directory. It never starts
# the materializer entry point, a server/client or PostgreSQL, and never deploys.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = Split-Path -Parent $PSScriptRoot
$projectRoot = Join-Path $repository 'tools\NikkeLocalLab.PhaseD.RuntimeMaterializer'
$project = Join-Path $projectRoot 'NikkeLocalLab.PhaseD.RuntimeMaterializer.csproj'
$checksProject = Join-Path $repository 'tests\NikkeLocalLab.Materializer.BehaviorChecks\NikkeLocalLab.Materializer.BehaviorChecks.csproj'
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Require([bool]$Condition, [string]$Code) { if (-not $Condition) { throw $Code } }
function Invoke-CheckedBuild([string[]]$Arguments) {
    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) { throw 's06_build_failed' }
}
Require ((Hash $BundlePath) -ceq $ExpectedBundleSha256) 's06_bundle_pin_mismatch'
$bundle = Get-Content -LiteralPath $BundlePath -Raw | ConvertFrom-Json
Require ($bundle.contractId -ceq 'nll/phase-d-runtime-bundle/v1') 's06_bundle_contract_invalid'
$referenceRoot = [IO.Path]::GetFullPath([string]$bundle.serverRoot)
Require (-not $referenceRoot.StartsWith('C:\NIKKE', [StringComparison]::OrdinalIgnoreCase)) 's06_official_path_rejected'
[xml]$definition = Get-Content -LiteralPath $project -Raw
$referencePins = @()
foreach ($reference in $definition.SelectNodes('//Reference')) {
    $name = [string]$reference.Include + '.dll'
    Require ($name -match '^[A-Za-z0-9_.-]+\.dll$') 's06_reference_name_invalid'
    $path = Join-Path $referenceRoot $name
    $pin = @($bundle.files | Where-Object { [string]$_.path -ieq $path })
    Require ($pin.Count -eq 1) 's06_reference_pin_missing'
    Require ((Hash $path) -ceq [string]$pin[0].sha256 -and
        (Get-Item -LiteralPath $path).Length -eq [long]$pin[0].length) 's06_reference_pin_mismatch'
    $referencePins += @{ path = $path; sha256 = [string]$pin[0].sha256 }
}
$resultRoot = Join-Path $repository ('artifacts\stabilization\s06\' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $resultRoot
$savedEnvironment = @{}
foreach ($name in @('DOTNET_CLI_HOME', 'NUGET_PACKAGES', 'DOTNET_CLI_TELEMETRY_OPTOUT')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$receipt = [ordered]@{
    contractId = 'nll/materializer-behavior-check/v1'; status = 'failed'
    bundleSha256 = $ExpectedBundleSha256; sourceProgramSha256 = Hash (Join-Path $projectRoot 'Program.cs')
    checksSourceSha256 = Hash (Join-Path (Split-Path $checksProject) 'Program.cs')
    referenceCount = $referencePins.Count; behavior = $null; mutations = @()
    separateBuilds = @(); originalClientExecuted = $false; operatingDatabaseTouched = $false
    deployed = $false; failureCode = $null; completedAtUtc = $null
}
function Invoke-Behavior([string]$AssemblyPath) {
    $output = @(& dotnet --roll-forward LatestMajor $script:checksDll $AssemblyPath)
    $exitCode = $LASTEXITCODE
    Require ($output.Count -eq 1) 's06_behavior_output_invalid'
    $result = [string]$output[0] | ConvertFrom-Json
    Require ($result.syntheticOnly -eq $true -and $result.passed + $result.failed -eq 21) 's06_behavior_count_invalid'
    return @{ exitCode = $exitCode; result = $result }
}
try {
    $env:DOTNET_CLI_HOME = Join-Path $repository '.dotnet-cli-home'
    $env:NUGET_PACKAGES = Join-Path $repository '.nuget-packages'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    Push-Location $repository
    try {
        Invoke-CheckedBuild @('restore', $checksProject, '--locked-mode')
        Invoke-CheckedBuild @('build', $checksProject, '-c', 'Release', '--no-restore', '-o', (Join-Path $resultRoot 'checks'))
    } finally { Pop-Location }
    $script:checksDll = Join-Path $resultRoot 'checks\NikkeLocalLab.Materializer.BehaviorChecks.dll'
    $materializerOutput = Join-Path $resultRoot 'materializer'
    Push-Location $projectRoot
    try {
        Invoke-CheckedBuild @('restore', $project, '--locked-mode', "-p:EpinelReferenceRoot=$referenceRoot")
        Invoke-CheckedBuild @('build', $project, '-c', 'Release', '--no-restore', "-p:EpinelReferenceRoot=$referenceRoot", '-o', $materializerOutput)
    } finally { Pop-Location }
    $materializerDll = Join-Path $materializerOutput 'NikkeLocalLab.PhaseD.RuntimeMaterializer.dll'
    $check = Invoke-Behavior $materializerDll
    $receipt.behavior = $check.result
    Require ($check.exitCode -eq 0 -and $check.result.failed -eq 0) 's06_behavior_failed'
    $receipt.separateBuilds += @{ role = 'materializer'; sha256 = Hash $materializerDll }

    if ($MutationChecks) {
        # Negative controls change only generated copies, never production source.
        $source = [IO.File]::ReadAllText((Join-Path $projectRoot 'Program.cs'))
        $mutations = @(
            @{ code = 't10_manufacturer'; before = '(int)itemDefinition!.ItemRare == 10'; after = '(int)itemDefinition!.ItemRare == -1'; expected = 'equipment_t10_true_all_slots' },
            @{ code = 'missing_cube_default'; before = 'existing.Length > 0 ? existing.Max(item => item.Level) : 15'; after = 'existing.Length > 0 ? existing.Max(item => item.Level) : 1'; expected = 'cube_missing_inventory_defaults_to_fifteen' }
        )
        foreach ($mutation in $mutations) {
            Require (($source.Split([string[]]@($mutation.before), [StringSplitOptions]::None)).Count -eq 2) 's06_mutation_anchor_changed'
            $root = Join-Path $resultRoot ('mutation-' + $mutation.code)
            $null = New-Item -ItemType Directory -Path $root
            [IO.File]::WriteAllText((Join-Path $root 'Program.cs'), $source.Replace($mutation.before, $mutation.after), [Text.UTF8Encoding]::new($false))
            [xml]$mutationProject = [IO.File]::ReadAllText($project)
            $property = $mutationProject.CreateElement('EnableDefaultCompileItems')
            $property.InnerText = 'false'
            $null = $mutationProject.Project.PropertyGroup.AppendChild($property)
            foreach ($compile in $mutationProject.SelectNodes('//Compile')) {
                $compile.Include = [IO.Path]::GetFullPath((Join-Path $projectRoot ([string]$compile.Include)))
            }
            $group = $mutationProject.CreateElement('ItemGroup')
            foreach ($file in @(Get-ChildItem -LiteralPath $projectRoot -Filter '*.cs' -File)) {
                $compile = $mutationProject.CreateElement('Compile')
                $compile.SetAttribute('Include', $(if ($file.Name -eq 'Program.cs') { Join-Path $root 'Program.cs' } else { $file.FullName }))
                $null = $group.AppendChild($compile)
            }
            $null = $mutationProject.Project.AppendChild($group)
            $mutationPath = Join-Path $root 'NikkeLocalLab.PhaseD.RuntimeMaterializer.csproj'
            $mutationProject.Save($mutationPath)
            Copy-Item -LiteralPath (Join-Path $projectRoot 'packages.lock.json') -Destination $root
            Push-Location $projectRoot
            try {
                Invoke-CheckedBuild @('restore', $mutationPath, '--locked-mode', "-p:EpinelReferenceRoot=$referenceRoot")
                Invoke-CheckedBuild @('build', $mutationPath, '-c', 'Release', '--no-restore', "-p:EpinelReferenceRoot=$referenceRoot", '-o', (Join-Path $root 'output'))
            } finally { Pop-Location }
            $check = Invoke-Behavior (Join-Path $root 'output\NikkeLocalLab.PhaseD.RuntimeMaterializer.dll')
            Require ($check.exitCode -ne 0 -and $check.result.failures -contains $mutation.expected) 's06_mutation_not_detected'
            $receipt.mutations += @{ code = $mutation.code; detected = $true; failedCases = $check.result.failures }
        }
    }

    foreach ($build in @(
        @{ role = 'bootstrap151'; root = 'tools\Phase3B2\PhysicalBootstrap151'; project = 'NikkeLocalLab.Phase3B2.PhysicalBootstrap151.csproj' },
        @{ role = 'desktop'; root = 'tools\NikkeLocalLab.ControlCenter.Desktop'; project = 'NikkeLocalLab.ControlCenter.Desktop.csproj' }
    )) {
        $buildProject = Join-Path (Join-Path $repository $build.root) $build.project
        # PhysicalBootstrap151 has no own global.json. Select the EXISTING pinned
        # SDK 10 via the materializer directory; never change the repository SDK 8.
        $buildWorkingRoot = if ($build.role -eq 'bootstrap151') { $projectRoot } else { $repository }
        Push-Location $buildWorkingRoot
        try {
            Invoke-CheckedBuild @('restore', $buildProject, '--locked-mode')
            Invoke-CheckedBuild @('build', $buildProject, '-c', 'Release', '--no-restore', '-o', (Join-Path $resultRoot $build.role))
        } finally { Pop-Location }
        $receipt.separateBuilds += @{ role = $build.role; status = 'built_not_executed' }
    }
    foreach ($pin in $referencePins) { Require ((Hash $pin.path) -ceq $pin.sha256) 's06_reference_changed' }
    Require ((Hash $BundlePath) -ceq $ExpectedBundleSha256) 's06_bundle_changed'
    Require ((Hash (Join-Path $projectRoot 'Program.cs')) -ceq $receipt.sourceProgramSha256) 's06_production_source_changed'
    $receipt.status = 'passed'
} catch {
    $receipt.failureCode = if ($_.Exception.Message -cmatch '^s06_[a-z_]+$') { $_.Exception.Message } else { 's06_uncontrolled_failure' }
    throw $receipt.failureCode
} finally {
    $receipt.completedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    [IO.File]::WriteAllText((Join-Path $resultRoot 'receipt.json'), (($receipt | ConvertTo-Json -Depth 10) + "`n"), [Text.UTF8Encoding]::new($false))
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
    Write-Output "S06 local receipt: $resultRoot\receipt.json"
}
