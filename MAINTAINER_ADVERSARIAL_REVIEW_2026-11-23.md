# Independent maintainer audit — 2026-11-23

**Scope:** Direct inspection of the current `main` source, existing README/ledger and Windows CI. Deliberately skeptical review of the recent v8 NRPT record, exclusive Go logging, route/NRPT Restore and the operator experience. This is not a certification. This document does not claim tests that were not run.

## Confirmed improvements

- New v8 journals record completed NRPT identity as `name`, `namespace`, `servers`, and the journal's operation-specific owner Comment. Restore rechecks the tuple before removal; legacy v3–v7 cleanup remains backward-compatible.
- Failed `Save-Json` replacement no longer unconditionally deletes a backup file, which could be the only intact former copy after a failed replacement.
- Elevated Go helper refuses a redirected or nonregular top-level Portable data file when observed; the check is explicitly not handle-based authorization.
- Windows preflight queries the NRPT inventory once for multiple committed rules, but still reads the object immediately before deletion.

## Challenge to the roadmap: problems sorted by *risk reduction*, not by feature appeal

| ID | Severity | Status | Issue | Evidence or proof boundary | Recommended next move |
|---|---|---|---|---|---|
| A-01 | **P0 release blocker** | CONFIRMED design gap | Elevated Restore obtains deletion authority from user-writable JSON under the executable directory. v8 UUID and extended metadata are also editable. | `src/Core.ps1` `State`, `Assert-RecoveryJournal`, `Get-RestorePreflight`, `Restore-Own`; `SECURITY_BOUNDARY_PLAN_2026-11-22.md` | Implement a separate, ACL-protected authority store in an isolated VM only after proving a non-destructive legacy migration and robust path semantics. |
| A-02 | **P1** | CONFIRMED limitation | Preflight + postcondition do not make a multi-object Restore atomic; a crash or external mutation between observation and removal can leave a partial state. | `src/Core.ps1` `Restore-Own`; `restoreDone*` fields | Crash-stop fault injection at every NRPT/route removal and journal write. Keep unresolved entries; do not claim rollback. |
| A-03 | **P1** | CONFIRMED limitation | Identical IPv4 route tuples are not unforgeable creator identities. Even one exact match might originate elsewhere. | `Test-ManagedRouteMatch`, `Get-RestorePreflight` | Document confidence precisely; avoid automatic adoption of route objects without provenance. |
| A-04 | **P1** | CONFIRMED interoperability risk | A separate administrator account used for UAC may have a different TEMP from the caller. The elevated helper rejects result logs outside its own TEMP and the GUI may receive no diagnostics. | `embedded_worker.go` `validateWorkerArguments`, `src/Gui.ps1` `Run-Action` | Design a restricted cross-account result transport without making caller-writable paths privileged output targets; test actual different-account UAC in a disposable VM. |
| A-05 | **P1** | OBSERVED, cause not established | GUI interaction CI occasionally fails with stale `Running apply ...` despite prior successful runs. Treat as intermittent test or UI-state risk, not as a harmless runner flake. | Windows Actions build `45053698102` GUI step FAILED; earlier passing runs | Instrument process lifetime, exit status and timer transitions; reproduce deterministically before adding cosmetic features. |
| A-06 | **P1** | CONFIRMED partial mitigation | Elevated Go reparse detection examines the config directory and named data files with `Lstat`, not every ancestor or handle-bound final target. Hardlink/TOCTOU cases remain. | `embedded_worker.go` `validatePortableFileBoundary` | Formal Windows path/file ID and ACL checks before elevating trust claims. Test junction, symlink, hardlink, replace races. |
| A-07 | **P2** | CONFIRMED limitation | `Local\\` mutex serializes processes in one Windows session, not independent Windows user sessions. | `src/Core.ps1` `Enter-ConfigLock`, `Enter-NetworkLock` | Design cross-session coordination tied to privileged journal authority; avoid unreviewed global mutex ACL. |
| A-08 | **P2** | CONFIRMED limitation | `Save-Json` uses filesystem Replace/Move but no verified write-through/flush semantics; power-loss durability is not demonstrated. | `src/Core.ps1` `Save-Json`, JSON locked-destination test | Add power-loss tests using disposable VM and distinguish atomic namespace replacement from durable data. |
| A-09 | **P2** | CONFIRMED compatibility choice | v3–v7 journals remain less specific than v8; they cannot prove completed NRPT DNS tuple integrity with the old Name-only records. | Legacy branches of `Test-CommittedNrptIdentity` | Keep explicit warning about weaker provenance; no automatic promotion of legacy state. |
| A-10 | **P2** | CONFIRMED UX limitation | Current system-state inspection is not proof of application traffic path, DNS over HTTPS, IPv6 or CDN egress. | `Inspect-JournalSnapshot`, README | Keep claims narrow; add operator-oriented status explanations rather than a misleading 'bypassed successfully' badge. |

## Adversarial assessment of recent code changes

1. **v8 record metadata strengthens consistency but is not identity authentication.** A process that can modify the recovery journal can alter those fields. The improvement is therefore defensive against accidental drift, not sufficient for the P0 trust boundary.
2. **More validation can block recovery.** A v8 object modified by another program is deliberately left intact; users must be told why and how to diagnose without deleting external policies.
3. **The stricter elevated file check can reject legitimate Portable folders stored through reparse-enabled environments.** This is a safe refusal but creates a new support case. Do not silently repair it by disabling the check.
4. **Failure-preserved backups require discoverability and privacy handling.** A uniquely named `.bak` may remain after a failed replace; support instructions must avoid deleting it automatically or uploading it to public issue threads.
5. **The 'single NRPT snapshot' optimization is bounded.** Pending rules still use namespace-based inspection, and revalidation during deletion remains intentionally per object. Do not advertise linear-time overall Restore.
6. **The GUI's status can still be mistaken for real routing verification.** A green CI build is evidence of specified tests passing, not evidence of correctly routed traffic on users' own machines.

## Recommended sequence, with acceptance gates

1. **P0: privileged-store trust design and non-destructive VM prototype.** Prove a normal user cannot alter privileged deletion authority; demonstrate safe refusal on junction, hardlink, symlink, stolen/corrupt/migrated legacy states, and UAC different-account. No production migration before this gate.
2. **P1: reproducible crash recovery and GUI lifecycle tests.** Force termination between OS mutation and journal completion, inspect post-crash state, test user closing window and a separately credentialed UAC worker. Quantify unresolved objects and user interventions.
3. **P1: legacy migration acceptance.** Clear distinction between desired target configuration and elevated recovery records. Never import legacy JSON into authority storage silently. If migration cannot prove ownership, leave state in quarantine and show next steps.
4. **P2: redacted diagnostic bundle and backup import preview.** Implement only after preserving the privacy boundary and ensuring that an import cannot modify elevated cleanup authority.
5. **P3: expanded appearance, adapter autodiscovery, bulk workflows.** Defer. They can multiply network-state and user-confusion cases before the trust and recovery model is stable.

## Production verdict

**Not ready for unrestricted/general distribution.** Existing Windows regression and isolated-runner tests support narrow recovery properties. They do not cover the full UAC/ACL boundary, all concurrent Windows sessions, crash/power-loss windows, the complete Restore transaction, or application-level traffic verification. A tagged NRPT comment and valid schema are not credentials. Prioritizing more bypass targets or additional route modes before these gaps are addressed would increase the attack surface without addressing core user risk.

**Review status:** maintainer self-challenge; do not treat it as an external Claude/Gemini audit. Independent review and disposable-VM acceptance remain necessary.
