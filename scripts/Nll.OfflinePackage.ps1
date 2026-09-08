# Source-only packaging helpers. No install, database, or process operations.
Set-StrictMode -Version Latest

function Get-NllPackageTree([string]$Root) {
    $rootItem = Get-Item -LiteralPath $Root -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'offline_package_root_invalid'
    }
    $rows = @()
    # Walk explicitly so a reparse directory is rejected BEFORE following it.
    $queue = [Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($rootItem.FullName)
    while ($queue.Count -gt 0) {
        foreach ($item in Get-ChildItem -LiteralPath $queue.Dequeue() -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'offline_package_reparse_rejected' }
            if ($item.PSIsContainer) { $queue.Enqueue($item.FullName); continue }
            $rows += [ordered]@{
                relativePath = [IO.Path]::GetRelativePath($rootItem.FullName, $item.FullName).Replace('\', '/')
                byteLength = $item.Length
                sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    }
    @($rows | Sort-Object { $_.relativePath })
}

function Assert-NllPackageTree([string]$Root, [object[]]$Expected) {
    $actual = @(Get-NllPackageTree $Root)
    if (($actual | ConvertTo-Json -Depth 5 -Compress) -cne ($Expected | ConvertTo-Json -Depth 5 -Compress)) {
        throw 'offline_package_tree_changed'
    }
}

function Copy-NllPackageTree([string]$Source, [string]$Destination, [object[]]$Expected) {
    if (Test-Path -LiteralPath $Destination) { throw 'offline_package_destination_exists' }
    $null = New-Item -ItemType Directory -Path $Destination
    Assert-NllPackageTree $Source $Expected
    foreach ($row in $Expected) {
        $target = Join-Path $Destination $row.relativePath
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
        Copy-Item -LiteralPath (Join-Path $Source $row.relativePath) -Destination $target
    }
    # Preserve empty directories as well (required for PostgreSQL cold copies).
    foreach ($directory in Get-ChildItem -LiteralPath $Source -Directory -Recurse -Force) {
        $null = New-Item -ItemType Directory -Path (Join-Path $Destination ([IO.Path]::GetRelativePath($Source, $directory.FullName))) -Force
    }
    Assert-NllPackageTree $Source $Expected
    Assert-NllPackageTree $Destination $Expected
}

function Get-NllPackageDelta([object[]]$Candidate, [object[]]$Installed) {
    $byPath = @{}
    foreach ($row in $Installed) { $byPath[$row.relativePath] = $row }
    foreach ($row in $Candidate) {
        $before = $byPath[$row.relativePath]
        if ($null -eq $before) { $action = 'add' }
        elseif ($before.sha256 -cne $row.sha256 -or $before.byteLength -ne $row.byteLength) { $action = 'replace' }
        else { $action = 'unchanged' }
        [ordered]@{ relativePath = $row.relativePath; action = $action; candidate = $row; installed = $before }
    }
    # Installed-only files (including local presentation assets) are not deletions.
}
