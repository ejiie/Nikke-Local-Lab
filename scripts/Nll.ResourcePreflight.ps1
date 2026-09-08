Set-StrictMode -Version Latest

function Get-NllResourcePreflightToolSetSha256 {
    param([Parameter(Mandatory)] [string]$ToolPath)
    $root = Split-Path -Parent $ToolPath
    $members = @(Get-ChildItem -LiteralPath $root -File | Sort-Object Name)
    if ($members.Count -lt 6) { throw 'phase_d_resource_preflight_tool_set_incomplete' }
    $lines = foreach ($member in $members) {
        $member.Name + "`t" + [string]$member.Length + "`t" +
            (Get-FileHash -LiteralPath $member.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($hasher.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes(($lines -join "`n") + "`n")))).Replace('-','').ToLowerInvariant()
    }
    finally { $hasher.Dispose() }
}

function Get-NllVoiceResourceSelection {
    # Only the two proven PlayerPrefs fields. Never enumerate or serialize the
    # rest of the key, which may contain unrelated private settings.
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        'Software\com.proximabeta\NIKKE', $false)
    if ($null -eq $key) { throw 'phase_d_resource_voice_selection_unresolved' }
    try {
        $values = @()
        foreach ($name in @('voiceLocale_h4098423835','voiceDownloadType_h2535520031')) {
            $value = $key.GetValue($name, $null)
            if ($value -is [byte[]]) {
                $value = [Text.Encoding]::UTF8.GetString($value).Trim([char]0)
            }
            $values += [string]$value
        }
        if ($values[0] -cnotin @('en','ko','ja') -or
            $values[1] -cnotin @('Minimal','Full')) {
            # A new enum spelling must be measured, not silently treated as
            # Full/Minimal or absence of audio.
            throw 'phase_d_resource_voice_selection_unresolved'
        }
        [pscustomobject]@{ language = $values[0]; scope = $values[1].ToLowerInvariant() }
    }
    finally { $key.Dispose() }
}

function Invoke-NllResourceCatalogPreflight {
    param(
        [Parameter(Mandatory)] [string]$ToolPath,
        [Parameter(Mandatory)] [string]$ServerRoot,
        [Parameter(Mandatory)] [string]$ClientExecutable,
        [Parameter(Mandatory)] [object]$Selection
    )
    if (-not (Test-Path -LiteralPath $ToolPath -PathType Leaf)) {
        throw 'phase_d_resource_preflight_tool_missing'
    }
    $output = @(& $ToolPath legacy-preflight $ServerRoot $ClientExecutable `
        ([string]$Selection.language) ([string]$Selection.scope))
    $exitCode = $LASTEXITCODE
    $result = ($output -join "`n") | ConvertFrom-Json
    if ($exitCode -ne 0 -or $result.statusCode -cne 'catalogs_verified') {
        $code = [string]$result.failureCode
        if ($code -cnotmatch '^resource_[a-z0-9_]{3,96}$') { $code = 'resource_preflight_failed' }
        $role = [string]$result.roleCode
        if ($role -cin @('en','ko','ja','core','dp','fd','saus')) { $code += '_' + $role }
        throw ('phase_d_' + $code)
    }
    $result
}

function Assert-NllResourceTransportBeforeClient {
    param(
        [Parameter(Mandatory)] [string]$ToolPath,
        [Parameter(Mandatory)] [string]$ReceiptPath,
        [Parameter(Mandatory)] [string]$ReceiptSha256,
        [Parameter(Mandatory)] [string]$ToolSha256,
        [Parameter(Mandatory)] [string]$TransportReceiptPath
    )
    if ((Get-FileHash -LiteralPath $ReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ReceiptSha256 -or
        (Get-NllResourcePreflightToolSetSha256 $ToolPath) -cne $ToolSha256) {
        throw 'phase_d_resource_preflight_receipt_drifted'
    }
    $receipt = Get-Content -LiteralPath $ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $current = Get-NllVoiceResourceSelection
    if ($current.language -cne $receipt.voiceLanguage -or $current.scope -cne $receipt.downloadScope) {
        throw 'phase_d_resource_voice_selection_changed'
    }
    $output = @(& $ToolPath loopback-verify $ReceiptPath)
    $exitCode = $LASTEXITCODE
    $result = ($output -join "`n") | ConvertFrom-Json
    if ($exitCode -ne 0 -or $result.statusCode -cne 'verified') {
        throw 'phase_d_resource_loopback_preflight_failed'
    }
    # Separate from historical optional-start checks: record this check only
    # after every selected catalog pair was actually served over loopback TLS.
    $evidence = [ordered]@{
        contractId = 'nll/resource-loopback-preflight/v1'
        statusCode = 'verified'
        catalogReceiptSha256 = $ReceiptSha256
        toolSetSha256 = $ToolSha256
        voiceLanguage = [string]$current.language
        downloadScope = [string]$current.scope
        catalogPairCount = 5
        physicalEndpointCode = 'ipv4_loopback_tls'
        officialOutboundPerformed = $false
        payloadClosureStatusCode = 'not_evaluated'
        actualPlayVerified = $false
        verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($evidence | ConvertTo-Json -Depth 4) + "`n")
    $stream = [IO.File]::Open($TransportReceiptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() }
    finally { $stream.Dispose() }
}
