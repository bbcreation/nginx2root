#!/usr/bin/env bash
# NGINX security update - Ubuntu + official nginx.org packages
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

DPKG_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
AUTO_YES=0
[[ ${1:-} != --yes ]] || AUTO_YES=1
UNDO=""

restore_sources() {
    rm -f /etc/apt/sources.list.d/nginx.list
    for b in /etc/apt/sources.list.bak-"$STAMP" /etc/apt/sources.list.d/*.bak-"$STAMP"; do
        [[ -f "$b" ]] && mv -f "$b" "${b%.bak-$STAMP}"
    done
    apt-get update >/dev/null 2>&1
}

rollback() {
    echo "Rolling back to nginx $PKGVER..."
    restore_sources
    apt-get install -y --allow-downgrades "${DPKG_OPTS[@]}" "${UBUNTU_PKGS[@]}" >/dev/null 2>&1 ||
        apt-get install -y "${DPKG_OPTS[@]}" "${UBUNTU_PKGS[@]%%=*}" >/dev/null 2>&1
    rm -rf /etc/nginx && tar -xzf "$BACKUP" -C /
    systemctl daemon-reload
    systemctl restart nginx
    if systemctl is-active --quiet nginx; then
        echo "ROLLED BACK: nginx $(dpkg-query -W -f='${Version}' nginx) restored, configuration restored from $BACKUP"
    else
        echo "ROLLBACK FAILED: nginx is not running; restore manually from $BACKUP"
    fi
}

fail() {
    trap - ERR
    set +e
    echo "NOT PATCHED: $*"
    case "$UNDO" in
        sources) restore_sources ;;
        packages) rollback ;;
    esac
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
    trusty|xenial|bionic|focal)
        fail "Ubuntu $CODENAME is end of life and nginx.org no longer builds packages for it; upgrade the OS or move to a new server" ;;
    *) fail "Ubuntu $CODENAME is not handled automatically; manual verification required" ;;
esac

dpkg-query -W -f='${db:Status-Status}' nginx 2>/dev/null | grep -qx installed ||
    fail "nginx package is not installed"

PKGVER=$(dpkg-query -W -f='${Version}' nginx)
MIGRATE=0
if [[ "$PKGVER" == *ubuntu* || "$PKGVER" == *sury* ]]; then
    MIGRATE=1
else
    PKGINFO=$(dpkg-query -W -f='${Maintainer} ${Homepage}' nginx)
    [[ "$PKGINFO" == *nginx.org* || "$PKGINFO" == *NGINX* || "$PKGINFO" == *F5* ]] ||
        fail "nginx package does not look like an official nginx.org/F5 package: $PKGINFO"
fi

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
# Ubuntu and PPA packages are migrated to stable, or to mainline on Laravel Forge servers.
if [[ -z "$CHANNEL" && $MIGRATE -eq 1 ]]; then
    CHANNEL=stable
    [[ ! -d /home/forge ]] || CHANNEL=mainline
elif [[ -z "$CHANNEL" ]]; then
    MINOR=$(sed -n 's/^1\.\([0-9]*\)\..*/\1/p' <<<"$PKGVER")
    [[ -n "$MINOR" ]] || fail "cannot determine nginx.org channel from version $PKGVER"
    if (( MINOR % 2 )); then CHANNEL=mainline; else CHANNEL=stable; fi
fi

case "$CHANNEL" in
    mainline) TARGET=1.31.9; REPOPATH=mainline/ubuntu ;;
    stable)   TARGET=1.30.7; REPOPATH=ubuntu ;;
    *) fail "unknown channel: $CHANNEL" ;;
esac

# The configuration must be valid before anything is changed.
nginx -t >/dev/null 2>&1 || fail "nginx -t fails before the upgrade"

# Ubuntu dynamic modules are replaced with nginx.org packages; stream and mail are built in.
if [[ $MIGRATE -eq 1 ]]; then
    NGINX_T=$(nginx -T 2>/dev/null)
    LISTEN_BEFORE=$(grep -cE '^[[:space:]]*listen[[:space:]]' <<<"$NGINX_T" || true)
    MODULES=()
    LOADS=()
    while read -r file so; do
        [[ "$file" == /etc/nginx/modules-enabled/* ]] ||
            fail "load_module $so in $file; manual migration required"
        pkg=""
        directive=""
        case "$so" in
            ngx_stream_module.so|ngx_mail_module.so) ;;
            ngx_http_geoip2_module.so|ngx_stream_geoip2_module.so) directive=geoip2 ;;
            ngx_http_brotli_filter_module.so|ngx_http_brotli_static_module.so) directive=brotli ;;
            ngx_ssl_ct_module.so|ngx_http_ssl_ct_module.so|ngx_stream_ssl_ct_module.so|ngx_mail_ssl_ct_module.so) directive=ssl_ct ;;
            ngx_http_geoip_module.so|ngx_stream_geoip_module.so) pkg=nginx-module-geoip ;;
            ngx_http_image_filter_module.so) pkg=nginx-module-image-filter ;;
            ngx_http_xslt_filter_module.so) pkg=nginx-module-xslt ;;
            ngx_http_perl_module.so) pkg=nginx-module-perl ;;
            ngx_http_js_module.so|ngx_stream_js_module.so) pkg=nginx-module-njs ;;
            *) fail "module $so has no nginx.org package; manual migration required" ;;
        esac
        if [[ -n "$directive" ]] && grep -qE "^[[:space:]]*$directive" <<<"$NGINX_T"; then
            grep -E "^[[:space:]]*$directive" <<<"$NGINX_T" | sort -u | head -n 5
            fail "the configuration uses $directive, which has no nginx.org module; remove these directives and run again"
        fi
        [[ -n "$pkg" ]] || continue
        [[ " ${LOADS[*]} " == *" $so "* ]] || LOADS+=("$so")
        [[ " ${MODULES[*]} " == *" $pkg "* ]] || MODULES+=("$pkg")
    done < <(awk '
        /^# configuration file / {f = $4; sub(/:$/, "", f)}
        $1 == "load_module" {so = $2; sub(/;$/, "", so); n = split(so, a, "/"); print f, a[n]}' <<<"$NGINX_T")

    echo "nginx $PKGVER is not an nginx.org package (Ubuntu or PPA). It will be replaced with nginx.org $CHANNEL $TARGET or newer."
    echo "Configuration in /etc/nginx is kept. nginx.org modules: ${MODULES[*]:-none}."
    if [[ $AUTO_YES -ne 1 ]]; then
        read -r -p "Type yes to migrate: " ANSWER </dev/tty ||
            fail "no terminal to confirm the migration; run with --yes"
        [[ "$ANSWER" == yes ]] || fail "migration declined"
    fi
fi

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

[[ $MIGRATE -eq 0 ]] || UNDO=sources

# The ondrej/nginx PPA was removed from Launchpad; disable it during migration.
if [[ $MIGRATE -eq 1 ]]; then
    while IFS= read -r f; do
        mv -f "$f" "$f.bak-$STAMP"
    done < <(grep -lE 'ppa\.launchpad(content)?\.net/ondrej/nginx' \
        /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true)
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

# Refresh package indexes. Errors in unrelated repositories are ignored;
# the version check below still requires fresh nginx.org indexes.
APTLOG=$(mktemp)
apt-get update >"$APTLOG" 2>&1 || true
if grep -Ei '(^Err:|^E:|^W:|Failed to fetch|NO_PUBKEY|EXPKEYSIG|is not signed)' "$APTLOG" | grep -q 'nginx\.org'; then
    grep -i 'nginx\.org' "$APTLOG" | tail -n 10
    rm -f "$APTLOG"
    fail "nginx.org repository download or verification error"
fi
if grep -qE '^E: Could not (get|open) lock' "$APTLOG"; then
    grep -E '^E:' "$APTLOG"
    rm -f "$APTLOG"
    fail "APT is locked by another process; try again later"
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

if [[ $MIGRATE -eq 1 ]]; then
    mapfile -t UBUNTU_PKGS < <(dpkg-query -W -f='${db:Status-Status} ${Package}=${Version}\n' |
        awk '$1 == "installed" && $2 ~ /^(nginx|nginx-common|nginx-core|nginx-full|nginx-light|nginx-extras|libnginx-mod-[^=]+)=/ {print $2}')
    INSTALL=(install -y "${DPKG_OPTS[@]}" "nginx=$REPOVER" "${MODULES[@]}")
    ALLOWED='^Remv (nginx-common|nginx-core|nginx-full|nginx-light|nginx-extras|libnginx-mod-[^ ]+) '
else
    # Dynamic modules depend on the exact nginx version and must be upgraded with it.
    mapfile -t MODULES < <(dpkg-query -W -f='${db:Status-Status} ${Package}\n' |
        awk '$1 == "installed" && $2 ~ /^nginx-module-/ {print $2}')
    INSTALL=(install -y --only-upgrade "nginx=$REPOVER" "${MODULES[@]}")
    ALLOWED='^$'
fi

# Dry run - do not let APT remove anything except the replaced Ubuntu nginx packages.
SIM=$(apt-get -s "${INSTALL[@]}" 2>&1) ||
    fail "APT upgrade simulation failed"
REMOVALS=$(grep '^Remv ' <<<"$SIM" | grep -vE "$ALLOWED" || true)
if [[ -n "$REMOVALS" ]]; then
    printf '%s\n' "$REMOVALS"
    fail "APT plans to remove packages - upgrade aborted"
fi

HAD_DEFAULT_CONF=0
[[ ! -e /etc/nginx/conf.d/default.conf ]] || HAD_DEFAULT_CONF=1

# Upgrade to the exact verified version.
[[ $MIGRATE -eq 0 ]] || UNDO=packages
apt-get "${INSTALL[@]}" ||
    fail "installing nginx $REPOVER failed"

if [[ $MIGRATE -eq 1 ]]; then
    # dpkg may replace unmodified Ubuntu config files with nginx.org defaults.
    tar -xzf "$BACKUP" -C / ||
        fail "failed to restore /etc/nginx from $BACKUP"
    find /etc/nginx/modules-enabled -xtype l -delete 2>/dev/null || true
    if [[ ${#LOADS[@]} -gt 0 ]]; then
        printf 'load_module modules/%s;\n' "${LOADS[@]}" > /etc/nginx/modules-enabled/50-nginx2root.conf
    fi
    [[ $HAD_DEFAULT_CONF -eq 1 ]] || rm -f /etc/nginx/conf.d/default.conf
    LISTEN_AFTER=$(nginx -T 2>/dev/null | grep -cE '^[[:space:]]*listen[[:space:]]' || true)
    [[ "$LISTEN_AFTER" == "$LISTEN_BEFORE" ]] ||
        fail "configuration changed during migration ($LISTEN_BEFORE listen directives before, $LISTEN_AFTER after)"
    systemctl daemon-reload ||
        fail "systemctl daemon-reload failed"
fi

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

if [[ $MIGRATE -eq 1 ]]; then
    systemctl enable nginx >/dev/null 2>&1 ||
        fail "systemctl enable nginx failed"
    printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' \
        > /etc/apt/preferences.d/99nginx
    UNDO=""
    echo "MIGRATED AND SECURE: nginx $PKGVER (Ubuntu or PPA) replaced with nginx.org $NEWVER ($CHANNEL), configuration valid, service running after restart."
else
    echo "UPDATED AND SECURE: nginx $NEWVER ($CHANNEL), configuration valid, service running after restart."
fi