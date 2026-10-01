# Full app/UI package with byte-exact backups and recoverable added-file rollback.
# This library never starts a process, accesses a DB, or grants native admission.
Set-StrictMode -Version Latest

function Assert-NllAppPackage([bool]$Value, [string]$Code) {
    if (-not $Value) { throw ('app_package_' + $Code) }
}
function Get-NllAppPlainPath([string]$Path) {
    Assert-NllAppPackage ([IO.Path]::IsPathFullyQualified($Path) -and -not $Path.StartsWith('\\')) 'path_invalid'
    $full = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
    Assert-NllAppPackage ($full.Length -gt [IO.Path]::GetPathRoot($full).Length -and
        -not $full.Substring([IO.Path]::GetPathRoot($full).Length).Contains(':')) 'path_invalid'
    for ($cursor = $full; $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
        try { $attributes = [IO.File]::GetAttributes($cursor) }
        catch [IO.FileNotFoundException] { continue }
        catch [IO.DirectoryNotFoundException] { continue }
        Assert-NllAppPackage (($attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'reparse_forbidden'
    }
    $full
}
function Get-NllAppMemberPath([string]$Root, [string]$Relative) {
    Assert-NllAppPackage ($Relative -cmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,511}$' -and
        @($Relative.Split('/') | Where-Object { $_ -in @('', '.', '..') -or $_.EndsWith('.') }).Count -eq 0) 'relative_path_invalid'
    Get-NllAppPlainPath (Join-Path $Root $Relative)
}
function Get-NllAppPin([string]$Path) {
    $path = Get-NllAppPlainPath $Path
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    Assert-NllAppPackage (Test-Path -LiteralPath $path -PathType Leaf) 'member_not_file'
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $digest = [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
        finally { $hash.Dispose() }
        [ordered]@{ sha256 = $digest; byteLength = $stream.Length }
    } finally { $stream.Dispose() }
}
function Test-NllAppPin($First, $Second) {
    if ($null -eq $First -or $null -eq $Second) { return $null -eq $First -and $null -eq $Second }
    $First.sha256 -ceq $Second.sha256 -and $First.byteLength -eq $Second.byteLength
}
function Get-NllAppInventory([string]$Root) {
    $root = Get-NllAppPlainPath $Root
    Assert-NllAppPackage (Test-Path -LiteralPath $root -PathType Container) 'tree_missing'
    # Validate every directory before descending; never traverse a junction.
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($root)
    $rows = [Collections.Generic.List[object]]::new()
    $directories = 0
    while ($pending.Count -gt 0) {
        $directory = $pending.Dequeue()
        Assert-NllAppPackage ((++$directories) -le 10000) 'tree_too_large'
        foreach ($member in [IO.DirectoryInfo]::new($directory).EnumerateFileSystemInfos()) {
            $path = Get-NllAppPlainPath $member.FullName
            if (($member.Attributes -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Enqueue($path); continue }
            $relative = [IO.Path]::GetRelativePath($root, $path).Replace('\', '/')
            $null = Get-NllAppMemberPath $root $relative
            Assert-NllAppPackage ($rows.Count -lt 10000) 'tree_too_large'
            $rows.Add([ordered]@{ relativePath = $relative; pin = Get-NllAppPin $path })
        }
    }
    Assert-NllAppPackage (($rows | Measure-Object -Property { $_.pin.byteLength } -Sum).Sum -le 2147483648L) 'tree_too_large'
    @($rows | Sort-Object relativePath)
}
function Test-NllAppInventory($Expected, $Actual) {
    if (@($Expected).Count -ne @($Actual).Count) { return $false }
    $actualMap = @{}
    foreach ($row in $Actual) { $actualMap[$row.relativePath] = $row.pin }
    foreach ($row in $Expected) {
        if (-not $actualMap.ContainsKey($row.relativePath) -or -not (Test-NllAppPin $row.pin $actualMap[$row.relativePath])) { return $false }
    }
    $true
}
function Copy-NllAppNewFile([string]$Source, [string]$Destination, $Pin) {
    Assert-NllAppPackage (Test-NllAppPin (Get-NllAppPin $Source) $Pin) 'source_drifted'
    $destination = Get-NllAppPlainPath $Destination
    Assert-NllAppPackage (-not (Test-Path -LiteralPath $destination)) 'output_exists'
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
    $inputStream = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $outputStream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $inputStream.CopyTo($outputStream); $outputStream.Flush($true) } finally { $outputStream.Dispose() }
    } finally { $inputStream.Dispose() }
    Assert-NllAppPackage ((Test-NllAppPin (Get-NllAppPin $destination) $Pin) -and
        (Test-NllAppPin (Get-NllAppPin $Source) $Pin)) 'copy_drifted'
}
function Write-NllAppNewJson([string]$Path, $Value) {
    $stream = [IO.File]::Open((Get-NllAppPlainPath $Path), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 12) + "`n")
        $stream.Write($bytes); $stream.Flush($true)
    } finally { $stream.Dispose() }
}
function New-NllControlCenterAppPackage([string]$AppRoot, [string]$PublishedRoot, [string]$OutputRoot) {
    $appRoot = Get-NllAppPlainPath $AppRoot
    $publishedRoot = Get-NllAppPlainPath $PublishedRoot
    $outputRoot = Get-NllAppPlainPath $OutputRoot
    Assert-NllAppPackage (-not (Test-Path -LiteralPath $outputRoot)) 'output_exists'
    foreach ($inputRoot in @($appRoot, $publishedRoot)) {
        $separator = [IO.Path]::DirectorySeparatorChar
        Assert-NllAppPackage ($inputRoot -ine $outputRoot -and
            -not $outputRoot.StartsWith($inputRoot + $separator, [StringComparison]::OrdinalIgnoreCase) -and
            -not $inputRoot.StartsWith($outputRoot + $separator, [StringComparison]::OrdinalIgnoreCase)) 'output_overlaps_input'
    }
    $before = @(Get-NllAppInventory $appRoot)
    $published = @(Get-NllAppInventory $publishedRoot)
    Assert-NllAppPackage ($before.Count -gt 0 -and $published.Count -gt 0) 'tree_empty'
    foreach ($required in @('NikkeLocalLab.Admin.Api.dll', 'NikkeLocalLab.Admin.Api.deps.json',
        'NikkeLocalLab.Admin.Api.runtimeconfig.json', 'wwwroot/editor/index.html', 'wwwroot/editor/editor.js',
        'wwwroot/editor/editor.css', 'wwwroot/editor/boss-seasons.js', 'wwwroot/editor/user-validation.js')) {
        Assert-NllAppPackage (@($published | Where-Object relativePath -CEQ $required).Count -eq 1) 'full_ui_bundle_required'
    }
    # Installed presentation.json and all locally owned assets must survive.
    # Only compiled app outputs and the complete checked-in editor bundle overlay: every top-level page,
    # script and stylesheet, so a newly added editor script cannot stay behind as an older copy.
    $overlay = @($published | Where-Object {
        $_.relativePath -cmatch '^[A-Za-z0-9._-]+\.(dll|pdb|exe|deps\.json|runtimeconfig\.json)$' -or
        $_.relativePath -cmatch '^wwwroot/editor/[A-Za-z0-9_-]+\.(html|js|css)$'
    })
    $null = [IO.Directory]::CreateDirectory($outputRoot)
    $beforeRoot = Join-Path $outputRoot 'before'
    $afterRoot = Join-Path $outputRoot 'after'
    foreach ($row in $before) { Copy-NllAppNewFile (Get-NllAppMemberPath $appRoot $row.relativePath) (Get-NllAppMemberPath $beforeRoot $row.relativePath) $row.pin }
    $afterMap = @{}
    foreach ($row in $before) { $afterMap[$row.relativePath] = @{ source = $beforeRoot; row = $row } }
    foreach ($row in $overlay) { $afterMap[$row.relativePath] = @{ source = $publishedRoot; row = $row } }
    foreach ($entry in $afterMap.Values) {
        Copy-NllAppNewFile (Get-NllAppMemberPath $entry.source $entry.row.relativePath) (Get-NllAppMemberPath $afterRoot $entry.row.relativePath) $entry.row.pin
    }
    $after = @(Get-NllAppInventory $afterRoot)
    Assert-NllAppPackage ((Test-NllAppInventory $before @(Get-NllAppInventory $appRoot)) -and
        (Test-NllAppInventory $before @(Get-NllAppInventory $beforeRoot)) -and
        (Test-NllAppInventory $published @(Get-NllAppInventory $publishedRoot))) 'input_drifted'
    $manifest = [ordered]@{ schemaVersion = 1; contractId = 'nll/control-center-app-package/v1';
        targetRoot = $appRoot; before = $before; after = $after; installedFilesModified = $false;
        operationalDatabaseTouched = $false; nativeClientExecuted = $false }
    $manifestPath = Join-Path $outputRoot 'manifest.private.json'
    Write-NllAppNewJson $manifestPath $manifest
    [ordered]@{ packageRoot = $outputRoot; manifestSha256 = (Get-NllAppPin $manifestPath).sha256;
        beforeCount = $before.Count; afterCount = $after.Count; installedFilesModified = $false }
}
function Read-NllControlCenterAppPackage([string]$PackageRoot, [string]$ManifestSha256) {
    $path = Get-NllAppMemberPath $PackageRoot 'manifest.private.json'
    Assert-NllAppPackage ($ManifestSha256 -cmatch '^[a-f0-9]{64}$' -and (Get-NllAppPin $path).sha256 -ceq $ManifestSha256 -and
        (Get-Item -LiteralPath $path).Length -le 4194304) 'manifest_drifted'
    $manifest = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-NllAppPackage ($manifest.schemaVersion -eq 1 -and $manifest.contractId -ceq 'nll/control-center-app-package/v1' -and
        $manifest.installedFilesModified -eq $false -and $manifest.operationalDatabaseTouched -eq $false -and
        $manifest.nativeClientExecuted -eq $false) 'manifest_invalid'
    foreach ($side in @('before','after')) {
        $seen = @{}
        foreach ($row in $manifest.$side) {
            $null = Get-NllAppMemberPath $PackageRoot $row.relativePath
            Assert-NllAppPackage (-not $seen.ContainsKey($row.relativePath) -and $row.pin.sha256 -cmatch '^[a-f0-9]{64}$' -and
                $row.pin.byteLength -ge 0) 'manifest_invalid'
            $seen[$row.relativePath] = $true
        }
        Assert-NllAppPackage (Test-NllAppInventory $manifest.$side @(Get-NllAppInventory (Join-Path $PackageRoot $side))) 'package_drifted'
    }
    $manifest
}
function Invoke-NllControlCenterAppPackage([string]$PackageRoot, [string]$ManifestSha256, [string]$TargetRoot,
    [ValidateSet('apply','restore')][string]$Operation) {
    $packageRoot = Get-NllAppPlainPath $PackageRoot
    $targetRoot = Get-NllAppPlainPath $TargetRoot
    $manifest = Read-NllControlCenterAppPackage $packageRoot $ManifestSha256
    Assert-NllAppPackage ($targetRoot -ceq $manifest.targetRoot -and
        [IO.Path]::GetPathRoot($packageRoot) -ieq [IO.Path]::GetPathRoot($targetRoot)) 'target_invalid'
    # The caller owns the cold-runtime and shared startup/deployment lease. This
    # local lease additionally rejects duplicate operations on the same package.
    try {
        $lease = [IO.File]::Open((Join-Path $packageRoot '.operation.lock'), [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] { throw 'app_package_busy' }
    try {
        $maps = @{ before = @{}; after = @{} }
        foreach ($side in @('before','after')) { foreach ($row in $manifest.$side) { $maps[$side][$row.relativePath] = $row.pin } }
        foreach ($key in $maps.before.Keys) { Assert-NllAppPackage ($maps.after.ContainsKey($key)) 'deletion_forbidden' }
        $current = @(Get-NllAppInventory $targetRoot)
        foreach ($row in $current) { Assert-NllAppPackage ($maps.after.ContainsKey($row.relativePath)) 'unexpected_target_file' }
        foreach ($key in $maps.after.Keys) {
            $pin = Get-NllAppPin (Get-NllAppMemberPath $targetRoot $key)
            Assert-NllAppPackage ((Test-NllAppPin $pin $maps.before[$key]) -or (Test-NllAppPin $pin $maps.after[$key])) 'target_drifted'
        }
        $side = if ($Operation -ceq 'apply') { 'after' } else { 'before' }
        $transferRoot = Join-Path $packageRoot ('transfer-' + $Operation)
        $null = [IO.Directory]::CreateDirectory($transferRoot)
        foreach ($key in @($maps.after.Keys | Sort-Object)) {
            $target = Get-NllAppMemberPath $targetRoot $key
            $desired = $maps[$side][$key]
            $currentPin = Get-NllAppPin $target
            if (Test-NllAppPin $currentPin $desired) { continue }
            Assert-NllAppPackage ((Test-NllAppPin $currentPin $maps.before[$key]) -or (Test-NllAppPin $currentPin $maps.after[$key])) 'target_drifted'
            if ($null -eq $desired) {
                # Added files are retired, not deleted; both the new file and all
                # prior files remain recoverable in the sealed package.
                $retired = Get-NllAppMemberPath (Join-Path $packageRoot 'retired-added') $key
                $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($retired))
                if (Test-Path -LiteralPath $retired) {
                    Assert-NllAppPackage (Test-NllAppPin (Get-NllAppPin $retired) $currentPin) 'retired_file_drifted'
                    $retired += '.' + [guid]::NewGuid().ToString('N')
                }
                [IO.File]::Move($target, $retired)
            } else {
                $temporary = Get-NllAppMemberPath $transferRoot $key
                if (Test-Path -LiteralPath $temporary) {
                    Assert-NllAppPackage (Test-NllAppPin (Get-NllAppPin $temporary) $desired) 'partial_drifted'
                } else { Copy-NllAppNewFile (Get-NllAppMemberPath (Join-Path $packageRoot $side) $key) $temporary $desired }
                Assert-NllAppPackage (Test-NllAppPin (Get-NllAppPin $target) $currentPin) 'target_drifted'
                $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                [IO.File]::Move($temporary, $target, $true)
            }
        }
        $null = Read-NllControlCenterAppPackage $packageRoot $ManifestSha256
        Assert-NllAppPackage (Test-NllAppInventory $manifest.$side @(Get-NllAppInventory $targetRoot)) 'final_tree_mismatch'
        $result = [ordered]@{ contractId = 'nll/control-center-app-package-operation/v1'; manifestSha256 = $ManifestSha256;
            operation = $Operation; statusCode = 'verified'; nativeClientExecuted = $false; operationalDatabaseTouched = $false }
        Write-NllAppNewJson (Join-Path $packageRoot ($Operation + '-' + [guid]::NewGuid().ToString('N') + '.receipt.json')) $result
        $result
    } finally { $lease.Dispose() }
}
