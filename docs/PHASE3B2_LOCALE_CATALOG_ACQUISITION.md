# Phase 3B-2 locale catalog acquisition

## Purpose

This lane acquires one exact locale catalog pair without changing the Micron
runtime, the golden lobby baseline, or either operator cache. It is separate
from the existing six-member `core`/`dp`/`fd` acquisition lane.

The implementation is locale-parameterized. English is the first target, but
Korean and later locale changes use the same scripts and contracts. A locale
change supplies a different protected version-map row and request manifest;
it does not require a code change.

## Inputs and derivation

The protected, Git-external `latest-<postfix>.txt` file is authoritative for:

- locale code;
- content version;
- seven-character revision code.

`new-phase3b2-static-locale-catalog-request-offline.ps1` selects one locale
row and derives exactly two static-CDN members:

1. `asset-catalog.cat` as an `NKDB` body;
2. `asset-catalog.cat.nds` as its 96-byte detached signature.

The request manifest records the client build, build root, postfix, locale,
version, revision, and exact member URIs. It stays under the protected
Git-external acquisition root. The repository stores no acquired catalog body,
signature, or private transport manifest.

## Validation and execution split

`invoke-phase3b2-static-locale-catalog-acquisition-on-samsung.ps1` defaults to
validation only. Validation checks the version-map hash, exact locale row,
derived URI equality, host, scheme, path, member order, and pair shape without
starting a network request.

Network execution additionally requires both:

- `-ExecuteApprovedAcquisition`;
- the reviewed request-manifest SHA-256 through
  `-ExpectedRequestManifestSha256`.

Execution is allowed only while Samsung is booted, Micron is offline, and the
launcher, client, private server, and physical bootstrap are all cold. The HTTP
client follows no redirects, uses no proxy, cookies, default credentials,
authorization, or decompression, and accepts only status 200 with no redirect,
cookie, or content-encoding response boundary. System TLS hostname validation
remains active.

The acquired body must start with `NKDB`; the detached signature must be
exactly 96 bytes. Only source-free role, kind, length, and SHA-256 data is
canonicalized into the receipt. URIs and relative paths remain in protected
Git-external evidence.

## Locale switch procedure

For English now, prepare and review an `en` manifest. For Korean later, repeat
the same preparation with `-LocaleCode ko` against the newly approved version
map. Never copy the English revision into the Korean manifest or relabel an
English/SAUS catalog as Korean. The validator recomputes the selected revision
from the version map and rejects such drift.

Only one locale overlay may be active. To switch from English to Korean, first
run `rollback-phase3b2-sealed-locale-catalog-overlay-offline.ps1` from Samsung
with the English deployment UID and reviewed receipt hash. Then acquire, seal,
and stage the Korean pair through the same parameterized lane. The original
Golden start remains the derivation parent for either language.

Acquisition does not authorize staging into Micron. After sealing, inspect the
pair offline and create a separate, hash-bound staging decision. Until then,
do not retry the original client.

## Golden locale overlay

`stage-phase3b2-sealed-locale-catalog-overlay-offline.ps1` applies one sealed
locale pair while Samsung is booted and the Micron runtime is cold. It first
verifies the acquisition receipt, private transport manifest, source-free
manifest, exact `NKDB` body, 96-byte signature, Golden finalization receipt,
Golden database and tools, verifier bundle, hosts state, and full cache shape.
It then writes a dual-copy rollback plan, copies the two members into a
same-volume temporary directory, renames that directory into the exact
locale/revision cache location, and creates a new locale-specific start
script.

The active Golden start, inner start, completion tools, database, server
binary, hosts, and both LocalLow profiles remain unchanged. The derived start
is produced from the Golden start by replacing only the expected cache file
count and content-byte-length expressions. The derivation tool reverses both
replacements in memory and requires the result to equal the original Golden
text. This is an additive overlay, not an in-place wrapper binding.

The existing Golden completion command remains compatible because it consumes
the active-run pointer written by the unchanged inner start; it does not bind
the outer start filename or cache count. The staging receipt prints the only
authorized Micron start command. Do not run the Golden control start while an
overlay is active because it intentionally expects the pre-overlay cache
shape.

## Rollback

`rollback-phase3b2-static-locale-catalog-acquisition-on-samsung.ps1` verifies
the sealed receipt hash and moves the complete assessment to the protected
quarantine tree. It deletes no content and changes neither Micron nor caches.

That acquisition rollback is distinct from the active overlay rollback.
`rollback-phase3b2-sealed-locale-catalog-overlay-offline.ps1` accepts only the
exact deployment receipt and plan, requires a cold Micron runtime, archives
the exact active pair and derived start, and restores the Golden cache count
and byte length. It never replaces or rewrites the Golden tools.

If both members were downloaded and passed their individual shape checks but
the first implementation stopped before receipt sealing,
`seal-phase3b2-static-locale-catalog-pending-offline.ps1` validates that exact
Pending assessment. Its default mode is read-only. Explicit sealing requires
`-SealValidatedPending`; it performs no network request and preserves the
original failure receipt beside the recovered acquisition receipt.
