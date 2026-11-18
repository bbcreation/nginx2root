# nginx2root

Upgrades nginx on Ubuntu servers to the official nginx.org releases that fix the 2026-11-18 security advisories ([nginx.org](https://nginx.org/en/security_advisories.html)):

- stable: **1.30.7** or newer
- mainline: **1.31.9** or newer

Fixed CVEs: CVE-2026-123634, CVE-2026-123007, CVE-2026-121810, CVE-2026-123633, CVE-2026-118899, CVE-2026-113425, CVE-2026-120993, CVE-2026-125283, CVE-2026-120967, CVE-2026-123640.

The HTTP/2 issue allows unauthenticated remote code execution and is enabled on most HTTPS sites. Patch every server.

## Requirements

- Ubuntu 22.04 (jammy), 24.04 (noble) or 26.04 (resolute). Ubuntu 20.04 and older cannot be patched: nginx.org no longer builds packages for them.
- nginx installed from nginx.org packages, or from Ubuntu packages (see [Migration from Ubuntu nginx](#migration-from-ubuntu-nginx))
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

## Migration from Ubuntu nginx

If nginx comes from Ubuntu packages (for example `1.24.0-2ubuntu7.19`) or from the removed `ondrej/nginx` PPA (older Laravel Forge servers), the fix is not available there. The script then offers to replace it with nginx.org stable, or mainline on Laravel Forge servers (the channel Forge itself uses):

```
nginx 1.24.0-2ubuntu7.19 is not an nginx.org package (Ubuntu or PPA). It will be replaced with nginx.org stable 1.30.7 or newer.
Configuration in /etc/nginx is kept. nginx.org modules: nginx-module-geoip.
Type yes to migrate:
```

Type `yes` to continue. To migrate many servers without the question, add `--yes`:

```bash
curl -fsSL https://raw.githubusercontent.com/bbcreation/nginx2root/main/nginx2root-fix.sh -o /tmp/nginx2root-fix.sh && bash /tmp/nginx2root-fix.sh --yes
```

On success the last line is:

```
MIGRATED AND SECURE: nginx 1.24.0-2ubuntu7.19 (Ubuntu or PPA) replaced with nginx.org 1.30.7-1~noble (stable), configuration valid, service running after restart.
```

During migration:

- `/etc/nginx` stays as it was (`sites-enabled`, `snippets`, `user www-data`, certbot changes).
- Ubuntu modules are replaced with nginx.org packages: geoip, image-filter, xslt, perl, njs. `stream` and `mail` are built into nginx.org nginx. `geoip2`, `brotli` and `ssl-ct` have no nginx.org package: they are dropped when the configuration does not use them; otherwise the script stops and shows the directives to remove.
- The script stops before any change if a module has no nginx.org package (for example `headers-more`) or a `load_module` line is outside `/etc/nginx/modules-enabled`.
- If nginx fails after the package swap, the script restores the previous packages and `/etc/nginx` and prints `ROLLED BACK:`. For the removed `ondrej/nginx` PPA the old packages cannot be downloaded, so the rollback installs the Ubuntu nginx package instead.
- The `ondrej/nginx` PPA source is disabled (backup: `*.bak-<timestamp>`).
- `/etc/apt/preferences.d/99nginx` is added so APT keeps nginx from nginx.org.
- Later nginx updates come from nginx.org, not from Ubuntu `unattended-upgrades`. Run this script again for future advisories.

## What it does

1. Checks the OS, the installed nginx package and the nginx.org channel (stable or mainline).
2. For Ubuntu nginx, checks the loaded modules and asks for confirmation.
3. Runs `nginx -t` and backs up `/etc/nginx` to `/root/nginx-config-before-<timestamp>.tar.gz`.
4. Installs the current nginx.org signing key after verifying its fingerprint.
5. Disables old nginx.org entries in `/etc/apt/sources.list` and `/etc/apt/sources.list.d/*.list` (backup: `*.bak-<timestamp>`) and writes `/etc/apt/sources.list.d/nginx.list`.
6. Runs `apt-get update`, then a dry run of the upgrade. Stops if APT wants to remove any package other than the replaced Ubuntu nginx packages.
7. Upgrades `nginx` and any installed `nginx-module-*` packages, runs `nginx -t`, restarts nginx and checks the running version.

## Notes

- nginx is restarted, so expect a short interruption.
- Errors in other APT repositories (for example a third-party repository with an expired key) are ignored; errors in the nginx.org repository stop the script.
- Repositories in deb822 format (`*.sources`) are not changed; the script stops and asks for manual review.
- It is safe to run the script again on an already patched server.

## Check the version

```bash
nginx -v
```
