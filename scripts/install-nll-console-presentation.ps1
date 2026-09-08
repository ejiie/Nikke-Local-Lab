[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\NLL\ControlCenter',
    [string]$AssetRoot = (Join-Path $PSScriptRoot '..\artifacts\phase-d\presentation-assets\consoles')
)

# A presentation-only deployment: no build, process restart, DB or runtime edit.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sourceEditor = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\NikkeLocalLab.Admin.Api\wwwroot\editor'))
$targetEditor = [IO.Path]::GetFullPath((Join-Path $InstallRoot 'app\wwwroot\editor'))
$AssetRoot = [IO.Path]::GetFullPath($AssetRoot)
foreach ($name in @('index.html','editor.js','editor.css')) {
    if (-not (Test-Path -LiteralPath (Join-Path $targetEditor $name) -PathType Leaf)) {
        throw 'console_ui_installation_missing'
    }
}
$expected = @('common','attacker','defender','supporter','elysion','missilis','tetra','pilgrim','abnormal')
$receipt = Get-Content -LiteralPath (Join-Path $AssetRoot 'console-assets.receipt.json') -Raw | ConvertFrom-Json
if ($receipt.contractId -cne 'nll/console-presentation-assets/v1' -or @($receipt.members).Count -ne 9) {
    throw 'console_ui_asset_receipt_invalid'
}
$plan = [Collections.Generic.List[object]]::new()
foreach ($name in @('index.html','editor.js','editor.css')) {
    $plan.Add(@{ RelativePath = $name; Source = Join-Path $sourceEditor $name })
}
foreach ($code in $expected) {
    $member = @($receipt.members | Where-Object { $_.coordinateCode -ceq $code })
    $source = Join-Path $AssetRoot ($code + '.webp')
    if ($member.Count -ne 1 -or $member[0].fileName -cne ($code + '.webp') -or
        (Get-Item -LiteralPath $source).Length -ne $member[0].byteLength -or
        (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -cne $member[0].sha256) {
        throw 'console_ui_asset_hash_mismatch'
    }
    $plan.Add(@{ RelativePath = "assets\consoles\$code.webp"; Source = $source })
}
$backupRoot = Join-Path $InstallRoot ('presentation-backups\console-cards-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
foreach ($item in $plan) {
    $item.Target = Join-Path $targetEditor $item.RelativePath
    $item.Backup = Join-Path $backupRoot $item.RelativePath
    $item.Existed = Test-Path -LiteralPath $item.Target -PathType Leaf
    if ($item.Existed) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $item.Backup) -Force | Out-Null
        Copy-Item -LiteralPath $item.Target -Destination $item.Backup
    }
}
$written = [Collections.Generic.List[object]]::new()
try {
    foreach ($item in $plan) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $item.Target) -Force | Out-Null
        $written.Add($item)
        Copy-Item -LiteralPath $item.Source -Destination $item.Target -Force
        if ((Get-FileHash -LiteralPath $item.Source).Hash -cne (Get-FileHash -LiteralPath $item.Target).Hash) {
            throw 'console_ui_deployed_hash_mismatch'
        }
    }
    $result = [ordered]@{
        status = 'installed'
        changedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        editorFiles = 3
        consoleIcons = 9
        backendChanged = $false
        processRestarted = $false
        backupRoot = $backupRoot
        members = @($plan | ForEach-Object { [ordered]@{
            relativePath = $_.RelativePath
            existedBefore = $_.Existed
            sha256 = (Get-FileHash -LiteralPath $_.Target).Hash.ToLowerInvariant()
        } })
    }
    [IO.File]::WriteAllText((Join-Path $backupRoot 'deployment.receipt.json'),
        ($result | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    $result | ConvertTo-Json -Depth 5
}
catch {
    foreach ($item in $written) {
        if ($item.Existed) { Copy-Item -LiteralPath $item.Backup -Destination $item.Target -Force }
        elseif (Test-Path -LiteralPath $item.Target -PathType Leaf) {
            # Exact known file created by this attempt, never a directory/glob.
            Remove-Item -LiteralPath $item.Target -Force
        }
    }
    throw
}
