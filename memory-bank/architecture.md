# Architecture

## Repository purpose

This repository hosts a VPS-side Xray management shell script. The primary entry point is `xray-manager.sh`.

## Files

- `xray-manager.sh` — Bash script for installing/removing Xray, managing VLESS Reality and Shadowsocks nodes, firewall ports, BBR settings, and the `xff` shortcut installer. The shortcut installer downloads from `masatoshiyokoyama635-sudo/vps-scripts`.
- `.gitattributes` — Forces `*.sh` files to keep LF line endings so shell scripts remain safe to run from Linux VPS environments after editing on Windows.
- `memory-bank/architecture.md` — Project structure and architecture notes.
- `memory-bank/progress.md` — Work progress and audit notes.

## Security notes

- The script should not be executed blindly on production VPS hosts. Review changes first and prefer testing on a disposable VPS.
- The script still depends on upstream XTLS GitHub resources for installing/removing Xray and downloading Xray-core. These are expected for this script, but they are supply-chain dependencies.
- Sensitive Xray node data can be written under `/usr/local/etc/xray/`; keep permissions restrictive when running on a VPS.
