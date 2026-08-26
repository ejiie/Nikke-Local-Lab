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

function Invoke-DerivationCase {
    param(
        [string]$Root,
        [string]$Name,
        [int]$AfterCount,
        [long]$AfterBytes
    )

    $goldenPath = Join-Path $Root ($Name + '.golden.ps1')
    $derivedPath = Join-Path $Root ($Name + '.derived.ps1')
    $goldenText = @(
        "`$inspection = Get-SyntheticInspection"
        "Assert-True (`$inspection.fileCount -eq 40111 -and"
        "    [long]`$inspection.contentByteLength -eq 39030643658L -and"
        "`$sausToolBinding.wrapperToolSha256 -ceq " +
            '(Get-Sha256Hex $PSCommandPath)'
        "    `$inspection.partialMemberCount -eq 0) 'invalid'"
    ) -join "`r`n"
    Write-Utf8NoBom $goldenPath ($goldenText + "`r`n")
    $goldenSha256 = Get-Sha256Hex $goldenPath

    $json = & $derivationTool `
        -GoldenStartPath $goldenPath `
        -DerivedStartPath $derivedPath `
        -ExpectedGoldenStartSha256 $goldenSha256 `
        -CacheFileCountBefore 40111 `
        -CacheContentByteLengthBefore 39030643658L `
        -CacheFileCountAfter $AfterCount `
        -CacheContentByteLengthAfter $AfterBytes
    $receipt = ($json | Out-String) | ConvertFrom-Json
    $derivedText = [IO.File]::ReadAllText(
        $derivedPath, [Text.Encoding]::UTF8
    )
    Assert-True (
        $receipt.contractId -ceq
            'nll/phase3b2-epinel-locale-overlay-start-derivation/v1' -and
        $receipt.exactExpressionReplacementCount -eq 3 -and
        $receipt.reverseProjectionVerified -and
        $receipt.goldenStartUnchanged -and
        $receipt.derivedSelfHashCheckRemoved -and
        $receipt.parentGoldenBindingPreserved -and
        (Get-Sha256Hex $goldenPath) -ceq $goldenSha256 -and
        $derivedText.Contains(
            '$inspection.fileCount -eq ' + [string]$AfterCount + ' -and'
        ) -and
        $derivedText.Contains(
            '[long]$inspection.contentByteLength -eq ' +
            [string]$AfterBytes + 'L -and'
        ) -and
        $derivedText.Contains(
            '$sausToolBinding.wrapperToolSha256 -ceq ' +
            "'$goldenSha256'"
        )
    ) 'phase3b2_locale_overlay_test_valid_derivation_failed'
}

$derivationTool = Join-Path $PSScriptRoot `
    'new-phase3b2-epinel-locale-overlay-start.ps1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'NLL-EpinelLocaleOverlayTest-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    Invoke-DerivationCase -Root $temporaryRoot -Name 'en' `
        -AfterCount 40113 -AfterBytes 39031656543L
    Invoke-DerivationCase -Root $temporaryRoot -Name 'ko' `
        -AfterCount 40113 -AfterBytes 39032000000L

    $duplicateGolden = Join-Path $temporaryRoot 'duplicate.golden.ps1'
    $duplicateDerived = Join-Path $temporaryRoot 'duplicate.derived.ps1'
    $duplicateLine = '$inspection.fileCount -eq 40111 -and'
    Write-Utf8NoBom $duplicateGolden (@(
            $duplicateLine
            $duplicateLine
            '[long]$inspection.contentByteLength -eq 39030643658L -and'
            '$sausToolBinding.wrapperToolSha256 -ceq ' +
                '(Get-Sha256Hex $PSCommandPath)'
        ) -join "`n")
    $observedFailure = ''
    try {
        & $derivationTool `
            -GoldenStartPath $duplicateGolden `
            -DerivedStartPath $duplicateDerived `
            -ExpectedGoldenStartSha256 (Get-Sha256Hex $duplicateGolden) `
            -CacheFileCountBefore 40111 `
            -CacheContentByteLengthBefore 39030643658L `
            -CacheFileCountAfter 40113 `
            -CacheContentByteLengthAfter 39031656543L | Out-Null
    }
    catch { $observedFailure = $_.Exception.Message }
    Assert-True ($observedFailure -ceq
        'phase3b2_locale_overlay_start_template_shape_invalid') `
        'phase3b2_locale_overlay_test_ambiguous_template_accepted'

    [pscustomobject]@{
        contractId = 'nll/phase3b2-epinel-locale-overlay-tests/v1'
        passedCount = 3
        englishDerivationPassed = $true
        koreanDerivationPassed = $true
        ambiguousGoldenTemplateRejected = $true
        goldenMutationPerformed = $false
        networkRequestStarted = $false
        clientExecutionStarted = $false
    } | ConvertTo-Json -Depth 4
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
