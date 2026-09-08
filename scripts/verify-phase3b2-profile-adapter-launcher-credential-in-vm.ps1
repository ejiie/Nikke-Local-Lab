[CmdletBinding()]
param(
    [string]$AdapterRoot = "C:\NLL\Tools\ProfileAdapter",
    [string]$EpinelRoot = "C:\NLL\EpinelPS"
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

Assert-True ($null -eq (Get-Process -Name EpinelPS, nikke_launcher, nikke `
        -ErrorAction SilentlyContinue)) "phase3b2_adapter_v2_runtime_not_cold"
Assert-True (@(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" `
        -ErrorAction SilentlyContinue | Where-Object State -EQ "Alive").Count -eq 0 -and
    @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" `
        -ErrorAction SilentlyContinue | Where-Object State -EQ "Alive").Count -eq 0) `
    "phase3b2_adapter_v2_default_route_present"

$dotnet = "$env:ProgramFiles\dotnet\dotnet.exe"
$projectPath = Join-Path $AdapterRoot "NikkeLocalLab.Phase3B2.ProfileAdapter.csproj"
$programPath = Join-Path $AdapterRoot "Program.cs"
$epinelProjectPath = Join-Path $EpinelRoot "EpinelPS\EpinelPS.csproj"
Assert-True (Test-Path -LiteralPath $dotnet -PathType Leaf) `
    "phase3b2_adapter_v2_dotnet_missing"
Assert-True ((& $dotnet --version).Trim() -ceq "10.0.400") `
    "phase3b2_adapter_v2_toolchain_mismatch"
Assert-True (Test-Path -LiteralPath $projectPath -PathType Leaf) `
    "phase3b2_adapter_v2_project_missing"
Assert-True (Test-Path -LiteralPath $programPath -PathType Leaf) `
    "phase3b2_adapter_v2_program_missing"
Assert-True (Test-Path -LiteralPath $epinelProjectPath -PathType Leaf) `
    "phase3b2_adapter_v2_epinel_project_missing"

$source = Get-Content -LiteralPath $programPath -Raw -Encoding UTF8
Assert-True ($source.Contains("NewLauncherPassword()") -and
    $source.Contains("LauncherPasswordHash(launcherPassword)") -and
    $source.Contains("Password = launcherPasswordHash") -and
    $source.Contains("password = launcherPassword") -and
    $source.Contains("md5_lower_hex_legacy_launcher_compatibility") -and
    $source.Contains("Convert.ToHexString(RandomNumberGenerator.GetBytes(10))") -and
    $source.Contains("MD5.HashData(Encoding.ASCII.GetBytes(password))") -and
    -not $source.Contains("Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))")) `
    "phase3b2_adapter_v2_credential_source_shape_invalid"

& $dotnet build $projectPath -c Release --no-restore --nologo `
    "-p:EpinelProjectPath=$epinelProjectPath"
Assert-True ($LASTEXITCODE -eq 0) "phase3b2_adapter_v2_build_failed"
Assert-True ((git -C $EpinelRoot rev-parse HEAD).Trim() -ceq
        "519c3db51ec24ca19307e93e85acde7885928a72" -and
    (git -C $EpinelRoot rev-parse 'HEAD^{tree}').Trim() -ceq
        "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a" -and
    @(git -C $EpinelRoot status --porcelain=v1 --untracked-files=all).Count -eq 0) `
    "phase3b2_adapter_v2_external_checkout_drift"

$outputPath = Join-Path $AdapterRoot `
    "bin\Release\net10.0\win-x64\NikkeLocalLab.Phase3B2.ProfileAdapter.exe"
Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) `
    "phase3b2_adapter_v2_build_output_missing"
$receiptRoot = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted\identity\launcher-credential-v1"
$receiptPath = Join-Path $receiptRoot "profile-adapter-build.receipt.json"
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) `
    "phase3b2_adapter_v2_build_receipt_exists"
$receipt = [ordered]@{
    contractId = "nll/phase3b2-profile-adapter-launcher-credential-build/v1"
    verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    dotnetSdkVersion = "10.0.400"
    sourceByteLength = (Get-Item -LiteralPath $programPath).Length
    sourceSha256 = Get-Sha256Hex $programPath
    outputByteLength = (Get-Item -LiteralPath $outputPath).Length
    outputSha256 = Get-Sha256Hex $outputPath
    launcherPasswordPlaintextLength = 20
    launcherPasswordStorageLength = 32
    launcherPasswordStorageSchemeCode =
        "md5_lower_hex_legacy_launcher_compatibility"
    launcherPasswordPlaintextPersistedInDatabase = $false
    externalCheckoutClean = $true
    adapterExecutionStarted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json
