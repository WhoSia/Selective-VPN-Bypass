# Selective VPN Bypass

Portable Windows x64 companion for SoftEther VPN Client. **The default exception list is empty**: no personal network IPs or domain preferences are shipped.

## Download

- **Releases:** download `SelectiveVPNBypass_Portable_Windows_x64.zip` for tagged versions.
- **Actions → Build Windows portable:** after a successful run, download the portable ZIP from Artifacts (sign-in required).
- **Code → Download ZIP** downloads repository **source code**, not the built EXE.

Extract the portable ZIP and double-click `SelectiveVPNBypass_GUI.exe`. Python and Qt are not required. The executable is unsigned.

## Features

- Maintain domain or IPv4 exception lists.
- Apply and restore Wi-Fi-directed IPv4 routes alongside SoftEther VPN.
- Query Wi-Fi DNS and inspect connection status.
- Tag managed Windows NRPT entries for cleanup.
- Do not alter SoftEther's default VPN route or Tailscale; refuse unmanaged /32 route conflicts.

## Build

Go 1.22 or later on Windows:

```powershell
$env:GOOS='windows'; $env:GOARCH='amd64'; $env:CGO_ENABLED='0'
go build -trimpath -ldflags='-H windowsgui -s -w' -o SelectiveVPNBypass_GUI.exe .
Compress-Archive -Path SelectiveVPNBypass_GUI.exe, README.md -DestinationPath SelectiveVPNBypass_Portable_Windows_x64.zip -Force
```

The GitHub Actions workflow builds on pushes to main; `v*` tags publish a GitHub Release ZIP.

## Limitations and safety

**Preview build:** Windows GUI and route behavior require device testing. DNS snapshots, browser DoH, IPv6, QUIC, and shared CDN IPs can undermine strict domain isolation. Use only on networks you are authorized to configure.

Do **not** commit local `Selective-VPN-Bypass.domains.json`, `*.state.json`, logs, or private IPs. Config starts empty and remains local.
