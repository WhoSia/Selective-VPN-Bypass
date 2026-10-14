# Contributing

Please keep this project small, portable, easy to inspect, and privacy-conscious.

## Setup

- Windows 10/11 x64, Go 1.22+, and Windows PowerShell 5.1.
- The Go entrypoint embeds src/Gui.ps1, src/Core.ps1 and src/Worker.ps1.
- Build: go build -o SelectiveVPNBypass_GUI.exe .

## Proposing changes

1. Open an issue, or submit a focused PR against main.
2. Describe reproduction, expected outcome and actual results.
3. Avoid including local IP addresses, private domain lists, credentials, school network addresses, or identifying network logs.
4. Test empty defaults, add/remove, configuration persistence, apply/restore, rollback, and Windows DPI at 100/125/150/200 percent.
5. Changes must not overwrite routes owned by other software (including Tailscale).
6. Network modifications must be explicit and reversible.

Contributors retain their own git attribution; maintainer-side commits must be attributed to WhoSia, never GitHub Actions[bot].
