#!/usr/bin/env bash
# NGINX security update - Ubuntu + official nginx.org packages
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

fail() {
    echo "NOT PATCHED: $*"
    exit 1
}
trap 'fail "error on line $LINENO: ${BASH_COMMAND}"' ERR

[[ $EUID -eq 0 ]] || fail "run this script as root"

for c in apt-get apt-cache dpkg-query dpkg gpg curl awk grep sed systemctl nginx; do
    command -v "$c" >/dev/null || fail "missing command: $c"
done

[[ -r /etc/os-release ]] || fail "missing /etc/os-release"
. /etc/os-release
[[ ${ID:-} == ubuntu ]] || fail "system is not Ubuntu"
CODENAME=${VERSION_CODENAME:-}
case "$CODENAME" in
    jammy|noble|resolute) ;;
    *) fail "Ubuntu $CODENAME is not handled automatically; manual verification required" ;;
esac

dpkg-query -W -f='${db:Status-Status}' nginx 2>/dev/null | grep -qx installed ||
    fail "nginx package is not installed"

PKGVER=$(dpkg-query -W -f='${Version}' nginx)
PKGINFO=$(dpkg-query -W -f='${Maintainer} ${Homepage}' nginx)
[[ "$PKGINFO" == *nginx.org* || "$PKGINFO" == *NGINX* || "$PKGINFO" == *F5* ]] ||
    fail "nginx package does not look like an official nginx.org/F5 package: $PKGINFO"

# Detect the channel from the active repository or a preserved .distUpgrade file.
CHANNEL=""
while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    if grep -qE 'nginx\.org/packages/(mainline|ubuntu)' "$f"; then
        if grep -q 'nginx.org/packages/mainline/ubuntu' "$f"; then
            [[ -z "$CHANNEL" || "$CHANNEL" == mainline ]] ||
                fail "conflicting nginx.org channels"
            CHANNEL=mainline
        elif grep -q 'nginx.org/packages/ubuntu' "$f"; then
            [[ -z "$CHANNEL" || "$CHANNEL" == stable ]] ||
                fail "conflicting nginx.org channels"
            CHANNEL=stable
        fi
    fi
done < <(echo /etc/apt/sources.list; find /etc/apt/sources.list.d -maxdepth 1 -type f \
    \( -name '*.list' -o -name '*.distUpgrade' \) 2>/dev/null)

# If the source is gone, detect the channel from the installed version.
if [[ -z "$CHANNEL" ]]; then
    case "$PKGVER" in
        1.31.*) CHANNEL=mainline ;;
        1.30.*) CHANNEL=stable ;;
        *) fail "cannot determine nginx.org channel from version $PKGVER" ;;
    esac
fi

case "$CHANNEL" in
    mainline) TARGET=1.31.9; REPOPATH=mainline/ubuntu ;;
    stable)   TARGET=1.30.7; REPOPATH=ubuntu ;;
    *) fail "unknown channel: $CHANNEL" ;;
esac

# The configuration must be valid before anything is changed.
nginx -t >/dev/null 2>&1 || fail "nginx -t fails before the upgrade"

# Back up the configuration before changing the package.
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="/root/nginx-config-before-$STAMP.tar.gz"
tar -czf "$BACKUP" -C / etc/nginx ||
    fail "failed to back up /etc/nginx"

KEY=/usr/share/keyrings/nginx-archive-keyring.gpg
FPR=8540A6F18833A80E9C1653A42FD21310B49F6B46
mkdir -p /usr/share/keyrings

# Install the key only after verifying its full fingerprint.
if [[ ! -s "$KEY" ]] ||
   ! gpg --show-keys --with-colons "$KEY" 2>/dev/null |
       grep -q "fpr:::::::::$FPR:"; then
    TMP=$(mktemp)
    curl -fsSL https://nginx.org/keys/nginx_signing.key -o "$TMP" ||
        fail "cannot download the nginx.org signing key"
    gpg --show-keys --with-colons "$TMP" 2>/dev/null |
        grep -q "fpr:::::::::$FPR:" ||
        fail "invalid nginx.org signing key fingerprint"
    gpg --batch --yes --dearmor -o "$KEY" "$TMP" ||
        fail "cannot create the keyring"
    rm -f "$TMP"
fi

# deb822 nginx.org sources are not handled automatically, to avoid
# leaving a second, conflicting package source.
if grep -RIl 'nginx\.org/packages' /etc/apt/sources.list.d \
    --include='*.sources' 2>/dev/null | grep -q .; then
    fail "found an nginx.org repository in .sources format; manual review required"
fi

# Back up and disable old nginx.org entries in .list files.
while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    grep -q 'nginx.org/packages' "$f" || continue
    cp -a "$f" "$f.bak-$STAMP"
    sed -i '/nginx\.org\/packages/s/^[[:space:]]*\(deb\|deb-src\)[[:space:]]/# disabled-by-nginx-security-script \1 /' "$f"
done < <(echo /etc/apt/sources.list; find /etc/apt/sources.list.d -maxdepth 1 -type f -name '*.list' 2>/dev/null)

# Restore the official repository for the current Ubuntu release and detected channel.
printf 'deb [signed-by=%s] https://nginx.org/packages/%s %s nginx\n' \
    "$KEY" "$REPOPATH" "$CODENAME" > /etc/apt/sources.list.d/nginx.list

# Refresh package indexes. Do not ignore APT errors.
APTLOG=$(mktemp)
if ! apt-get update >"$APTLOG" 2>&1; then
    tail -n 25 "$APTLOG"
    rm -f "$APTLOG"
    fail "apt-get update failed"
fi
if grep -Eqi '(^Err:|Failed to fetch|NO_PUBKEY|EXPKEYSIG|The repository .* is not signed)' "$APTLOG"; then
    tail -n 25 "$APTLOG"
    rm -f "$APTLOG"
    fail "APT repository download or verification error"
fi
rm -f "$APTLOG"

# Pick the version only from the expected repository and release.
REPOVER=$(apt-cache madison nginx |
    awk -v repo="nginx.org/packages/$REPOPATH" -v suite="$CODENAME" '
        index($0,repo) && index($0,suite "/nginx") {print $3}
    ' | sort -Vu | tail -n1)

[[ -n "$REPOVER" ]] ||
    fail "no nginx package in the $CHANNEL repository for Ubuntu $CODENAME"

dpkg --compare-versions "$REPOVER" ge "$TARGET-0" ||
    fail "repository offers $REPOVER, but at least $TARGET is required"

# Dynamic modules depend on the exact nginx version and must be upgraded with it.
mapfile -t MODULES < <(dpkg-query -W -f='${db:Status-Status} ${Package}\n' |
    awk '$1 == "installed" && $2 ~ /^nginx-module-/ {print $2}')

# Dry run - do not let APT remove packages.
SIM=$(apt-get -s install --only-upgrade "nginx=$REPOVER" "${MODULES[@]}" 2>&1) ||
    fail "APT upgrade simulation failed"
if grep -qE '^Remv ' <<<"$SIM"; then
    printf '%s\n' "$SIM" | grep '^Remv '
    fail "APT plans to remove packages - upgrade aborted"
fi

# Upgrade to the exact verified version.
apt-get install -y --only-upgrade "nginx=$REPOVER" "${MODULES[@]}" ||
    fail "installing nginx $REPOVER failed"

NEWVER=$(dpkg-query -W -f='${Version}' nginx)
dpkg --compare-versions "$NEWVER" ge "$TARGET-0" ||
    fail "unpatched version $NEWVER still installed after the upgrade"

# Test the configuration and restart the service on the new binary.
nginx -t >/dev/null 2>&1 ||
    fail "nginx -t fails after the upgrade; configuration backup: $BACKUP"

systemctl restart nginx ||
    fail "nginx restart failed"

systemctl is-active --quiet nginx ||
    fail "nginx service is not active after restart"

# Final check of the running binary.
RUNVER=$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p')
dpkg --compare-versions "$RUNVER" ge "$TARGET" ||
    fail "running binary is version $RUNVER, expected at least $TARGET"

echo "UPDATED AND SECURE: nginx $NEWVER ($CHANNEL), configuration valid, service running after restart."