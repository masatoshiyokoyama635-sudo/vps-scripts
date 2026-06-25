# Progress

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
