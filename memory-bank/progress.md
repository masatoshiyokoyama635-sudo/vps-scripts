# Progress

## 2026-08-16

- Added persistent HTTP Basic Auth inbound support to `xray-manager.sh` while retaining VLESS Reality and Shadowsocks.
- HTTP records use `http|port|username|password|remark|ipver|ext_ip|ext_port`; HTTP ports are generated in the high range and checked against system listeners and existing node records.
- Rebuilds now validate node types/ports, generate `settings.users`, test candidate Xray configuration when the binary is available, and atomically replace the config only after validation. Existing configuration is preserved on malformed records.
- Added HTTP menu/list/export/port-management paths, credential validation, node-data permissions, and a feature marker to prevent `install_shortcut()` from silently installing an older script without HTTP support.
- HTTP credentials are now generated automatically: usernames use a random 16-hex suffix and passwords use 24 random hex bytes (48 characters); no manual credential input is required.
- `bash -n`, `git diff --check`, and Xray 26.3.27 `run -test` against a minimal HTTP configuration passed. Full script rebuild testing is blocked locally because Git Bash does not provide `jq` or Linux `ss`; run the mixed VLESS/SS/HTTP regression on a disposable Linux VPS before deployment.

## 2026-06-25

- Changed the VLESS Reality default SNI in `xray-manager.sh` from `www.microsoft.com` to `www.sony.com` because the Microsoft SNI path recently became unreliable.
- Verified the change with `bash -n xray-manager.sh`, `git diff --check`, targeted string search, and code review.
- Existing nodes are unaffected because persisted SNI values remain stored in `/usr/local/etc/xray/nodes.txt`; only newly created VLESS nodes use the new default when the prompt is left blank.

## 2026-06-21

- Cloned `masatoshiyokoyama635-sudo/vps-scripts` into `E:/vis project/vps_scripts`.
- Fetched the latest `xray-manager.sh` from the old account repository `nolemond-admursa/vps-scripts` for read-only comparison.
- Synchronized `xray-manager.sh` to the old account latest version while replacing hardcoded raw GitHub URLs from `nolemond-admursa/vps-scripts` to `masatoshiyokoyama635-sudo/vps-scripts`.
- Verified no `nolemond-admursa/vps-scripts` references remain in the active script.
- Ran `bash -n xray-manager.sh` and `git diff --check`; both passed.
- Security review found no obvious backdoor patterns in the updated script; remaining concerns are supply-chain hardening items such as mutable upstream URLs and checksum/version pinning.
- Added `.gitattributes` to keep shell scripts as LF line endings.
