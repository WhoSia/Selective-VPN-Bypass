# Selective VPN Bypass

A lightweight **portable Windows companion for SoftEther VPN Client**, developed openly in this repository.

> **Preview / experimental:** Not yet tested end-to-end on Windows with live VPN connections. Network rules can affect connectivity.

## Download

**Windows executable:** Open [Actions](../../actions/workflows/build-windows.yml), select a successful **Build Windows portable** run and download the `SelectiveVPNBypass-Portable-Windows-x64` artifact. Extract it and run `SelectiveVPNBypass_GUI.exe`. GitHub login may be required for Actions artifacts.

**Code → Download ZIP** is the source ZIP. It is not an executable distribution. Tagged GitHub Releases will be published manually by **WhoSia** after testing—not by GitHub Actions bots.

**Latest verified CI package (2026-11-09 KST):** [Windows Portable: NRPT crash journal + embedded privileged helper](https://github.com/WhoSia/Selective-VPN-Bypass/actions/runs/42571566855) · artifact `SelectiveVPNBypass-Portable-Windows-x64` · package SHA-256 `38e854bfd6485147543ea87aa28985f730f8de3d7cba0ae8ef4823199430ad36`. Regression, simulated restore, embedded worker tests, Windows x64 compile and ZIP upload PASS. [Isolated live Windows crash-recovery test](https://github.com/WhoSia/Selective-VPN-Bypass/actions/runs/42571566919) also PASS with reserved test objects. Real SoftEther/UAC approval and arbitrary forced termination on a user's network remain unverified.

## Features

- Empty default exception list; add and remove domains (including .kr/.wiki) or IPv4 addresses.
- Local-only JSON configuration stored alongside the EXE; **never automatically imports a previous user's settings**.
- Status, Wi-Fi DNS lookup, Apply and Restore actions.
- Uses Windows PowerShell 5.1 built into Windows; no Python/Qt installation needed.
- Windows UAC approval is requested for Apply/Restore; ordinary list editing does not require elevation.
- Build is automated, but the workflow **never creates commits or releases**.

## Architecture

The Go executable now invokes its embedded Core PowerShell source **from memory for elevated Apply/Restore**, without loading a writable runtime-v4 script for privileged work. Read-only/list editing still uses the normal PowerShell worker. The privileged helper allows only Apply/Restore and validates the portable configuration folder and worker log name. The executable is not code-signed, so this is a trust-boundary hardening step, not verified resistance to executable replacement or every local attack.\n\nGo executable embeds three PowerShell sources: `src/Gui.ps1` (WinForms UI), `src/Core.ps1` (validation/routing), `src/Worker.ps1` (command worker). This is **not** yet a native Go UI toolkit. A fully modern high-DPI interface is a future improvement; the preview uses DPI-scaled layout and needs real-world display testing.

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
