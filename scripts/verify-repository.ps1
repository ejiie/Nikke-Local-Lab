param(
    [ValidateSet("working", "tracked", "staged")]
    [string]$Mode = "working",
    [switch]$AllowRemote
)

$ErrorActionPreference = "Stop"

function Add-Failure {
    param([string]$Message)
    $script:Failures.Add($Message)
}

function Normalize-PathText {
    param([string]$PathText)
    return $PathText.Replace("\\", "/").TrimStart("./")
}

$Failures = [System.Collections.Generic.List[string]]::new()
$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDirectory ".."))

$TemporaryPostgreSqlPath = Join-Path $RepositoryRoot ".tmp-pg"
if (Test-Path -LiteralPath $TemporaryPostgreSqlPath) {
    Add-Failure "Disposable PostgreSQL cluster must not remain in the repository workspace: .tmp-pg"
}

$GitTop = (& git -C $RepositoryRoot rev-parse --show-toplevel).Trim()
if ([System.IO.Path]::GetFullPath($GitTop) -ne $RepositoryRoot) {
    Add-Failure "Git top-level is not the new repository root: $GitTop"
}

$ExpectedGitDirectory = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot ".git"))
if (-not (Test-Path -LiteralPath $ExpectedGitDirectory -PathType Container)) {
    Add-Failure ".git must be an independent directory, not a linked worktree file."
}

$CommonDirectoryText = (& git -C $RepositoryRoot rev-parse --git-common-dir).Trim()
$CommonDirectory = if ([System.IO.Path]::IsPathRooted($CommonDirectoryText)) {
    [System.IO.Path]::GetFullPath($CommonDirectoryText)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $CommonDirectoryText))
}
if ($CommonDirectory -ne $ExpectedGitDirectory) {
    Add-Failure "Git common directory points outside this repository: $CommonDirectory"
}

$Remotes = @(& git -C $RepositoryRoot remote)
if (-not $AllowRemote -and $Remotes.Count -gt 0) {
    Add-Failure "Remote repositories are not allowed in the local-only baseline: $($Remotes -join ', ')"
}

$Paths = switch ($Mode) {
    "tracked" { @(& git -C $RepositoryRoot ls-files) }
    "staged" { @(& git -C $RepositoryRoot diff --cached --name-only --diff-filter=ACMR) }
    default { @(& git -C $RepositoryRoot ls-files --cached --others --exclude-standard) }
}

$ForbiddenDirectoryPattern = '(^|/)(data|Database|raw|decoded|decrypted|extracted|bundles|captures|dumps|outputs|artifacts|cache|var|logs|tmp|\.tmp-pg|secrets|vault|staging|runtime|NikkeLocalLab|TestResults)(/|$)'
$ForbiddenNamePattern = '(^|/)(\.env($|\.)|auth_state[^/]*\.json$|cookies?[^/]*\.json$|credentials?[^/]*\.json$|sessions?[^/]*\.json$|tokens?[^/]*\.json$|\.gitmodules$)'
$ForbiddenExtensions = @(
    ".mpk", ".bundle", ".unity3d", ".assets", ".asset", ".ress", ".resource",
    ".ab", ".pak", ".obb", ".bytes", ".bin", ".dat", ".nds", ".lsc",
    ".db", ".db3", ".sqlite", ".sqlite3", ".wal", ".shm", ".journal",
    ".dump", ".backup", ".bak", ".png", ".jpg", ".jpeg", ".webp", ".gif",
    ".bmp", ".tga", ".dds", ".ktx", ".ktx2", ".astc", ".pvr", ".psd",
    ".ogg", ".wav", ".mp3", ".bank", ".wem", ".mp4", ".webm", ".avi",
    ".mov", ".fbx", ".mesh", ".anim", ".controller", ".prefab", ".unity",
    ".spriteatlas", ".zip", ".7z", ".rar", ".tar", ".gz", ".xz", ".zst",
    ".exe", ".dll", ".pdb", ".so", ".dylib", ".apk", ".log", ".trx",
    ".dmp", ".etl", ".pcap", ".har", ".jsonl", ".ndjson"
)

$PrivateKeyPattern = '-----BEGIN ' + '[A-Z ]*PRIVATE KEY-----'
$BearerPattern = 'Authorization\s*:\s*' + 'Bearer\s+[A-Za-z0-9._~+/-]{20,}'
$JwtPattern = '\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\b'
$LongBlobPattern = '[A-Za-z0-9+/]{512,}={0,2}'

foreach ($PathEntry in $Paths) {
    if ([string]::IsNullOrWhiteSpace($PathEntry)) { continue }

    $RelativePath = Normalize-PathText $PathEntry
    $FullPath = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $RelativePath))

    if (-not $FullPath.StartsWith($RepositoryRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Failure "Path escapes repository root: $RelativePath"
        continue
    }
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { continue }

    if ($RelativePath -match $ForbiddenDirectoryPattern) {
        Add-Failure "Forbidden runtime/data directory is tracked: $RelativePath"
    }
    if ($RelativePath -match $ForbiddenNamePattern) {
        Add-Failure "Forbidden secret/session path is tracked: $RelativePath"
    }

    $Extension = [System.IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
    if ($ForbiddenExtensions -contains $Extension) {
        Add-Failure "Forbidden binary/data extension is tracked: $RelativePath"
    }

    $Item = Get-Item -LiteralPath $FullPath -Force
    if ($Item.LinkType) {
        Add-Failure "Symbolic links are not allowed: $RelativePath"
    }
    if ($Item.Length -gt 1MB) {
        Add-Failure "Tracked file exceeds 1 MiB: $RelativePath ($($Item.Length) bytes)"
    }

    if ($Extension -eq ".json") {
        $AllowedJson = (
            $RelativePath -match '^contracts/.+\.schema\.json$' -or
            $RelativePath -match '^config/.+\.example\.json$' -or
            $RelativePath -match '^tests/fixtures/synthetic/.+\.json$' -or
            $RelativePath -match '^tests/fixtures/evidence/.+\.json$' -or
            $RelativePath -eq 'global.json' -or
            $RelativePath -match '(^|/)packages\.lock\.json$'
        )
        if (-not $AllowedJson) {
            Add-Failure "JSON is outside the Phase 0 allowlist: $RelativePath"
        }
        try {
            Get-Content -Raw -LiteralPath $FullPath | ConvertFrom-Json | Out-Null
        } catch {
            Add-Failure "Invalid JSON: $RelativePath ($($_.Exception.Message))"
        }
    }

    $Header = New-Object byte[] 16
    $Stream = [System.IO.File]::OpenRead($FullPath)
    try {
        $HeaderLength = $Stream.Read($Header, 0, $Header.Length)
    } finally {
        $Stream.Dispose()
    }
    $HeaderAscii = [System.Text.Encoding]::ASCII.GetString($Header, 0, $HeaderLength)
    if (($HeaderLength -ge 4 -and $Header[0] -eq 0x50 -and $Header[1] -eq 0x4B) -or
        ($HeaderLength -ge 8 -and $Header[0] -eq 0x89 -and $Header[1] -eq 0x50 -and $Header[2] -eq 0x4E -and $Header[3] -eq 0x47) -or
        ($HeaderLength -ge 2 -and $Header[0] -eq 0x4D -and $Header[1] -eq 0x5A) -or
        ($HeaderLength -ge 4 -and $Header[0] -eq 0x7F -and $Header[1] -eq 0x45 -and $Header[2] -eq 0x4C -and $Header[3] -eq 0x46) -or
        $HeaderAscii.StartsWith("UnityFS")) {
        Add-Failure "Binary/archive magic is not allowed: $RelativePath"
    }

    if ($Item.Length -le 1MB) {
        $Text = Get-Content -Raw -LiteralPath $FullPath -ErrorAction SilentlyContinue
        if ($null -ne $Text) {
            if ($Text -match '^version https://git-lfs.github.com/spec/v1') {
                Add-Failure "Git LFS pointers are not allowed: $RelativePath"
            }
            if ($Text -match $PrivateKeyPattern -or $Text -match $BearerPattern -or $Text -match $JwtPattern) {
                Add-Failure "Possible credential material detected: $RelativePath"
            }
            if ($Text -match $LongBlobPattern) {
                Add-Failure "Possible embedded binary/Base64 blob detected: $RelativePath"
            }
        }
    }
}

$GitLinks = @(& git -C $RepositoryRoot ls-files --stage | Select-String '^160000 ')
if ($GitLinks.Count -gt 0) {
    Add-Failure "Git submodules/gitlinks are not allowed."
}

$ManifestPath = Join-Path $RepositoryRoot "tests/fixtures/synthetic/manifest.json"
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    Add-Failure "Synthetic fixture manifest is missing."
} else {
    $Manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
    if ($Manifest.classification -ne "synthetic" -or
        $Manifest.source -ne "hand-authored" -or
        $Manifest.containsGameContent -ne $false -or
        $Manifest.containsRealAccountData -ne $false) {
        Add-Failure "Synthetic fixture manifest does not satisfy the repository policy."
    }
}

$EvidenceManifestPath = Join-Path $RepositoryRoot "tests/fixtures/evidence/manifest.json"
if (-not (Test-Path -LiteralPath $EvidenceManifestPath -PathType Leaf)) {
    Add-Failure "Source-free evidence fixture manifest is missing."
} else {
    try {
        $EvidenceManifest = Get-Content -Raw -LiteralPath $EvidenceManifestPath | ConvertFrom-Json
        if ($EvidenceManifest.classification -ne "source_free_evidence" -or
            $EvidenceManifest.source -ne "local_read_only_measurement" -or
            $EvidenceManifest.containsGameContent -ne $false -or
            $EvidenceManifest.containsRealAccountData -ne $false -or
            $EvidenceManifest.containsRawIdentifiers -ne $false -or
            $EvidenceManifest.containsLocalPaths -ne $false) {
            Add-Failure "Source-free evidence fixture manifest does not satisfy the repository policy."
        }

        $DeclaredEvidenceFixtures = @($EvidenceManifest.fixtures)
        $CanonicalDeclaredEvidenceFixtures = @($DeclaredEvidenceFixtures | Sort-Object -CaseSensitive -Unique)
        if (($DeclaredEvidenceFixtures -join "`n") -cne ($CanonicalDeclaredEvidenceFixtures -join "`n")) {
            Add-Failure "Source-free evidence fixture manifest entries must be unique and ordinally sorted."
        }

        foreach ($FixtureName in $DeclaredEvidenceFixtures) {
            if ($FixtureName -notmatch '^[a-z0-9][a-z0-9.-]{0,127}\.json$') {
                Add-Failure "Invalid source-free evidence fixture name: $FixtureName"
                continue
            }

            $EvidenceFixturePath = Join-Path (Split-Path -Parent $EvidenceManifestPath) $FixtureName
            if (-not (Test-Path -LiteralPath $EvidenceFixturePath -PathType Leaf)) {
                Add-Failure "Declared source-free evidence fixture is missing: $FixtureName"
            }
        }

        $PresentEvidenceFixtures = @(Get-ChildItem -LiteralPath (Split-Path -Parent $EvidenceManifestPath) -File -Filter '*.json' |
            Where-Object { $_.Name -ne 'manifest.json' } |
            Select-Object -ExpandProperty Name |
            Sort-Object -CaseSensitive)
        if (($PresentEvidenceFixtures -join "`n") -cne ($CanonicalDeclaredEvidenceFixtures -join "`n")) {
            Add-Failure "Source-free evidence fixtures and manifest entries differ."
        }
    } catch {
        Add-Failure "Invalid source-free evidence fixture manifest: $($_.Exception.Message)"
    }
}

if ($Failures.Count -gt 0) {
    Write-Error ("Repository policy failed:`n - " + ($Failures -join "`n - "))
    exit 1
}

Write-Output "Repository policy passed ($Mode): $($Paths.Count) file(s) checked."
