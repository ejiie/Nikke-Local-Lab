[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GoldenStartPath,
    [Parameter(Mandatory = $true)]
    [string]$DerivedStartPath,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string]$ExpectedGoldenStartSha256,
    [Parameter(Mandatory = $true)]
    [int]$CacheFileCountBefore,
    [Parameter(Mandatory = $true)]
    [long]$CacheContentByteLengthBefore,
    [Parameter(Mandatory = $true)]
    [int]$CacheFileCountAfter,
    [Parameter(Mandatory = $true)]
    [long]$CacheContentByteLengthAfter
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ExactOccurrenceCount {
    param([string]$Text, [string]$Value)
    [regex]::Matches($Text, [regex]::Escape($Value)).Count
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporary, $Text, [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporary -Destination $Path
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

$expectedGoldenStartSha256 = $ExpectedGoldenStartSha256.ToLowerInvariant()
Assert-True (
    (Test-Path -LiteralPath $GoldenStartPath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $DerivedStartPath) -and
    (Get-Sha256Hex $GoldenStartPath) -ceq $expectedGoldenStartSha256 -and
    $CacheFileCountBefore -gt 0 -and
    $CacheContentByteLengthBefore -gt 0 -and
    $CacheFileCountAfter -eq ($CacheFileCountBefore + 2) -and
    $CacheContentByteLengthAfter -gt $CacheContentByteLengthBefore
) 'phase3b2_locale_overlay_start_input_invalid'

$goldenText = [IO.File]::ReadAllText(
    $GoldenStartPath, [Text.Encoding]::UTF8
)
$oldFileExpression = '$inspection.fileCount -eq ' +
    [string]$CacheFileCountBefore + ' -and'
$newFileExpression = '$inspection.fileCount -eq ' +
    [string]$CacheFileCountAfter + ' -and'
$oldByteExpression = '[long]$inspection.contentByteLength -eq ' +
    [string]$CacheContentByteLengthBefore + 'L -and'
$newByteExpression = '[long]$inspection.contentByteLength -eq ' +
    [string]$CacheContentByteLengthAfter + 'L -and'
$oldBindingExpression = '$sausToolBinding.wrapperToolSha256 -ceq ' +
    '(Get-Sha256Hex $PSCommandPath)'
$newBindingExpression = '$sausToolBinding.wrapperToolSha256 -ceq ' +
    "'$expectedGoldenStartSha256'"

Assert-True (
    (Get-ExactOccurrenceCount $goldenText $oldFileExpression) -eq 1 -and
    (Get-ExactOccurrenceCount $goldenText $oldByteExpression) -eq 1 -and
    (Get-ExactOccurrenceCount $goldenText $oldBindingExpression) -eq 1 -and
    (Get-ExactOccurrenceCount $goldenText $newFileExpression) -eq 0 -and
    (Get-ExactOccurrenceCount $goldenText $newByteExpression) -eq 0 -and
    (Get-ExactOccurrenceCount $goldenText $newBindingExpression) -eq 0
) 'phase3b2_locale_overlay_start_template_shape_invalid'

$derivedText = $goldenText.Replace($oldFileExpression, $newFileExpression)
$derivedText = $derivedText.Replace($oldByteExpression, $newByteExpression)
$derivedText = $derivedText.Replace(
    $oldBindingExpression, $newBindingExpression
)
$reversedText = $derivedText.Replace($newFileExpression, $oldFileExpression)
$reversedText = $reversedText.Replace($newByteExpression, $oldByteExpression)
$reversedText = $reversedText.Replace(
    $newBindingExpression, $oldBindingExpression
)
Assert-True (
    $reversedText -ceq $goldenText -and
    (Get-ExactOccurrenceCount $derivedText $newFileExpression) -eq 1 -and
    (Get-ExactOccurrenceCount $derivedText $newByteExpression) -eq 1 -and
    (Get-ExactOccurrenceCount $derivedText $newBindingExpression) -eq 1 -and
    (Get-ExactOccurrenceCount $derivedText $oldFileExpression) -eq 0 -and
    (Get-ExactOccurrenceCount $derivedText $oldByteExpression) -eq 0 -and
    (Get-ExactOccurrenceCount $derivedText $oldBindingExpression) -eq 0
) 'phase3b2_locale_overlay_start_reverse_projection_invalid'

Write-AtomicUtf8NoBom $DerivedStartPath $derivedText
Assert-True (
    (Get-Sha256Hex $GoldenStartPath) -ceq $expectedGoldenStartSha256
) 'phase3b2_locale_overlay_start_golden_mutated'

$goldenBytes = [IO.File]::ReadAllBytes($GoldenStartPath)
$derivedBytes = [IO.File]::ReadAllBytes($DerivedStartPath)
$changedByteCount = -1
if ($goldenBytes.Length -eq $derivedBytes.Length) {
    $changedByteCount = 0
    for ($index = 0; $index -lt $goldenBytes.Length; $index++) {
        if ($goldenBytes[$index] -ne $derivedBytes[$index]) {
            $changedByteCount++
        }
    }
}

[pscustomobject]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-locale-overlay-start-derivation/v1'
    goldenStartByteLength = [long]$goldenBytes.Length
    goldenStartSha256 = $expectedGoldenStartSha256
    derivedStartByteLength = [long]$derivedBytes.Length
    derivedStartSha256 = Get-Sha256Hex $DerivedStartPath
    cacheFileCountBefore = $CacheFileCountBefore
    cacheFileCountAfter = $CacheFileCountAfter
    cacheContentByteLengthBefore = $CacheContentByteLengthBefore
    cacheContentByteLengthAfter = $CacheContentByteLengthAfter
    exactExpressionReplacementCount = 3
    reverseProjectionVerified = $true
    goldenStartUnchanged = $true
    derivedSelfHashCheckRemoved = $true
    parentGoldenBindingPreserved = $true
    changedByteCount = $changedByteCount
} | ConvertTo-Json -Depth 5
