# Selective VPN Bypass

A small portable Windows companion for SoftEther VPN. Maintain a list of hostname / IPv4 exceptions, check status, and apply or restore selected direct Wi-Fi routes.

**Current stage:** v1.2 preview. Windows x64 executable and source bundle are being prepared; Windows GUI and route application require real-device testing.

## Features

- Minimal GUI: exceptions, Add / Remove, Apply / Restore, Status, DNS lookup.
- Go-based Windows executable with bundled Windows PowerShell + WinForms scripts (not PyQt).
- Apply / Restore ask for elevation; list editing does not.
- No installer; ZIP distribution.

## Limitations

IPv4 snapshot routing is not complete per-domain split tunneling. DNS/NRPT, DoH, IPv6, HTTP/3 and shared CDN IPs may produce other outcomes. Keep existing VPN default routes and Tailscale configurations untouched; unmanaged route conflicts must not be deleted automatically. Use only on networks you are authorized to configure.

## Roadmap

1. Domain/IP exception manager + portable Windows desktop build.
2. Windows field validation and clearer connectivity checks.
3. (Later) Optional VPN Gate server latency comparison.

Do not treat a successful `Apply` operation as proof that the destination was reached via the intended public IP.
