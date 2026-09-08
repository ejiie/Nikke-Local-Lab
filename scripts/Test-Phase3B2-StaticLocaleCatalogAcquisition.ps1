[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function New-RequestManifest {
    param(
        [string]$Path,
        [string]$LocaleCode,
        [long]$ContentVersion,
        [string]$RevisionCode,
        [string]$CdnHost = 'cloud.nikke-kr.com',
        [string]$SignatureSuffix = '.nds'
    )
    $baseUri = 'https://' + $CdnHost +
        '/prdenv/150-b059c3f36c/StandaloneWindows64/pck/' +
        $LocaleCode + '/' + $RevisionCode + '/asset-catalog.cat'
    $manifest = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-approved-static-locale-catalog-request/v1'
        requestSetUid = [Guid]::NewGuid().ToString('D')
        clientBuild = '150.6.9'
        clientBuildRoot = '150-b059c3f36c'
        latestPostfix = '651'
        localeCode = $LocaleCode
        revisionCode = $RevisionCode
        contentVersion = $ContentVersion
        members = @(
            [ordered]@{
                roleCode = 'locale_catalog_body'
                kindCode = 'nkdb_body'
                uri = $baseUri
            },
            [ordered]@{
                roleCode = 'locale_catalog_signature'
                kindCode = 'detached_signature_96'
                uri = $baseUri + $SignatureSuffix
            }
        )
    }
    Write-Utf8NoBom $Path (($manifest | ConvertTo-Json -Depth 6) + "`n")
}

function Assert-ValidationPasses {
    param(
        [string]$ScriptPath,
        [string]$ManifestPath,
        [string]$VersionMapPath,
        [string]$VersionMapSha256,
        [string]$ExpectedLocale,
        [string]$ExpectedRevision
    )
    $json = & $ScriptPath `
        -RequestManifestPath $ManifestPath `
        -VersionMapPath $VersionMapPath `
        -ExpectedVersionMapSha256 $VersionMapSha256
    $receipt = $json | ConvertFrom-Json
    Assert-True ($receipt.contractId -ceq
            'nll/phase3b2-static-locale-catalog-request-validation/v1' -and
        $receipt.localeCode -ceq $ExpectedLocale -and
        $receipt.revisionCode -ceq $ExpectedRevision -and
        $receipt.approvedMemberCount -eq 2 -and
        $receipt.readyForExplicitAcquisition -and
        -not $receipt.micronMutationAllowed) `
        'phase3b2_static_locale_test_valid_manifest_rejected'
}

function Assert-ValidationFails {
    param(
        [string]$ScriptPath,
        [string]$ManifestPath,
        [string]$VersionMapPath,
        [string]$VersionMapSha256,
        [string]$ExpectedFailureCode
    )
    $observed = ''
    try {
        & $ScriptPath `
            -RequestManifestPath $ManifestPath `
            -VersionMapPath $VersionMapPath `
            -ExpectedVersionMapSha256 $VersionMapSha256 | Out-Null
    }
    catch { $observed = $_.Exception.Message }
    Assert-True ($observed -ceq $ExpectedFailureCode) `
        'phase3b2_static_locale_test_invalid_manifest_accepted'
}

$scriptPath = Join-Path $PSScriptRoot `
    'invoke-phase3b2-static-locale-catalog-acquisition-on-samsung.ps1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('NLL-StaticLocaleCatalogTest-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    $versionMapPath = Join-Path $temporaryRoot 'latest-651.txt'
    Write-Utf8NoBom $versionMapPath (@(
        'core:552831,150.6.b15'
        'dp:553076,1d5645e'
        'en:552072,dee9e75'
        'ja:552078,8995876'
        'ko:551960,bef9fc2'
        'fd:552446,85b12fc'
        'saus:552998,19e939d'
    ) -join "`n")
    $versionMapSha256 = Get-Sha256Hex $versionMapPath

    $enPath = Join-Path $temporaryRoot 'en.request.json'
    New-RequestManifest -Path $enPath -LocaleCode 'en' `
        -ContentVersion 552072 -RevisionCode 'dee9e75'
    Assert-ValidationPasses -ScriptPath $scriptPath `
        -ManifestPath $enPath -VersionMapPath $versionMapPath `
        -VersionMapSha256 $versionMapSha256 -ExpectedLocale 'en' `
        -ExpectedRevision 'dee9e75'

    $koPath = Join-Path $temporaryRoot 'ko.request.json'
    New-RequestManifest -Path $koPath -LocaleCode 'ko' `
        -ContentVersion 551960 -RevisionCode 'bef9fc2'
    Assert-ValidationPasses -ScriptPath $scriptPath `
        -ManifestPath $koPath -VersionMapPath $versionMapPath `
        -VersionMapSha256 $versionMapSha256 -ExpectedLocale 'ko' `
        -ExpectedRevision 'bef9fc2'

    $wrongRevisionPath = Join-Path $temporaryRoot 'wrong-revision.request.json'
    New-RequestManifest -Path $wrongRevisionPath -LocaleCode 'en' `
        -ContentVersion 552072 -RevisionCode 'bef9fc2'
    Assert-ValidationFails -ScriptPath $scriptPath `
        -ManifestPath $wrongRevisionPath -VersionMapPath $versionMapPath `
        -VersionMapSha256 $versionMapSha256 `
        -ExpectedFailureCode `
            'phase3b2_static_locale_request_version_map_mismatch'

    $wrongHostPath = Join-Path $temporaryRoot 'wrong-host.request.json'
    New-RequestManifest -Path $wrongHostPath -LocaleCode 'en' `
        -ContentVersion 552072 -RevisionCode 'dee9e75' `
        -CdnHost 'example.invalid'
    Assert-ValidationFails -ScriptPath $scriptPath `
        -ManifestPath $wrongHostPath -VersionMapPath $versionMapPath `
        -VersionMapSha256 $versionMapSha256 `
        -ExpectedFailureCode `
            'phase3b2_static_locale_request_member_binding_invalid'

    $wrongSignaturePath = Join-Path $temporaryRoot `
        'wrong-signature.request.json'
    New-RequestManifest -Path $wrongSignaturePath -LocaleCode 'ko' `
        -ContentVersion 551960 -RevisionCode 'bef9fc2' `
        -SignatureSuffix '.sig'
    Assert-ValidationFails -ScriptPath $scriptPath `
        -ManifestPath $wrongSignaturePath -VersionMapPath $versionMapPath `
        -VersionMapSha256 $versionMapSha256 `
        -ExpectedFailureCode `
            'phase3b2_static_locale_request_member_binding_invalid'

    [pscustomobject]@{
        contractId =
            'nll/phase3b2-static-locale-catalog-acquisition-tests/v1'
        passedCount = 5
        localeValidationPassed = @('en', 'ko')
        versionMapMismatchRejected = $true
        alternateHostRejected = $true
        alternateSignaturePathRejected = $true
        networkRequestStarted = $false
        micronMutationPerformed = $false
    } | ConvertTo-Json -Depth 4
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
