# Selective VPN Bypass

A lightweight **portable Windows companion for SoftEther VPN Client**, developed openly in this repository.

> **Preview / experimental:** Not yet tested end-to-end on Windows with live VPN connections. Network rules can affect connectivity.

## Download

**Windows executable:** Open [Actions](../../actions/workflows/build-windows.yml), select a successful **Build Windows portable** run and download the `SelectiveVPNBypass-Portable-Windows-x64` artifact. Extract it and run `SelectiveVPNBypass_GUI.exe`. GitHub login may be required for Actions artifacts.

**Code → Download ZIP** is the source ZIP. It is not an executable distribution. Tagged GitHub Releases will be published manually by **WhoSia** after testing—not by GitHub Actions bots.

**Latest verified CI package (2026-11-22 KST):** [Windows portable: NRPT journal-bound ownership protection](https://github.com/WhoSia/Selective-VPN-Bypass/actions/runs/44933145046) · artifact `SelectiveVPNBypass-Portable-Windows-x64` · inside ZIP SHA-256 `be94111153e46774b484ef1e080d5d0d95c223ff4c6fed3e82926069ca5d653f`. PowerShell tests, per-operation ownership collision tests, GUI regression, Windows x64 build and ZIP upload PASS. [Isolated Windows v6/v7 NRPT recovery integration](https://github.com/WhoSia/Selective-VPN-Bypass/actions/runs/44933145024) PASS. Not a security certification or live VPN guarantee.

## Features

- Empty default exception list; add and remove domains (including .kr/.wiki) or IPv4 addresses.
- Local-only JSON configuration stored alongside the EXE; **never automatically imports a previous user's settings**.
- Status, Wi-Fi DNS lookup, Apply and Restore actions.
- Uses Windows PowerShell 5.1 built into Windows; no Python/Qt installation needed.
- Windows UAC approval is requested for Apply/Restore; ordinary list editing does not require elevation.
- Build is automated, but the workflow **never creates commits or releases**.

## Architecture

The Go executable now invokes its embedded Core PowerShell source **from memory for elevated Apply/Restore**, without loading a writable runtime-v4 script for privileged work. Read-only/list editing still uses the normal PowerShell worker. The privileged helper allows only Apply/Restore and validates the portable configuration folder and worker log name. The executable is not code-signed, so this is a trust-boundary hardening step, not verified resistance to executable replacement or every local attack.\n\nGo executable embeds three PowerShell sources: `src/Gui.ps1` (WinForms UI), `src/Core.ps1` (validation/routing), `src/Worker.ps1` (command worker). This is **not** yet a native Go UI toolkit. A fully modern high-DPI interface is a future improvement; the preview uses DPI-scaled layout and needs real-world display testing.

## Status display and recovery expectations

The interface distinguishes the **saved exception list** from the **Windows operation journal**. `Journal: present (unverified)` means a recovery state file exists, **not** that Windows routing or DNS rules are verified active. `Journal: absent` means there is no saved recovery state for that portable folder; it does not prove that OS policies from an older folder or an interrupted operation are absent.

Use Add to save an entry; it does not immediately activate the entry. If Add fails, the typed entry is preserved to reduce repeated work. Apply/Restore require administrator approval; choosing not to approve is not itself evidence of a system fault.

Before moving or replacing portable folders, inspect any outstanding journal and avoid deleting the recovery state without knowing whether network objects remain. Do not share unredacted diagnostics that contain local addresses, network configuration or usernames.

For an independent engineering review covering user burden, failure states, security assumptions and verification gaps, see [AUDIT_2026-11-22.md](AUDIT_2026-11-22.md).

## Recovery Inspector (read-only)

Use the **Inspect** button to compare this portable folder's saved recovery journal against a snapshot of Windows NRPT and IPv4 route entries. This operation does not require UAC elevation and does **not** add, remove or repair network rules.

Possible results are `NO_JOURNAL` (this folder has no journal), `MATCHED_SNAPSHOT` (recorded objects appear present, **not** proof of actual site routing), `INCOMPLETE` (pending operations), `MISMATCH` (recorded objects not found), `CONFLICT` (incompatible objects), and `UNKNOWN` (unreadable journal or insufficient observation). The output reports counts rather than including the domain/IP names from the journal.

**Do not erase the journal or copy one portable folder's state into another** just because the inspector reports a mismatch. A previous installation or third-party software may still own overlapping Windows objects. The inspector intentionally never attempts automatic cleanup.

## Configuration health, ownership hints and long operations

**Inspect** now distinguishes a malformed saved exception JSON from a missing journal. A malformed list reports `CONFIG_INVALID`; the original bytes are left untouched and Add/Remove are disabled in the GUI until the file is repaired independently. Do not replace a corrupted file with an empty list without first preserving and inspecting it.

If Windows has owner-tagged NRPT policies not attributable to the journal for this portable folder, Inspect reports `UNATTRIBUTED_POLICIES` when no more urgent journal status is present. This is **not proof** that the policy belongs to another copy: it may be a stale rule. The app does not automatically adopt, remove, or overwrite those policies.

For tasks taking longer than 30 seconds, the GUI explains that an operation is ongoing. Past 120 seconds it recommends read-only inspection after any interruption, without killing Apply/Restore automatically. These notices are advisory: there is no network transaction cancellation guarantee, and a long-running process can still require controlled diagnostics.

## Journal-bound ownership (v7) and legacy recovery

New `Apply` operations create a **version 7 journal** with a random operation identifier saved before Windows policy changes. The new NRPT rules use `Selective-VPN-Bypass-owned:<operation-UUID>` in their Comment field. Restore and Inspect require the exact identifier for these rules. A missing or invalid identifier in a v7 journal is an error, **not** a reason to fall back to legacy ownership.

Older v6 (and earlier) journals continue to use the legacy Comment for Restore; their identity is less specific. Newly launched Apply operations **never automatically adopt a policy merely because it has the old owner tag**, even when DNS servers and namespace match. If an old orphaned policy remains, use Inspect and review it carefully before making system changes. The app does not delete foreign policies as part of this migration.

An operation UUID is an **accidental-collision discriminator, not a cryptographic identity**. Other applications with administrator access can imitate this Comment, and an IPv4 route is not tagged with the NRPT owner identity. Different portable folders remain independent and may still conflict over routes. This release strengthens NRPT recovery boundaries but does not promise multi-instance isolation for all Windows network objects.

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
