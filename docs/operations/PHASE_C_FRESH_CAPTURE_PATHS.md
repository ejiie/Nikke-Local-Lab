# Phase C fresh capture fixed paths

## Purpose

This document is the single path authority for the Phase C fresh account and
progression capture flow. Do not infer package directory punctuation or raw
output placement from nearby folders.

## Fixed paths

| Role | Exact path |
|---|---|
| Official current client/update root | `C:\NIKKE` |
| Frozen Phase3B2 client lane (not an official mirror) | `C:\NLL\Clients\NIKKE-150.6.9-Physical` |
| Active repository | `C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab` |
| Local secret input | `C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\.env` |
| Fetch launcher | `C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\scripts\invoke-nll-phase-c-fresh-account-fetch.ps1` |
| Account collector | `C:\Users\nlloperator\Downloads\NLL-Imported-Samsung\getFromBlaLink.py` |
| Collector Python | `C:\Users\nlloperator\Downloads\NLL-Imported-Samsung\.venv\Scripts\python.exe` |
| Playwright browser root | `C:\Users\nlloperator\AppData\Local\ms-playwright` |
| Account raw output | `C:\Users\nlloperator\Database\raw\nikke_full_scroll_result.json` |
| Trigger archive root | `C:\Users\nlloperator\AppData\LocalLow\com_proximabeta\NIKKE` |
| Trigger archive pattern | `NKSD_TRIGGER_<schema>_<account-key>` |
| Clean hosts recovery snapshot for this Micron OS | `C:\NLL\Backups\Phase3B2\Physical-P0-v1\hosts.original.bin` |
| Historical v8 completion repair | `C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\scripts\repair-phase3b2-epinel-solo-raid-damage-source-observer-v8-completion-offline.ps1` |
| Same-capture gate | `C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\scripts\test-nll-phase-c-same-capture-inputs.ps1` |
| Phase C acceptance | `C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\scripts\invoke-nll-phase-c-operator-fetch-acceptance.ps1` |

The trigger package directory contains an underscore: `com_proximabeta`.
`com.proximabeta` is a different directory and must not be substituted.

The collector calculates its output below `C:\Users\nlloperator\Database\raw`.
The migrated copy beside `getFromBlaLink.py` is not the active output and must
not be used as a fresh capture.

On Micron, the official launcher updates and starts `C:\NIKKE`. The Phase C
fresh trigger sync may use that official-current client after the runtime is
cold. Local Lab private-server scripts must not repoint the official tree, and
the official launcher must not update the frozen Phase3B2 lane. `E:\NIKKE` is
the mounted Samsung installation and is not a Phase C input. See
[MICRON_CURRENT_PATHS.md](../MICRON_CURRENT_PATHS.md).

## Runtime UID and `.env` fields

UID is a per-run account selector. The fetch launcher asks for it in a Windows
input dialog each time and passes it to the collector only for that process. It
does not store the UID in `.env` or in a launcher receipt. For non-interactive
automation, supply `-Uid <digits>` explicitly.

The local `.env` file is Git-ignored and must remain untracked. Fill these three
credential/configuration fields locally:

```dotenv
NIKKE_BLABLA_ID=
NIKKE_BLABLA_PW=
NIKKE_REGION=JP/KR/NA/SEA/Global
```

The launcher reads only these three names from the repository `.env`, sets them
for the collector child process, and restores its prior process environment in
a `finally` block. It never prints the values.

Before showing the UID dialog, the launcher asks the installed Playwright
version for its exact Chromium install location. If the headed
`chrome-win64\chrome.exe` member is absent, it runs `python -m playwright
install chromium`, waits for completion, and verifies the executable again.
This prevents a partially completed browser download from reaching the fetch
step.

## Operator sequence

1. Create the same-capture request while the runtime is cold.
2. Fill the three repository `.env` fields.
3. Run the account fetch and enter the target UID in the input dialog:

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass -Force
   & 'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\scripts\invoke-nll-phase-c-fresh-account-fetch.ps1'
   ```

   Non-interactive invocation is also supported:

   ```powershell
   & 'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\scripts\invoke-nll-phase-c-fresh-account-fetch.ps1' `
       -Uid '<digits>'
   ```

4. Reuse the matching account's existing `NKSD_TRIGGER_*` archive when its
   cumulative progression is already sufficient and unchanged. Enter the
   official client and refresh it only when the archive is missing, belongs to
   another UID, has an invalid shape/version, or the account actually gained
   new progression.
5. Run the same-capture gate with the request manifest and `-RequireReady`.
6. Run Phase C acceptance only after the gate reports
   `readyForOfflineMaterialization=true`.

`NKSD_TRIGGER_*` is a persisted cumulative NIKKE client output. The repository
extraction and gate scripts read it; they do not synthesize or rename it. Phase
C inspection v2 requires a unique UID match but does not require a new file
mtime for unchanged progression. `-RequireFreshTriggerArchive` restores the
strict request-time freshness gate when an operator knows progression changed.

When the fetched profile identifier and the client archive filename use
different identifier domains, the operator may bind an already-complete
archive explicitly with `-ProgressionTemplateArchivePath`. The v2 inspection
receipt records `operator_selected_progression_template`; neither the selected
path nor the account identifier is persisted. This mode treats the archive as
a reusable content-unlock progression template rather than same-account live
state and must not be used to claim current official progression freshness.

## Regression incident

The first gate revision bound both inputs incorrectly:

- it checked `com.proximabeta` instead of `com_proximabeta`;
- it checked a migrated stale JSON beside the collector instead of the
  collector's active `Database\raw` output.

Both gate and acceptance defaults must continue to match this document. A path
audit should fail when either the dot-form LocalLow directory or the migrated
raw copy is reintroduced as an active default.

## 2026-08-29 blank BlaBla login incident

### Symptom and observed cause

The headed BlaBlaLink browser opened its login shell, but the body below the
region selector remained blank. The account collector therefore could not
reach the email and password controls.

This was not a collector selector failure or a BlaBlaLink account failure. A
credential-free browser observation showed both login SDK members failing with
`net::ERR_CONNECTION_REFUSED`:

- `https://common-web.intlgame.com/sdk-cdn/infinite-pass/latest/index.css`
- `https://common-web.intlgame.com/sdk-cdn/infinite-pass/latest/index.umd.js`

The active Windows hosts file resolved `common-web.intlgame.com` to
`127.0.0.1`. The mapping belonged to the appended
`# begin NLL Phase3B2 Physical entries` block.

The stale block predated the Phase3B2 DamageSourceObserver-v8 run. The v8
completion truthfully reported `hostsRestored=true`, but it restored the exact
per-run `hosts.before.bin`, whose SHA-256 was already the contaminated value
`dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0`.
Therefore `hostsRestored=true` means only *restored to the captured run
baseline*. It does not by itself prove that official domains are no longer
loopback-bound.

### Recovery and sealed evidence

The abandoned v8 run was `9db13331-aa5b-469e-aaa5-d92bcb11c16e`.
Its completion repair corrected the damage-source sum for both Windows
PowerShell 5.1 and PowerShell 7, then the normal completion restored the DB,
removed SQLite runtime members, removed the extension firewall group, archived
the active pointer, and left the runtime cold.

The relevant receipts are:

- repair receipt:
  `C:\NLL\E\P3SRDSO8D\completion-repair-v1\fa0a5b60-fa43-46b7-ac79-426501b86cfb\repair.receipt.json`
- repair receipt SHA-256:
  `e1133e09cc528f10218c9702ecc78949f57cd2757612afdf4288702b641acfba`
- completion receipt:
  `C:\NLL\E\P3SRDSO8\9db13331-aa5b-469e-aaa5-d92bcb11c16e\completion.receipt.json`
- completion receipt SHA-256:
  `d5179bac2db5114204cc124db64fdf062d6be75c2fa8ea5a8115844f587130b7`

After the run was cold, the current hosts file was compared line-for-line with
the original Physical-P0 snapshot. The only extra content was the complete NLL
Phase3B2 block, so the original snapshot was restored. The verified clean state
for this Micron OS is:

- hosts byte length: `1054`
- hosts SHA-256:
  `565955a47a890e8090a2987a234ba05e2624c84a587ba86e8648f912678984b9`
- NLL Phase3B2 hosts block present: `false`
- live v8 active pointer present: `false`

After DNS cache flush, `common-web.intlgame.com` resolved through public CDN
CNAMEs rather than `127.0.0.1`. A second credential-free browser observation
returned HTTP `200` for both login SDK members, with zero SDK request failures,
and displayed visible email and password inputs plus the `Log in` button. No
collector selector change was required for this incident.

### Required regression barriers

Before the next Phase C official account fetch:

1. The original-client runtime must be cold and no live NLL active-run pointer
   may exist.
2. `common-web.intlgame.com` must not resolve to loopback.
3. The hosts file must not contain the NLL Phase3B2 block while an official
   login or fetch is attempted.
4. The login SDK CSS and JS must be reachable before a headed browser is
   launched. A failure should stop before credentials are read or entered.

Before the next original-client Phase3B2 lane:

1. The contaminated PhysicalP2-v2 hash
   `dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0`
   must not be admitted as a clean OS hosts baseline.
2. Start and completion must record two independent postconditions:
   `restoredToCapturedBaseline` and `officialDomainsUnboundAfterCompletion`.
3. Completion must fail if any NLL-owned official-domain mapping remains after
   rollback, even when the final file matches the captured pre-run hash.
4. Repair and completion audits that operators run in Windows PowerShell must
   be exercised in Windows PowerShell 5.1 as well as PowerShell 7. The v8 repair
   incident demonstrated that an ordered dictionary/JSON array fixture can
   pass in one runtime and fail in the other.
