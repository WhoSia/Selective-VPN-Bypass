# Selective VPN Bypass

A lightweight **portable Windows companion for SoftEther VPN Client**, developed openly in this repository.

> **Preview / experimental:** Not yet tested end-to-end on Windows with live VPN connections. Network rules can affect connectivity.

## Download

**Windows executable:** Open [Actions](../../actions/workflows/build-windows.yml), select a successful **Build Windows portable** run and download the `SelectiveVPNBypass-Portable-Windows-x64` artifact. Extract it and run `SelectiveVPNBypass_GUI.exe`. GitHub login may be required for Actions artifacts.

**Code → Download ZIP** is the source ZIP. It is not an executable distribution. Tagged GitHub Releases will be published manually by **WhoSia** after testing—not by GitHub Actions bots.

## Features

- Empty default exception list; add and remove domains (including .kr/.wiki) or IPv4 addresses.
- Local-only JSON configuration stored alongside the EXE; **never automatically imports a previous user's settings**.
- Status, Wi-Fi DNS lookup, Apply and Restore actions.
- Uses Windows PowerShell 5.1 built into Windows; no Python/Qt installation needed.
- Windows UAC approval is requested for Apply/Restore; ordinary list editing does not require elevation.
- Build is automated, but the workflow **never creates commits or releases**.

## Architecture

Go executable embeds three PowerShell sources: `src/Gui.ps1` (WinForms UI), `src/Core.ps1` (validation/routing), `src/Worker.ps1` (command worker). This is **not** yet a native Go UI toolkit. A fully modern high-DPI interface is a future improvement; the preview uses DPI-scaled layout and needs real-world display testing.

## Build from source

With Go 1.22+ on Windows, run:

```powershell
$env:GOOS='windows'
$env:GOARCH='amd64'
$env:CGO_ENABLED='0'
go build -trimpath -ldflags='-H windowsgui -s -w' -o SelectiveVPNBypass_GUI.exe .
Compress-Archive -Path SelectiveVPNBypass_GUI.exe,README.md -DestinationPath SelectiveVPNBypass_Portable_Windows_x64.zip -Force
```

## Safety and limitations

IPv4 DNS-based routing is **not guaranteed domain isolation**: browser DoH, IPv6, QUIC, DNS changes and shared CDN IPs may affect routing. Unmanaged conflicting routes must not be overwritten. The user's VPN default route and Tailscale configuration are not deliberately modified. Use this utility only on networks you are authorized to administer and keep an independent network recovery method available.

Do not include your real local/public IP addresses, private domains or personal exceptions in GitHub issues, screenshots, source commits or logs.

## Open source contributions

See [CONTRIBUTING.md](CONTRIBUTING.md). Licensed under [MIT](LICENSE). Maintainer changes are committed as **WhoSia**; no GitHub Actions[bot] commits.
