# Offline preparation only. No HTTP handler, listener, download or client mutation.
Set-StrictMode -Version Latest

function Assert-NllHeader([bool]$Condition, [string]$Code) {
    if (-not $Condition) { throw ('resource_header_' + $Code) }
}

function Assert-NllHeaderLocalPath([string]$Path) {
    Assert-NllHeader ([IO.Path]::IsPathFullyQualified($Path) -and -not $Path.StartsWith('\\')) 'path_invalid'
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            Assert-NllHeader (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'path_reparse'
        }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Read-NllHeaderBytes([string]$Path, [long]$MaximumBytes = 65536) {
    try {
        Assert-NllHeaderLocalPath $Path
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            Assert-NllHeader ($stream.Length -gt 0 -and $stream.Length -le $MaximumBytes) 'size_invalid'
            $bytes = [byte[]]::new([int]$stream.Length)
            $stream.ReadExactly($bytes, 0, $bytes.Length)
            return ,$bytes
        } finally { $stream.Dispose() }
    } catch {
        if ($_.Exception.Message -cmatch '^resource_header_[a-z_]+$') { throw }
        throw 'resource_header_input_read_failed'
    }
}

function Get-NllHeaderDigest([byte[]]$Bytes) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-NllResourceHeaderUri([object]$Config, [string]$Platform) {
    $base = [string]$Config.ResourceBaseURL
    $selector = [string]$Config.ResourceDataPackVersion
    Assert-NllHeader ($Platform -cmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$') 'platform_invalid'
    Assert-NllHeader ($selector -cmatch '^[0-9]{1,8}$') 'selector_invalid'
    Assert-NllHeader ($base.EndsWith('/{Platform}') -and ([regex]::Matches($base, '\{Platform\}')).Count -eq 1) 'base_invalid'
    $resolved = $base.Replace('{Platform}', $Platform)
    $uri = $null
    Assert-NllHeader ([Uri]::TryCreate($resolved, [UriKind]::Absolute, [ref]$uri)) 'base_invalid'
    # These are the existing normal resource route and the two reviewed local
    # ports, not a version/language-specific destination or a fetch allowlist.
    Assert-NllHeader ($uri.Scheme -ceq 'https' -and $uri.Port -in 443,8443 -and
        -not $uri.UserInfo -and -not $uri.Query -and -not $uri.Fragment -and
        $resolved -ceq $uri.AbsoluteUri -and $uri.AbsolutePath -cmatch '^/prdenv/[A-Za-z0-9_./-]+$' -and
        -not $uri.AbsolutePath.Contains('//') -and
        @($uri.AbsolutePath.Split('/') | Where-Object { $_ -in '.','..' }).Count -eq 0) 'base_invalid'
    [Uri]($resolved + '/pck/latest-' + $selector + '.txt')
}

function Get-NllResourceHeaderPlan {
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$SourceConfigSha256,
        [Parameter(Mandatory)][string]$InputDirectory,
        [Parameter(Mandatory)][string]$ExpectedAcquisitionReceiptSha256,
        [Parameter(Mandatory)][string]$ExpectedMetadataSha256,
        [Parameter(Mandatory)][string]$Platform
    )
    try {
        foreach ($digest in @($SourceConfigSha256,$ExpectedAcquisitionReceiptSha256,$ExpectedMetadataSha256)) {
            Assert-NllHeader ($digest -cmatch '^[a-f0-9]{64}$') 'digest_invalid'
        }
        $uri = Get-NllResourceHeaderUri $Config $Platform
        $receiptBytes = Read-NllHeaderBytes (Join-Path $InputDirectory 'acquisition.receipt.json') 262144
        Assert-NllHeader ((Get-NllHeaderDigest $receiptBytes) -ceq $ExpectedAcquisitionReceiptSha256) 'receipt_drift'
        $receipt = [Text.UTF8Encoding]::new($false,$true).GetString($receiptBytes) | ConvertFrom-Json
        $requestBytes = Read-NllHeaderBytes (Join-Path $InputDirectory 'request.private.json') 262144
        Assert-NllHeader ((Get-NllHeaderDigest $requestBytes) -ceq $receipt.requestSha256) 'request_drift'
        $request = [Text.UTF8Encoding]::new($false,$true).GetString($requestBytes) | ConvertFrom-Json
        foreach ($flag in @($receipt.installationChanged,$receipt.databaseChanged,$request.redirects,$request.proxy,$request.credentials)) {
            Assert-NllHeader ($flag -is [bool] -and $flag -eq $false) 'acquisition_invalid'
        }
        Assert-NllHeader ($receipt.contract -ceq 'nll/cold-version-input-acquisition/v1' -and
            $request.contract -ceq 'nll/cold-version-input-request/v1' -and
            $null -eq $receipt.failure -and $receipt.tls -ceq 'system_hostname_and_certificate_validation' -and
            $receipt.installationChanged -ceq $false -and $receipt.databaseChanged -ceq $false -and
            $request.redirects -ceq $false -and $request.proxy -ceq $false -and $request.credentials -ceq $false) 'acquisition_invalid'
        Assert-NllHeader ($receipt.build -ceq $Config.TargetVersion -and $request.build -ceq $Config.TargetVersion -and
            $receipt.configSha256 -ceq $SourceConfigSha256 -and $request.configSha256 -ceq $SourceConfigSha256) 'config_binding_invalid'
        foreach ($members in @($request.members,$receipt.members)) {
            Assert-NllHeader (@($members).Count -eq 2 -and
                @($members | Where-Object { $_.role -ceq 'version_metadata' }).Count -eq 1 -and
                @($members | Where-Object { $_.role -ceq 'static_pack' }).Count -eq 1) 'members_invalid'
        }
        $member = @($request.members | Where-Object { $_.role -ceq 'version_metadata' })[0]
        $acquired = @($receipt.members | Where-Object { $_.role -ceq 'version_metadata' })[0]
        # Only the local serving port differs from the exact approved CDN URI.
        $origin = [UriBuilder]::new($uri)
        $origin.Port = 443
        Assert-NllHeader ($member.uri -ceq $origin.Uri.AbsoluteUri -and $member.maxBytes -eq 65536 -and
            $member.file -cmatch '^[A-Za-z0-9_-][A-Za-z0-9_.-]*[.]txt$' -and -not $member.file.Contains('..')) 'request_binding_invalid'
        Assert-NllHeader ($acquired.status -ceq 'acquired_hash_sealed' -and $acquired.httpStatus -eq 200 -and
            $acquired.sha256 -ceq $ExpectedMetadataSha256) 'acquisition_member_invalid'
        $source = Join-Path $InputDirectory $member.file
        $bytes = Read-NllHeaderBytes $source
        Assert-NllHeader ($bytes.Length -eq $acquired.byteLength -and
            (Get-NllHeaderDigest $bytes) -ceq $ExpectedMetadataSha256) 'content_drift'
        # Keep this object private. It contains the original request's path.
        [pscustomobject]@{ role='version_metadata'; sourcePath=$source
            relativePath=('cache/' + $uri.AbsolutePath.TrimStart('/'))
            length=$bytes.Length; sha256=$ExpectedMetadataSha256 }
    } catch {
        if ($_.Exception.Message -cmatch '^resource_header_[a-z_]+$') { throw }
        throw 'resource_header_input_invalid'
    }
}

function Get-NllResourceHeaderTarget([string]$RuntimeRoot, [object]$Plan) {
    Assert-NllHeaderLocalPath $RuntimeRoot
    Assert-NllHeader ($Plan.role -ceq 'version_metadata' -and
        $Plan.relativePath -cmatch '^cache/prdenv/[A-Za-z0-9_./-]+/pck/latest-[0-9]{1,8}[.]txt$' -and
        -not $Plan.relativePath.Contains('//') -and
        @($Plan.relativePath.Split('/') | Where-Object { $_ -in '.','..' }).Count -eq 0) 'target_invalid'
    $cacheRoot = [IO.Path]::GetFullPath((Join-Path $RuntimeRoot 'cache')).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $target = [IO.Path]::GetFullPath((Join-Path $RuntimeRoot $Plan.relativePath))
    Assert-NllHeader ($target.StartsWith($cacheRoot,[StringComparison]::OrdinalIgnoreCase)) 'target_invalid'
    Assert-NllHeaderLocalPath $target
    $target
}

function Copy-NllResourceHeader([string]$RuntimeRoot, [object]$Plan) {
    try {
        $target = Get-NllResourceHeaderTarget $RuntimeRoot $Plan
        Assert-NllHeader (Test-Path -LiteralPath $RuntimeRoot -PathType Container) 'runtime_missing'
        Assert-NllHeader (-not (Test-Path -LiteralPath (Join-Path $RuntimeRoot 'resource-probe-runtime.private.json'))) 'runtime_already_sealed'
        Assert-NllHeader (-not (Test-Path -LiteralPath $target)) 'target_exists'
        $bytes = Read-NllHeaderBytes $Plan.sourcePath
        Assert-NllHeader ($bytes.Length -eq $Plan.length -and (Get-NllHeaderDigest $bytes) -ceq $Plan.sha256) 'content_drift'
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        Assert-NllHeaderLocalPath $target
        $output = [IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $output.Write($bytes,0,$bytes.Length); $output.Flush($true) } finally { $output.Dispose() }
        $copied = Read-NllHeaderBytes $target
        Assert-NllHeader ($copied.Length -eq $Plan.length -and (Get-NllHeaderDigest $copied) -ceq $Plan.sha256) 'copy_drift'
    } catch {
        if ($_.Exception.Message -cmatch '^resource_header_[a-z_]+$') { throw }
        throw 'resource_header_stage_failed'
    }
}

function Assert-NllResourceHeaderManifest([string]$RuntimeRoot, [object]$Plan, [object[]]$Files) {
    $target = Get-NllResourceHeaderTarget $RuntimeRoot $Plan
    $pins = @($Files | Where-Object { $_.path.Replace('\','/') -ieq $Plan.relativePath })
    Assert-NllHeader ($pins.Count -eq 1) 'manifest_member_missing_or_duplicate'
    Assert-NllHeader ($pins[0].path -ceq $Plan.relativePath -and $pins[0].length -eq $Plan.length -and
        $pins[0].sha256 -ceq $Plan.sha256) 'manifest_member_drift'
    $bytes = Read-NllHeaderBytes $target
    Assert-NllHeader ($bytes.Length -eq $Plan.length -and (Get-NllHeaderDigest $bytes) -ceq $Plan.sha256) 'content_drift'
}
