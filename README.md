# Selective VPN Bypass

A lightweight **portable Windows companion for SoftEther VPN Client**, developed openly in this repository.

> **Preview / experimental:** Not yet tested end-to-end on Windows with live VPN connections. Network rules can affect connectivity.

## Download

**Windows executable:** Open [Actions](../../actions/workflows/build-windows.yml), select a successful **Build Windows portable** run and download the `SelectiveVPNBypass-Portable-Windows-x64` artifact. Extract it and run `SelectiveVPNBypass_GUI.exe`. GitHub login may be required for Actions artifacts.

**Code → Download ZIP** is the source ZIP. It is not an executable distribution. Tagged GitHub Releases will be published manually by **WhoSia** after testing—not by GitHub Actions bots.

**Latest verified CI package (2026-11-23 KST):** [Windows portable: worker-result validation, 3× GUI regression and read-only migration gate](https://github.com/WhoSia/Selective-VPN-Bypass/actions/runs/45056497157) · artifact `SelectiveVPNBypass-Portable-Windows-x64` · ZIP SHA-256 `C805C1A90BFEBFE16DF4869A83639C9BED58E541BB7266DEF55F23E88E5FE425`. PowerShell journal/migration tests, all 3 independently isolated WinForms interaction trials, Go unit/security tests, Windows x64 compile and artifact upload PASS. [Isolated Windows NRPT/route integration](https://github.com/WhoSia/Selective-VPN-Bypass/actions/runs/45056497117) PASS. This does not establish authenticated privileged journal authority, full crash safety, or live SoftEther behavior.

## Features

- Empty default exception list; add and remove domains (including .kr/.wiki) or IPv4 addresses.
- Local-only JSON configuration stored alongside the EXE; **never automatically imports a previous user's settings**.
- Status, Wi-Fi DNS lookup, Apply and Restore actions.
- Uses Windows PowerShell 5.1 built into Windows; no Python/Qt installation needed.
- Windows UAC approval is requested for Apply/Restore; ordinary list editing does not require elevation.
- Build is automated, but the workflow **never creates commits or releases**.

## Architecture

The Go executable now invokes its embedded Core PowerShell source **from memory for elevated Apply/Restore**, without loading a writable runtime-v4 script for privileged work. Read-only/list editing still uses the normal PowerShell worker. The privileged helper allows only Apply/Restore and validates the portable configuration folder and worker log name. The executable is not code-signed, so this is a trust-boundary hardening step, not verified resistance to executable replacement or every local attack.

Go executable embeds three PowerShell sources: `src/Gui.ps1` (WinForms UI), `src/Core.ps1` (validation/routing), `src/Worker.ps1` (command worker). This is **not** yet a native Go UI toolkit. A fully modern high-DPI interface is a future improvement; the preview uses DPI-scaled layout and needs real-world display testing.

## Status display and recovery expectations

The interface distinguishes the **saved exception list** from the **Windows operation journal**. `Journal: present (unverified)` means a recovery state file exists, **not** that Windows routing or DNS rules are verified active. `Journal: absent` means there is no saved recovery state for that portable folder; it does not prove that OS policies from an older folder or an interrupted operation are absent.

Use Add to save an entry; it does not immediately activate the entry. If Add fails, the typed entry is preserved to reduce repeated work. Apply/Restore require administrator approval; choosing not to approve is not itself evidence of a system fault.

Before moving or replacing portable folders, inspect any outstanding journal and avoid deleting the recovery state without knowing whether network objects remain. Do not share unredacted diagnostics that contain local addresses, network configuration or usernames.

For an independent engineering review covering user burden, failure states, security assumptions and verification gaps, see [AUDIT_2026-11-22.md](AUDIT_2026-11-22.md). The latest critical self-review is [MAINTAINER_ADVERSARIAL_REVIEW_2026-11-23.md](MAINTAINER_ADVERSARIAL_REVIEW_2026-11-23.md); it documents release-blocking limitations rather than declaring the product production-ready.

## Recovery Inspector (read-only)

Use the **Inspect** button to compare this portable folder's saved recovery journal against a snapshot of Windows NRPT and IPv4 route entries. This operation does not require UAC elevation and does **not** add, remove or repair network rules.

Possible results are `NO_JOURNAL` (this folder has no journal), `MATCHED_SNAPSHOT` (recorded objects appear present, **not** proof of actual site routing), `INCOMPLETE` (pending operations), `MISMATCH` (recorded objects not found), `CONFLICT` (incompatible objects), and `UNKNOWN` (unreadable journal or insufficient observation). The output reports counts rather than including the domain/IP names from the journal.

**Do not erase the journal or copy one portable folder's state into another** just because the inspector reports a mismatch. A previous installation or third-party software may still own overlapping Windows objects. The inspector intentionally never attempts automatic cleanup.

## Configuration health, ownership hints and long operations

**Inspect** now distinguishes a malformed saved exception JSON from a missing journal. A malformed list reports `CONFIG_INVALID`; the original bytes are left untouched and Add/Remove are disabled in the GUI until the file is repaired independently. Do not replace a corrupted file with an empty list without first preserving and inspecting it.

If Windows has owner-tagged NRPT policies not attributable to the journal for this portable folder, Inspect reports `UNATTRIBUTED_POLICIES` when no more urgent journal status is present. This is **not proof** that the policy belongs to another copy: it may be a stale rule. The app does not automatically adopt, remove, or overwrite those policies.

For tasks taking longer than 30 seconds, the GUI explains that an operation is ongoing. Past 120 seconds it recommends read-only inspection after any interruption, without killing Apply/Restore automatically. These notices are advisory: there is no network transaction cancellation guarantee, and a long-running process can still require controlled diagnostics.

## Journal-bound ownership (v8) and legacy recovery

**New Apply creates a version 8 journal.** In addition to the operation UUID and matching owner-tagged NRPT Comment introduced with v7, each committed NRPT record now keeps the Windows Name, exact namespace and expected DNS server set. Preflight, Restore and Inspector compare these fields before treating a policy as managed. If the same named and owner-tagged Windows rule has changed namespace or DNS servers, Restore refuses to remove it and preserves the journal.

Version 8 requires a complete, unique `ruleDetails` record per committed rule. An incomplete or malformed v8 record must not silently degrade to v7 ownership checks. Interrupted Apply operations continue to use their already-written `pendingRules` intents for crash reconciliation.

Older v3–v7 journals remain readable under their original compatibility rules. Existing portable journals are **not automatically converted** into an authenticated record, and their historic Name-only entries cannot prove DNS tuple equality. The application refuses to adopt an unrelated orphan policy based merely on an owner tag.

**An operation UUID and NRPT Comment are not cryptographic credentials.** A writable portable journal can be modified, and IPv4 routes still lack an authenticated creator identity. v8 provides stronger drift detection but does not solve the privileged journal trust boundary.

## Write failures, read-only file boundary and recovery overhead

The JSON writer uses temporary files and Windows same-volume replacement. If replacement fails after a backup is created, it **retains that backup** rather than deleting it without inspection. A locked-destination regression confirms preservation of original bytes. This is not a guarantee against sudden power loss; there is no verified durable flush protocol.

Before elevated Apply or Restore, the Go helper refuses a Portable directory or named saved-list/recovery-journal path that is not an ordinary filesystem object in its current observation. The check is a limited `Lstat` preflight: it does not establish file-handle identity, prove ACL authority, inspect every ancestor junction, or eliminate hardlinks and replacement races. Legitimate symlink-based Portable layouts may now be rejected until manually reviewed.

Full Restore preflight now reads the committed NRPT inventory once rather than querying Windows separately for each completed rule, while per-object queries immediately before mutation remain in place. This reduces avoidable system calls; it is not a promise of overall linear-time execution.

## Cross-folder coordination and recovery journal validation

Apply/Restore now take two locks: a configuration-folder writer lock and a `Local\\SelectiveVPNBypass-NetworkWriter` network-operation lock shared across **portable folders in the same Windows session**. This prevents simultaneous network mutations by two app copies in that session, but it does not block other user sessions or unrelated network software.

Restore now refuses to remove a route when more than one identical candidate is returned for the journaled interface, prefix, gateway and route metric. This is a fail-closed safety check, not proof of ownership when a single identical route may have been created by another app.

Before Restore, the application structurally validates the recovery journal: supported schema version, interface index, IPv4 host prefixes, gateway IPs and pending DNS records. Legacy records without newer optional fields remain readable. Inspect reports `UNKNOWN` for structurally invalid journals; do not manually edit or delete the journal without a verified recovery plan.

**Important:** Structural validation and owner comments are not cryptographic integrity or authorization checks, because state files remain writable by the local user. A stronger privilege-separated trust model and inter-session isolation remain future work.

## Restore preflight and observed postconditions

Before deleting any recorded Windows objects, Restore now performs a **read-only, full-journal preflight**. It checks recorded NRPT identities and pending rule intents, then checks all recorded IPv4 routes for ambiguity and changed interface identity. If this preflight encounters a conflict, **no deletion begins**. Missing objects are treated as already absent from the observed snapshot, not as an instruction to remove a substitute.

During deletion, each candidate is queried again before its corresponding operation. After the deletion attempts, the same reconciliation checks run again; a journal is cleared only when no recorded objects remain observable and no errors occurred. If any error occurs, the journal stays for inspection and a later recovery attempt.

This **does not provide atomicity**: changes can still occur between checks, an operation can fail after earlier deletions, and a crash can leave an incomplete journal. The current implementation intentionally blocks all deletions when an ambiguous candidate is found during the first preflight; an alternative per-item cleanup policy needs separate design and tests. State files remain user-writable, and structural validation does not authenticate their origin.

## Per-item recovery completion and reboot behavior

After an OS object is verified absent during Restore, the recovery journal now records terminal progress in optional `restoreDoneRules`, `restoreDoneIntents` and `restoreDoneRoutes` arrays. Existing v6/v7 journals remain readable. On a later Restore, terminal entries are not treated as a new removal instruction; this reduces the chance of deleting a replacement with the same Windows rule identity. The read-only Inspector reports `RESTORE_PARTIAL` and the recorded completed count while unresolved work remains.

An ActiveStore route may disappear after restart. If the recorded tuple is genuinely absent, Restore may converge without deleting a new route, even if the old adapter index is no longer current. If a recorded route is still present but the adapter has changed, Restore refuses to guess. The route's creator is still not cryptographically provable.

**This is not crash-proof atomicity.** There remains a window after an OS object disappears but before its completed-state write is durable. Moreover, terminal records are stored in user-writable JSON: schema validation checks their shape and membership, not their authenticity. Do not manually alter these records to force cleanup.

For the next trust-boundary milestone, see [Privileged Recovery Journal Trust Boundary — Design Gate](SECURITY_BOUNDARY_PLAN_2026-11-22.md). This document is a **proposal**, not a deployed administrator-protected journal store or migration.

## Read-only privileged journal readiness check

The **Inspect** action now also reports the state of a **future** administrator-controlled recovery journal directory under the Windows CommonApplicationData location (typically `%ProgramData%\\SelectiveVPNBypass`). This is a **non-destructive readiness check**: it does not create the directory, change ACLs, import portable journals, or touch Windows DNS/routing rules.

- `NOT_CONFIGURED`: no future privileged-store directory exists. **Expected for current portable installs**; the app still uses its original portable journal.
- `UNSAFE_PATH` or `REPARSE_POINT`: the expected storage path is not a normal directory or uses redirection. Do not treat it as an elevated authority.
- `BROAD_WRITE_ACE`: a visible ACL rule grants broad write-like rights. This is a **review indicator**, not a complete computation of effective access.
- `ACL_UNVERIFIED` / `UNKNOWN`: the read-only ACL scan either found no obvious broad-write entry or could not complete. Neither status proves a secure journal.

This report remains available when the Windows network inspection cannot complete. No status authenticates the **existing user-editable** portable recovery journal. The separate [privileged journal boundary plan](SECURITY_BOUNDARY_PLAN_2026-11-22.md) remains proposed, not installed or migrated.

## Defensive UX improvements: diagnostics and saved-list backup

The GUI now classifies several common failures with **advisory codes**, including `UAC_CANCELLED`, `LOG_UNAVAILABLE`, `JOURNAL_INVALID`, `OWNERSHIP_CONFLICT`, `NETWORK_UNAVAILABLE`, and `WORKER_FAILED`. The output explains an appropriate next check rather than implying that an interrupted operation was automatically rolled back. Classification is heuristic; inspect actual Windows state before assuming recovery. If a worker ends without writing a result log, the GUI reports `NO_RESULT_LOG` rather than assuming a specific cause. When the user tries to close the window while Apply/Restore is still active, the GUI explains that closing the window does **not** cancel the worker and asks for confirmation; Windows shutdown is not blocked by this prompt.

The **Backup** button creates a user-selected JSON file containing only the **saved desired exceptions** in the format `SelectiveVPNBypass.TargetsBackup.v1`. It deliberately does **not** export the route/NRPT recovery journal, operation owner IDs, DNS policy objects or system routes. It uses exclusive new-file creation to avoid overwriting an existing file. Save the backup somewhere private because it may include sensitive domain names or IPv4 addresses. **Automatic import is not provided** in this release; copying a backup directly over an active configuration or recovery journal is unsafe.

The elevated Go worker now opens only a fresh result log under its process temporary directory, using an exclusive file handle and capturing PowerShell output through the Go process instead of letting elevated PowerShell reopen the log destination. A pre-existing filename is refused. Note that alternate administrator-account UAC elevation can use a different temporary directory and may require an explicit future cross-account logging design. This hardening limits accidental overwrite; it does not fully establish the authenticity of the user-writable journal or eliminate all filesystem redirection races.

## Worker completion integrity and migration-blocker assessment

The GUI now treats **missing or empty worker result logs as unverified failures**, even when the worker process exited with code zero. It preserves the text entered for Add until both a successful process exit and a readable, nonempty result have been observed. Failure notifications advise read-only Inspect rather than assuming rollback completed.

Windows CI runs the GUI interaction test **three times in separate temporary folders** to increase its chance of detecting timing-dependent lifecycle failures. Worker start/finish counters are included in test exceptions to help distinguish a button dispatch issue from a delayed exit or status update. Repeated success does **not** prove that the previously observed intermittent failure is fixed.

Inspect also reports a **read-only privileged-journal migration gate**. Possible labels are `NO_LOCAL_JOURNAL`, `BLOCKED_INVALID_JOURNAL`, `BLOCKED_LEGACY_OWNER`, `BLOCKED_PENDING`, `BLOCKED_RECORDED_OBJECTS`, `EMPTY_JOURNAL_REVIEW`, and `BLOCKED_UNREADABLE`. Even `EMPTY_JOURNAL_REVIEW` is **not permission to migrate**: other Windows objects and Portable folders may still exist. The software does not create the future privileged directory, elevate journal authority, copy legacy files or modify Windows network policies during this classification.

## Redacted support summary and ACL diagnostics

The read-only **Inspect** action now prints a single `Redacted support summary:` JSON line in the format `SVB-DIAG-v1`. It contains fixed status codes and integer counts for journaled DNS policies, IPv4 routes, unresolved objects and completed cleanup work; it includes **no configured domain names, IP addresses, usernames, filesystem paths, raw journal bytes, or owner UUIDs**. Its `VerifiedTraffic` field is always `false`: this is a diagnostic snapshot, not proof of what a browser or another program actually did.

The privileged-store ACL readiness check now tests only the rights relevant to **writing, deleting, or altering permissions**. A read-only `Users` grant should not be classified as a broad-write grant just because composite `FullControl` or `Modify` enumeration values contain read bits. This is still a limited ACL warning heuristic, not effective-access verification, handle-bound path validation, or authentication of the existing portable journal.

For GUI operations, `NO_RESULT_LOG` explains that a separately credentialed administrator may have a different TEMP directory. The reason is a **possibility**, not a confirmed diagnosis; the software does not automatically copy privileged logs into other accounts or treat missing logs as success.

## Verification and development history

The build workflow runs syntax, exception-list, and noninteractive GUI initialization checks before compiling the portable ZIP. These checks do **not** replace actual Windows DPI, button interaction, VPN connection, or route rollback testing.

Run the non-network regression suite on Windows:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\test-core.ps1
```

All changes and their evidence limitations are recorded in [DEVELOPMENT_LEDGER.md](DEVELOPMENT_LEDGER.md). See [CONTRIBUTING.md](CONTRIBUTING.md) for safe, privacy-conscious contributions.

## Build from source

With Go 1.22+ on Windows, run:

```powershell
$env:GOOS='windows'
$env:GOARCH='amd64'
$env:CGO_ENABLED='0'
go build -trimpath -ldflags='-H windowsgui -s -w' -o SelectiveVPNBypass_GUI.exe .
Compress-Archive -Path SelectiveVPNBypass_GUI.exe,README.md,LICENSE -DestinationPath SelectiveVPNBypass_Portable_Windows_x64.zip -Force
```

## Recovery and concurrent use

Apply/Restore and list mutations are serialized per portable configuration folder by a Windows named mutex. Pending IPv4 route intents **and NRPT namespace/DNS intents** are persisted before corresponding OS changes, and Restore checks completed and pending records. For NRPT pending records without a Windows-generated ID, recovery only removes a uniquely matching owner-tagged namespace with the same DNS servers; ambiguous or foreign rules are rejected. State JSON replacement uses same-folder temporary files.

This is an **incremental crash-recovery improvement**, not a claim that every NRPT rule or route can be recovered after an arbitrary crash. A rule created just before an interrupted journal update can now be reconciled when it has a unique exact match; collisions, same-tag foreign instances and externally modified settings remain residual risks. Avoid running separate portable copies against the same Windows network configuration until installation-scoped ownership is implemented and tested.

## Safety and limitations

IPv4 DNS-based routing is **not guaranteed domain isolation**: browser DoH, IPv6, QUIC, DNS changes and shared CDN IPs may affect routing. Unmanaged conflicting routes must not be overwritten. The user's VPN default route and Tailscale configuration are not deliberately modified. Use this utility only on networks you are authorized to administer and keep an independent network recovery method available.

Do not include your real local/public IP addresses, private domains or personal exceptions in GitHub issues, screenshots, source commits or logs.

## Open source contributions

See [CONTRIBUTING.md](CONTRIBUTING.md). Licensed under [MIT](LICENSE). Maintainer changes are committed as **WhoSia**; no GitHub Actions[bot] commits.

## Development record

Every decision, patch, regression, failure and verification is recorded with Korea Standard Time in [DEVELOPMENT_LEDGER.md](DEVELOPMENT_LEDGER.md). Entries distinguish observed Windows outcomes from source-only and CI-only evidence.
