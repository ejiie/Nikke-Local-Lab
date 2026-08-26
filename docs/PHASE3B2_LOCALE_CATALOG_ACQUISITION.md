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

Acquisition does not authorize staging into Micron. After sealing, inspect the
pair offline and create a separate, hash-bound staging decision. Until then,
do not retry the original client.

## Rollback

`rollback-phase3b2-static-locale-catalog-acquisition-on-samsung.ps1` verifies
the sealed receipt hash and moves the complete assessment to the protected
quarantine tree. It deletes no content and changes neither Micron nor caches.

If both members were downloaded and passed their individual shape checks but
the first implementation stopped before receipt sealing,
`seal-phase3b2-static-locale-catalog-pending-offline.ps1` validates that exact
Pending assessment. Its default mode is read-only. Explicit sealing requires
`-SealValidatedPending`; it performs no network request and preserves the
original failure receipt beside the recovered acquisition receipt.
