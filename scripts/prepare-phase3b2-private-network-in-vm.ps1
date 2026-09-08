[CmdletBinding()]
param(
    [string]$EvidenceRoot = "$env:LOCALAPPDATA\NikkeLocalLab\Evidence\Phase3B2\Trusted\network-private-v1"
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

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) "administrator_required"
Assert-True ($null -eq (Get-Process -Name EpinelPS, nikke, nikke_launcher -ErrorAction SilentlyContinue)) `
    "phase3b2_private_network_runtime_process_started"
Assert-True (-not (Test-Path -LiteralPath "C:\NLL\Inputs\credential-bearing\source.json")) `
    "phase3b2_private_network_credential_source_present"
Assert-True (-not (Test-Path -LiteralPath $EvidenceRoot)) `
    "phase3b2_private_network_evidence_exists"

$physicalAdapters = @(Get-NetAdapter -Physical -ErrorAction Stop)
$upAdapters = @($physicalAdapters | Where-Object Status -EQ "Up")
Assert-True ($physicalAdapters.Count -eq 1 -and $upAdapters.Count -eq 1) `
    "phase3b2_private_network_adapter_shape_invalid"
$adapter = $upAdapters[0]
$interfaceIndex = [int]$adapter.ifIndex
Assert-True ([Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()) `
    "phase3b2_private_network_link_not_available"

New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
$beforePath = Join-Path $EvidenceRoot "network-before.raw.json"
$rollbackPlanPath = Join-Path $EvidenceRoot "rollback-plan.json"
$receiptPath = Join-Path $EvidenceRoot "network-preparation.receipt.json"

$before = [ordered]@{
    contractId = "nll/phase3b2-private-network-before/v1"
    observedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    adapter = $adapter | Select-Object Name, InterfaceDescription, InterfaceGuid, MacAddress,
        ifIndex, Status, LinkSpeed
    ipInterfaces = @(Get-NetIPInterface -InterfaceIndex $interfaceIndex -ErrorAction Stop |
        Select-Object AddressFamily, Dhcp, ConnectionState, InterfaceMetric,
            WeakHostSend, WeakHostReceive)
    ipAddresses = @(Get-NetIPAddress -InterfaceIndex $interfaceIndex -ErrorAction SilentlyContinue |
        Select-Object AddressFamily, IPAddress, PrefixLength, PrefixOrigin,
            SuffixOrigin, AddressState, Type)
    routes = @(Get-NetRoute -InterfaceIndex $interfaceIndex -ErrorAction SilentlyContinue |
        Select-Object AddressFamily, DestinationPrefix, NextHop, RouteMetric,
            Protocol, State, Store)
    dns = @(Get-DnsClientServerAddress -InterfaceIndex $interfaceIndex -ErrorAction Stop |
        Select-Object AddressFamily, ServerAddresses)
}
Write-Utf8NoBom $beforePath (($before | ConvertTo-Json -Depth 10) + "`n")

$rollbackPlan = [ordered]@{
    contractId = "nll/phase3b2-private-network-rollback-plan/v1"
    mechanismCode = "restore_exact_p0_v3_checkpoint_then_disconnect_private_switch"
    hostResetReceiptByteLength = 814
    hostResetReceiptSha256 = "780e09d4dbe75180862f9347163a9e4058441cd5b3d025aaf38dee7b345f6748"
    backupByteLength = (Get-Item -LiteralPath $beforePath).Length
    backupSha256 = Get-Sha256Hex $beforePath
    prepared = $true
}
Write-Utf8NoBom $rollbackPlanPath (($rollbackPlan | ConvertTo-Json) + "`n")

Set-NetIPInterface -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -Dhcp Disabled
foreach ($address in @(Get-NetIPAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue)) {
    Remove-NetIPAddress -InputObject $address -Confirm:$false
}
foreach ($route in @(Get-NetRoute -InterfaceIndex $interfaceIndex -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue | Where-Object DestinationPrefix -EQ "0.0.0.0/0")) {
    Remove-NetRoute -InputObject $route -Confirm:$false
}
New-NetIPAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 `
    -IPAddress "192.0.2.2" -PrefixLength 24 -Type Unicast | Out-Null
Set-DnsClientServerAddress -InterfaceIndex $interfaceIndex -ResetServerAddresses

for ($attempt = 0; $attempt -lt 60; $attempt++) {
    $networkAvailable = [Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
    $profiles = @(Get-NetConnectionProfile -InterfaceIndex $interfaceIndex -ErrorAction SilentlyContinue)
    $ipv4DefaultRoutes = @(Get-NetRoute -InterfaceIndex $interfaceIndex -AddressFamily IPv4 `
        -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Where-Object State -EQ "Alive")
    if ($networkAvailable -and $profiles.Count -eq 1 -and $ipv4DefaultRoutes.Count -eq 0) { break }
    Start-Sleep -Seconds 1
}

$ipv6DefaultRoutes = @(Get-NetRoute -InterfaceIndex $interfaceIndex -AddressFamily IPv6 `
    -DestinationPrefix "::/0" -ErrorAction SilentlyContinue | Where-Object State -EQ "Alive")
$ipv4Addresses = @(Get-NetIPAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 `
    -ErrorAction Stop | Where-Object Type -EQ "Unicast")
$ipv4Dns = @(Get-DnsClientServerAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 `
    -ErrorAction Stop | ForEach-Object { $_.ServerAddresses } | Where-Object { $_ })
Assert-True ($networkAvailable -and $profiles.Count -eq 1 -and
    $ipv4DefaultRoutes.Count -eq 0 -and $ipv6DefaultRoutes.Count -eq 0 -and
    $ipv4Addresses.Count -eq 1 -and $ipv4Addresses[0].IPAddress -ceq "192.0.2.2" -and
    $ipv4Addresses[0].PrefixLength -eq 24 -and $ipv4Dns.Count -eq 0) `
    "phase3b2_private_network_normalization_failed"

$targetDomains = @(
    "global-lobby.nikke-kr.com", "cloud.nikke-kr.com", "jp-lobby.nikke-kr.com",
    "us-lobby.nikke-kr.com", "kr-lobby.nikke-kr.com", "sea-lobby.nikke-kr.com",
    "hmt-lobby.nikke-kr.com", "aws-na-dr.intlgame.com", "sg-vas.intlgame.com",
    "aws-na.intlgame.com", "na-community.playerinfinite.com", "common-web.intlgame.com",
    "li-sg.intlgame.com", "na.fleetlogd.com", "www.jupiterlauncher.com",
    "data-aws-na.intlgame.com", "sentry.io"
)
foreach ($domain in $targetDomains) {
    $answers = @(Resolve-DnsName -Name $domain -Type A -ErrorAction Stop |
        Where-Object { $_.Type -eq "A" })
    Assert-True ($answers.Count -ge 1 -and
        @($answers | Where-Object IPAddress -CNE "127.0.0.1").Count -eq 0) `
        "phase3b2_private_network_hosts_resolution_mismatch"
}

$receipt = [ordered]@{
    contractId = "nll/phase3b2-private-network-preparation/v1"
    preparedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    networkModeCode = "private_vm_only_no_gateway"
    hostPrivateSwitchReceiptByteLength = 814
    hostPrivateSwitchReceiptSha256 = "780e09d4dbe75180862f9347163a9e4058441cd5b3d025aaf38dee7b345f6748"
    beforeStateByteLength = (Get-Item -LiteralPath $beforePath).Length
    beforeStateSha256 = Get-Sha256Hex $beforePath
    rollbackPlanByteLength = (Get-Item -LiteralPath $rollbackPlanPath).Length
    rollbackPlanSha256 = Get-Sha256Hex $rollbackPlanPath
    systemNetworkAvailable = $true
    upPhysicalNetworkAdapterCount = 1
    networkProfileCount = 1
    ipv4DefaultRouteCount = 0
    ipv6DefaultRouteCount = 0
    ipv4DnsServerCount = 0
    staticAddressRoleCode = "rfc5737_testnet1_nonroutable_guest"
    mappedLoopbackDomainCount = 17
    externalUplinkPresent = $false
    hostVirtualAdapterPresent = $false
    natConfigured = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
Write-Utf8NoBom $receiptPath (($receipt | ConvertTo-Json) + "`n")
$receipt | ConvertTo-Json

