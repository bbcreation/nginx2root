# nginx2root

Upgrades nginx on Ubuntu servers that use the official nginx.org packages to the releases that fix the 2026-11-18 security advisories ([nginx.org](https://nginx.org/en/security_advisories.html)):

- stable: **1.30.7** or newer
- mainline: **1.31.9** or newer

Fixed CVEs: CVE-2026-123634, CVE-2026-123007, CVE-2026-121810, CVE-2026-123633, CVE-2026-118899, CVE-2026-113425, CVE-2026-120993, CVE-2026-125283, CVE-2026-120967, CVE-2026-123640.

## Requirements

- Ubuntu 22.04 (jammy), 24.04 (noble) or 26.04 (resolute)
- nginx installed from nginx.org packages (not the Ubuntu `nginx` package)
- root access

## Usage

Paste into the server console as root:

```bash
curl -fsSL https://raw.githubusercontent.com/bbcreation/nginx2root/main/nginx2root-fix.sh -o /tmp/nginx2root-fix.sh && bash /tmp/nginx2root-fix.sh
```

Or as a regular user with sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/bbcreation/nginx2root/main/nginx2root-fix.sh -o /tmp/nginx2root-fix.sh && sudo bash /tmp/nginx2root-fix.sh
```

On success the last line is:

```
UPDATED AND SECURE: nginx 1.30.7-1~noble (stable), configuration valid, service running after restart.
```

On any problem the script stops and prints a line starting with `NOT PATCHED:` with the reason. Nothing is upgraded in that case.

## What it does

1. Checks the OS, the installed nginx package and the nginx.org channel (stable or mainline).
2. Runs `nginx -t` and backs up `/etc/nginx` to `/root/nginx-config-before-<timestamp>.tar.gz`.
3. Installs the current nginx.org signing key after verifying its fingerprint.
4. Disables old nginx.org entries in `/etc/apt/sources.list` and `/etc/apt/sources.list.d/*.list` (backup: `*.bak-<timestamp>`) and writes `/etc/apt/sources.list.d/nginx.list`.
5. Runs `apt-get update`, then a dry run of the upgrade. Stops if APT wants to remove any package.
6. Upgrades `nginx` and any installed `nginx-module-*` packages, runs `nginx -t`, restarts nginx and checks the running version.

## Notes

- nginx is restarted, so expect a short interruption.
- Repositories in deb822 format (`*.sources`) are not changed; the script stops and asks for manual review.
- It is safe to run the script again on an already patched server.

## Check the version

```bash
nginx -v
```
