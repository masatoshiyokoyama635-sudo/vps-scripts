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
- `nodes.txt` now supports `http|port|username|password|remark|ipver|ext_ip|ext_port`; `rebuild_config()` generates an Xray HTTP inbound with the legacy-compatible `settings.accounts` field and Basic Auth. Xray v26.5.9+ also accepts and prefers `settings.users`, but `accounts` remains compatible with both older and current versions. HTTP credentials are generated automatically as a random hex username/password pair, remain plaintext in the local node database, and require restrictive permissions.
- VLESS, Shadowsocks, and HTTP node creation and port changes all use `read_port()`: entering a port selects it after availability checks, while pressing Enter accepts the displayed random high-port default.
- The script marks the current HTTP behavior with `Feature: http-basic-auth-manual-port`; `install_shortcut()` uses `SCRIPT_FEATURE` to replace older local shortcut scripts only after downloading a syntax-valid remote script containing that marker. The download uses the explicit `refs/heads/master` path to avoid stale short-ref cache entries. Temporary candidate configs retain a `.json` suffix because Xray infers the config format from the filename extension.
