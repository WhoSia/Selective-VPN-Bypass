# Privileged Recovery Journal Trust Boundary — Design Gate
**2026-11-22 · proposal only · not implemented · review before architecture change**

## Motivation and current observed behavior

The Windows portable application keeps the desired exception list and the recovery journal adjacent to the executable, commonly a directory writable by the logged-in user. The elevated, embedded Go/PowerShell worker accepts this journal as the source for deleting Windows DNS Client NRPT rules and IPv4 host routes. Journal schema checks and exact tuple/Comment matching reduce accidental mistakes but do **not** establish that a local user process did not fabricate, replay, or downgrade the journal.

Current v7 NRPT operation UUID is an accidental-collision discriminator, not a secret authentication mechanism. IPv4 `Get-NetRoute` results do not provide the app with an unforgeable creator identity. New `restoreDoneRules`, `restoreDoneIntents`, and `restoreDoneRoutes` fields provide retry bookkeeping, but because they are in the same user-writable journal they also must not be interpreted as cryptographically authenticated facts.

## Proposed authority partition

- **User-writable portable directory:** application EXE, `domains.json`, and a *display-only* status/cache file (if needed). Treat all user-provided text and paths as untrusted, even when syntax is valid.
- **Privileged journal store:** fixed per-machine location below `%ProgramData%\SelectiveVPNBypass\` created and owned by Administrators/SYSTEM, with ACLs explicitly audited. A fixed application-specific path is preferred to a caller-supplied path. Reject reparse points/junctions and untrusted directory redirection; use fixed-name and object identity checks.
- **Privileged worker boundary:** only narrowly defined Apply/Restore operations; read journal through the privileged store. The worker must not accept caller-supplied arbitrary `path`, `ruleName`, `route`, `backup` or `log destination` as deletion authority. A user-writable desired list can influence an *Apply plan* only after separate validation and conflict checks.
- **Ownership model:** install-scoped GUID plus operation-scoped UUID, journaled *before* Windows mutation. These IDs reduce accidental collisions but should be paired with privilege-separated storage, not presented as secrets.
- **Inspection:** the ordinary GUI may request a redacted, read-only status from a constrained helper. Exposing the privileged journal raw could leak network entries; prefer status codes and counts.
- **Durability:** write-ahead intents and completed-state transitions must be committed before depending on them. Use replace/flush discipline, durable backup retention strategy and verified read-back after writes. Claim no full power-loss guarantee until crash/power-off tests.
- **Security perimeter:** this design defends against accidental same-user modifications and limited non-elevated local tampering; it does *not* secure the OS against a hostile administrator or a compromised signed executable.

## Legacy journal migration rules

1. Never silently treat an existing v3–v7 portable JSON as authoritative data in the new privileged store.
2. Inventory legacy state read-only; snapshot OS objects and classify owned/foreign/ambiguous/missing with explicit provenance confidence.
3. If a legacy journal still describes live objects, use a **separate, human-confirmed legacy recovery mode** under strict safeguards; do not automatically import those objects or widen deletion permissions.
4. Only after confirming legacy objects are cleared should a *new* privileged journal be initialized; preserve the original legacy bytes as read-only evidence until the user explicitly completes migration.
5. If prior journal is missing or corrupted, offer diagnostics without guessing ownership. Never invent a replacement UUID or downgrade an identity-bearing v7 journal to v6.
6. A failed migration leaves the privileged store and portable folder independently inspectable; no deletion of the legacy file just because a new version started.

## Acceptance tests before implementing

| ID | Test | Required result |
|---|---|---|
| B-01 | Non-admin modifies old portable journal | Cannot change privileged cleanup authority |
| B-02 | Non-admin supplies custom directory, junction, symlink, or hardlink to elevated worker | Elevated worker refuses unintended privileged writes |
| B-03 | Old v6/v7 JSON copied to another portable folder | No silent ownership adoption or cross-folder cleanup |
| B-04 | Forged schema downgrade v7→v6 | No authorization bypass or weaker cleanup |
| B-05 | Operator cancels UAC | No unverified success status; portable desired list preserved |
| B-06 | Privileged journal write fails before OS mutation | No OS change |
| B-07 | Power interruption after OS mutation | Inspection/retry converges in disposable Windows VM or clearly retains unresolved entries |
| B-08 | Separate Windows user sessions concurrently request Apply/Restore | Correct serialization or explicit denial without deadlock |
| B-09 | New signed build starts from old install | User-visible and non-destructive migration |
| B-10 | Privileged journal bytes corrupted or truncated | No destructive cleanup; report remains actionable |

## Sequencing recommendation

First, complete per-item recovery progress (including old journal compatibility, reboot absence and retry safety) and ensure Windows CI consistently passes. Then add a *read-only prototype* of privileged-store health inspection in a disposable VM. Only after the ACL/security boundary and migration tests are independently reviewed should elevated Apply/Restore be switched to the new store.

**Status:** Proposal. No privileged directory, service, ACL, registry modification, or migration executed by this document. Do not label the current release as having an authenticated recovery journal.
