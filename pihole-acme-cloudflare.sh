#!/usr/bin/env bash
#
# pihole-acme-cloudflare - trusted HTTPS for the Pi-hole v6 web interface.
#
# Gets a Let's Encrypt (or ZeroSSL) certificate with acme.sh using a Cloudflare
# DNS challenge, so Pi-hole never has to be reachable from the internet.
# Renewal is automatic (acme.sh cron job), and every new certificate is checked,
# installed and loaded into pihole-FTL without manual steps.
# Works with a normal Pi-hole install and with Pi-hole in Docker.
#
# Inspired by https://gist.github.com/kaczmar2/17f02a0ddb59a7d336b20376695797c6
#
# Quick start:  sudo ./pihole-acme-cloudflare.sh install      (see --help)
set -euo pipefail

VERSION="1.0.0"
NAME="pihole-acme-cloudflare"
INSTALL_PATH="/usr/local/sbin/$NAME"
DEFAULT_CONF="/etc/$NAME.conf"
CONF="${PIHOLE_ACME_CONF:-$DEFAULT_CONF}"
# acme.sh runs the deploy step from cron with a minimal PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# --- Settings: environment variables, overridden by the config file ----------
DOMAINS="${DOMAINS:-}"                 # space-separated, first is the main name; wildcards allowed
WEB_DOMAIN="${WEB_DOMAIN:-}"           # name you open Pi-hole on (default: first non-wildcard in DOMAINS)
EMAIL="${EMAIL:-}"                     # ACME account email (optional for Let's Encrypt)
CF_Token="${CF_Token:-}"               # Cloudflare API token
CF_Account_ID="${CF_Account_ID:-}"     # only for account-owned tokens
CF_Zone_ID="${CF_Zone_ID:-}"           # optional: lets the token skip Zone:Read
CHALLENGE_ALIAS="${CHALLENGE_ALIAS:-}" # optional: Cloudflare domain that answers the challenge (DNS alias mode)
CA="${CA:-letsencrypt}"                # letsencrypt | zerossl | google | any acme.sh --server value
KEY_TYPE="${KEY_TYPE:-ec-256}"         # ec-256 | ec-384 | 2048 | 3072 | 4096
DOCKER_CONTAINER="${DOCKER_CONTAINER:-}" # Pi-hole container name (auto-detected if pihole-FTL isn't on the host)
PIHOLE_DIR="${PIHOLE_DIR:-}"           # host path of /etc/pihole (auto-detected)
ACME_HOME="${ACME_HOME:-/root/.acme.sh}"
STATE_DIR="${STATE_DIR:-/etc/$NAME}"
CERT_NAME="${CERT_NAME:-tls-acme.pem}"
SETTINGS=(DOMAINS WEB_DOMAIN EMAIL CF_Token CF_Account_ID CF_Zone_ID CHALLENGE_ALIAS CA KEY_TYPE
          DOCKER_CONTAINER PIHOLE_DIR ACME_HOME STATE_DIR CERT_NAME)

FORCE=0 STAGING=0 NONINTERACTIVE=0
DOMAIN_LIST=() ECC=() WEB_HOST=""

# --- Output -------------------------------------------------------------------
if [[ -t 2 ]]; then B=$'\e[1m' R=$'\e[31m' Y=$'\e[33m' G=$'\e[32m' N=$'\e[0m'; else B="" R="" Y="" G="" N=""; fi
log()  { printf '%s==>%s %s\n' "$G" "$N" "$*" >&2; }
warn() { printf '%sWarning:%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sError:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
$NAME $VERSION - Let's Encrypt for the Pi-hole v6 web interface via Cloudflare DNS

Usage: sudo $NAME <command> [options]

Commands:
  install     Set up (asks for missing settings), issue the certificate and load it into Pi-hole.
              Safe to run again, e.g. after changing DOMAINS in the config.
  status      Show the certificate, what Pi-hole is serving, and the next renewal.
  renew       Renew now if due (with --force: renew regardless).
  deploy      Reinstall the current certificate into Pi-hole (acme.sh runs this after each renewal).
  uninstall   Stop renewing and switch Pi-hole back to its own self-signed certificate.

Options:
  --staging          Use the Let's Encrypt staging CA (test without hitting rate limits).
                     Afterwards run 'install --force' to get a real certificate.
  --force            Issue/renew even if the current certificate is still valid.
  -y, --non-interactive  Never prompt; fail if settings are missing.
  -h, --help         Show this help.   -V, --version   Show the version.

Before you start:
  1. Pi-hole v6 (native or Docker), and a domain whose DNS is on Cloudflare (free plan is fine).
  2. Cloudflare API token: dash.cloudflare.com > My Profile > API Tokens > Create Token >
     "Edit zone DNS" template, then add the permission Zone > Zone > Read,
     and limit Zone Resources to your domain.
  3. A local DNS record so the name points to Pi-hole on your LAN:
     Pi-hole > Settings > Local DNS Records, e.g. pihole.example.com -> 192.168.1.2
     (the name does NOT need to exist in public DNS, and nothing needs to be opened in your firewall).
  4. Download this file and run:  sudo bash $NAME.sh install
     It installs acme.sh and itself, asks for the missing settings and saves them.

Settings are read from $DEFAULT_CONF (chmod 600; override with PIHOLE_ACME_CONF=...).
On the first run they can also come from environment variables (unattended setup):
  sudo DOMAINS="pihole.example.com" CF_Token="..." bash $NAME.sh install -y

  DOMAINS           names on the certificate, space-separated; wildcards allowed ("*.lan.example.com")
  WEB_DOMAIN        name you open Pi-hole on (default: first non-wildcard name)
  CF_Token          Cloudflare API token
  CF_Account_ID     only for account-owned tokens
  CF_Zone_ID        lets the token work without Zone > Zone > Read
  CHALLENGE_ALIAS   Cloudflare domain that answers the challenge for domains whose DNS is elsewhere
                    (needs a CNAME _acme-challenge.<name> -> _acme-challenge.<alias domain>)
  EMAIL             ACME account email (optional for Let's Encrypt, required for ZeroSSL)
  CA                letsencrypt (default), zerossl, google, ...
  KEY_TYPE          ec-256 (default), ec-384, 2048, 4096
  DOCKER_CONTAINER  Pi-hole container name (auto-detected)
  PIHOLE_DIR        host path of the container's /etc/pihole (auto-detected)

Pi-hole's own certificate files are left untouched: the new certificate is written to
/etc/pihole/$CERT_NAME and Pi-hole is pointed at it with webserver.tls.cert.
EOF
}

# --- Config -------------------------------------------------------------------
need_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo $NAME ...)"; }

load_config() {
    [[ -f $CONF ]] || return 0
    # The file contains the API token, so only root may read it
    [[ $(stat -c %a "$CONF") == [0-7]00 ]] || die "$CONF is readable by other users - run: chmod 600 $CONF"
    # shellcheck source=/dev/null
    . "$CONF"
}

save_config() {
    local v
    (
        umask 077
        {
            echo "# $NAME settings, written $(date '+%F %T'). Contains your API token: keep it chmod 600."
            echo "# After changing DOMAINS or CA, run: sudo $NAME install"
            for v in "${SETTINGS[@]}"; do printf '%s=%q\n' "$v" "${!v}"; done
        } > "$CONF"
    )
    log "Saved settings to $CONF"
}

ask() {  # ask VAR "prompt" [secret]
    local var=$1 prompt=$2 secret=${3:-} reply=""
    [[ -n ${!var} ]] && return 0
    if [[ -n $secret ]]; then
        read -rsp "$prompt: " reply </dev/tty; echo >&2
    else
        read -rp "$prompt: " reply </dev/tty
    fi
    printf -v "$var" '%s' "$reply"
}

wizard() {
    if [[ $NONINTERACTIVE == 1 || ! -t 0 ]]; then return 0; fi
    echo "${B}First-time setup${N} - press Enter to skip optional questions." >&2
    ask DOMAINS  "Hostname(s) for Pi-hole, space-separated (e.g. pihole.example.com)"
    ask CF_Token "Cloudflare API token (permissions: Zone > Zone > Read, Zone > DNS > Edit)" secret
    ask EMAIL    "Email for the ACME account (optional)"
}

parse_domains() {
    local d re='^(\*\.)?([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z][a-z0-9-]*[a-z0-9]$'
    DOMAINS=$(tr '[:upper:],' '[:lower:] ' <<<"$DOMAINS")
    read -ra DOMAIN_LIST <<<"$DOMAINS"
    ((${#DOMAIN_LIST[@]})) || die "DOMAINS is empty - set it in $CONF"
    for d in "${DOMAIN_LIST[@]}"; do
        [[ $d =~ $re ]] || die "'$d' is not a valid hostname (IP addresses cannot get public certificates)"
    done
    WEB_HOST=$WEB_DOMAIN
    if [[ -z $WEB_HOST ]]; then
        for d in "${DOMAIN_LIST[@]}"; do
            if [[ $d != \*.* ]]; then WEB_HOST=$d; break; fi
        done
    fi
    ECC=()
    if [[ $KEY_TYPE == ec-* ]]; then ECC=(--ecc); fi
}

# --- Pi-hole --------------------------------------------------------------------
ftl() {
    if [[ -n $DOCKER_CONTAINER ]]; then docker exec "$DOCKER_CONTAINER" pihole-FTL "$@"
    else pihole-FTL "$@"; fi
}
ftl_get() { ftl --config "$1" 2>/dev/null | tr -d '"\r'; }
ftl_set() {
    [[ $(ftl_get "$1") == "$2" ]] && return 0
    log "Pi-hole: $1 = $2"
    ftl --config "$1" "$2" >/dev/null
}

detect_pihole() {
    if [[ -z $DOCKER_CONTAINER ]] && ! command -v pihole-FTL >/dev/null && command -v docker >/dev/null; then
        DOCKER_CONTAINER=$(docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /pihole/ {print $1; exit}' || true)
        if [[ -n $DOCKER_CONTAINER ]]; then log "Found Pi-hole in Docker container '$DOCKER_CONTAINER'"; fi
    fi
    if [[ -n $DOCKER_CONTAINER ]]; then
        command -v docker >/dev/null || die "DOCKER_CONTAINER is set but docker is not installed"
        [[ $(docker inspect -f '{{.State.Running}}' "$DOCKER_CONTAINER" 2>/dev/null) == true ]] \
            || die "Docker container '$DOCKER_CONTAINER' is not running"
        if [[ -z $PIHOLE_DIR ]]; then
            PIHOLE_DIR=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/pihole"}}{{.Source}}{{end}}{{end}}' "$DOCKER_CONTAINER")
            [[ -n $PIHOLE_DIR ]] || die "Container '$DOCKER_CONTAINER' has no volume for /etc/pihole, so the certificate would be lost on restart. Add one, or set PIHOLE_DIR."
        fi
    else
        command -v pihole-FTL >/dev/null || die "Pi-hole (pihole-FTL) not found. For Pi-hole in Docker, set DOCKER_CONTAINER."
        PIHOLE_DIR=${PIHOLE_DIR:-/etc/pihole}
    fi
    [[ -f $PIHOLE_DIR/pihole.toml ]] || die "$PIHOLE_DIR/pihole.toml not found - Pi-hole v6 is required (or set PIHOLE_DIR)"
    ftl_get webserver.tls.cert >/dev/null || die "'pihole-FTL --config' failed - Pi-hole v6 is required"
}

# Path of our certificate as pihole-FTL sees it (inside the container for Docker)
ftl_cert_path() {
    if [[ -n $DOCKER_CONTAINER ]]; then echo "/etc/pihole/$CERT_NAME"; else echo "$PIHOLE_DIR/$CERT_NAME"; fi
}

# First TLS port from webserver.port, e.g. "80o,443os,[::]:80o,[::]:443os" -> 443
https_port() {
    ftl_get webserver.port | tr ',' '\n' | sed -E 's/.*://' | grep -E '^[0-9]+[a-z]*s' | head -n1 | grep -oE '^[0-9]+' || true
}

restart_ftl() {
    log "Restarting pihole-FTL to load the certificate"
    if [[ -n $DOCKER_CONTAINER ]]; then
        docker restart "$DOCKER_CONTAINER" >/dev/null
    else
        systemctl restart pihole-FTL 2>/dev/null || service pihole-FTL restart
    fi
}

check_local() {
    local port; port=$(https_port)
    if [[ -z $port ]]; then
        warn "Pi-hole's webserver.port has no HTTPS port. Add one with:"
        warn "  pihole-FTL --config webserver.port '80o,443os,[::]:80o,[::]:443os'"
    fi
    if [[ -n $WEB_HOST ]] && ! getent hosts "$WEB_HOST" >/dev/null; then
        warn "$WEB_HOST does not resolve from this machine. Add it under Pi-hole > Settings > Local DNS Records,"
        warn "pointing to this machine's LAN IP, so browsers can find it."
    fi
    if [[ -z $WEB_HOST ]]; then
        warn "DOMAINS only has wildcards - set WEB_DOMAIN to the name you open Pi-hole on."
    fi
}

# --- Cloudflare -------------------------------------------------------------------
cf_api() {
    # The token goes to curl on stdin, so it never shows up in ps
    printf 'header = "Authorization: Bearer %s"\n' "$CF_Token" \
        | curl -sS --max-time 20 -K - "https://api.cloudflare.com/client/v4/$1" || true
}
cf_ok() { grep -Eq '"success"[[:space:]]*:[[:space:]]*true'; }

find_zone() {
    local name=$1 resp
    while [[ $name == *.* ]]; do
        resp=$(cf_api "zones?name=$name")
        if cf_ok <<<"$resp" && ! grep -Eq '"result"[[:space:]]*:[[:space:]]*\[\]' <<<"$resp"; then
            log "  $1 -> Cloudflare zone $name"
            return 0
        fi
        name=${name#*.}
    done
    return 1
}

# Catch token/zone problems before asking the CA (failed attempts count toward rate limits)
check_cloudflare() {
    local d name verify="user/tokens/verify"
    local -A seen=()
    log "Checking the Cloudflare API token"
    if [[ -n $CF_Account_ID ]]; then verify="accounts/$CF_Account_ID/tokens/verify"; fi
    if ! cf_api "$verify" | cf_ok; then
        if [[ -z $CF_Account_ID ]]; then
            die "Cloudflare rejected the API token. If it is an account-owned token, also set CF_Account_ID."
        fi
        die "Cloudflare rejected the API token for account $CF_Account_ID"
    fi
    if [[ -n $CF_Zone_ID ]]; then
        cf_api "zones/$CF_Zone_ID/dns_records?per_page=1" | cf_ok \
            || die "The token cannot read DNS records in zone $CF_Zone_ID - it needs Zone > DNS > Edit for that zone"
        return 0
    fi
    for d in "${DOMAIN_LIST[@]}"; do
        name=${CHALLENGE_ALIAS:-${d#\*.}}
        [[ -n ${seen[$name]:-} ]] && continue
        seen[$name]=1
        find_zone "$name" || die "No Cloudflare zone found for $name. The token needs Zone > Zone > Read and Zone > DNS > Edit for that zone (or set CF_Zone_ID). Domains whose DNS is not on Cloudflare can use CHALLENGE_ALIAS."
    done
}

# --- acme.sh -------------------------------------------------------------------------
acme() { "$ACME_HOME/acme.sh" --home "$ACME_HOME" "$@"; }

install_acme() {
    [[ -x $ACME_HOME/acme.sh ]] && return 0
    command -v crontab >/dev/null || die "crontab not found - install cron first (e.g. apt install cron) so certificates renew automatically"
    log "Installing acme.sh into $ACME_HOME"
    local tmp; tmp=$(mktemp -d)
    curl -fsSL https://github.com/acmesh-official/acme.sh/archive/refs/heads/master.tar.gz | tar -xz -C "$tmp"
    local args=(--install --home "$ACME_HOME")
    if [[ -n $EMAIL ]]; then args+=(--accountemail "$EMAIL"); fi
    (cd "$tmp/acme.sh-master" && ./acme.sh "${args[@]}") || die "acme.sh installation failed"
    rm -rf "$tmp"
}

issue_cert() {
    local server=$CA rc=0 d v
    if [[ $STAGING == 1 ]]; then
        [[ $CA == letsencrypt ]] || die "--staging only works with CA=letsencrypt"
        server=letsencrypt_test
    fi
    local args=(--issue --dns dns_cf --server "$server" --keylength "$KEY_TYPE")
    for d in "${DOMAIN_LIST[@]}"; do
        args+=(-d "$d")
        if [[ -n $CHALLENGE_ALIAS ]]; then args+=(--challenge-alias "$CHALLENGE_ALIAS"); fi
    done
    if [[ $FORCE == 1 ]]; then args+=(--force); fi
    if [[ -n $EMAIL ]]; then args+=(--accountemail "$EMAIL"); fi
    for v in CF_Token CF_Account_ID CF_Zone_ID; do
        if [[ -n ${!v} ]]; then export "${v?}"; fi
    done

    log "Requesting a certificate for ${DOMAIN_LIST[*]} from $server"
    acme "${args[@]}" || rc=$?
    case $rc in
        0) ;;
        2) log "The current certificate is still valid - not renewed (use --force to issue a new one now)" ;;
        *) die "The certificate request failed - see the acme.sh output above" ;;
    esac
}

install_cert() {
    local reload="$INSTALL_PATH deploy"
    if [[ $CONF != "$DEFAULT_CONF" ]]; then reload="PIHOLE_ACME_CONF='$CONF' $reload"; fi
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    # acme.sh copies the files and runs the reload command now and after every renewal
    acme --install-cert -d "${DOMAIN_LIST[0]}" ${ECC[@]+"${ECC[@]}"} \
        --key-file "$STATE_DIR/key.pem" \
        --fullchain-file "$STATE_DIR/fullchain.pem" \
        --reloadcmd "$reload" \
        || die "Installing the certificate into Pi-hole failed - see the output above"
}

self_install() {
    local src; src=$(readlink -f "$0")
    [[ $src == "$INSTALL_PATH" ]] && return 0
    [[ -f $src ]] || die "Run this script from a downloaded file, not through a pipe"
    install -m 755 "$src" "$INSTALL_PATH"
    log "Installed $INSTALL_PATH"
}

# --- Commands -------------------------------------------------------------------------
cmd_install() {
    local c port url
    need_root
    for c in curl openssl tar; do command -v "$c" >/dev/null || die "$c is required"; done
    load_config
    detect_pihole
    [[ -f $CONF ]] || wizard
    [[ -n $DOMAINS ]] || die "DOMAINS is not set - put it in $CONF or pass it as an environment variable"
    [[ -n $CF_Token ]] || die "CF_Token is not set - put it in $CONF or pass it as an environment variable"
    if [[ $CA == zerossl && -z $EMAIL ]]; then die "ZeroSSL requires EMAIL"; fi
    parse_domains
    check_cloudflare
    check_local
    [[ -f $CONF ]] || save_config
    self_install
    install_acme
    issue_cert
    install_cert

    port=$(https_port)
    url="https://${WEB_HOST:-<your-hostname>}"
    if [[ -n $port && $port != 443 ]]; then url+=":$port"; fi
    log "${B}Done.${N} Open $url/admin/ - renewal is automatic. Check anytime with: sudo $NAME status"
    if [[ $STAGING == 1 ]]; then warn "This is a STAGING certificate (not trusted). Run 'sudo $NAME install --force' for a real one."; fi
}

cmd_deploy() {
    local key chain dest tmp owner
    need_root
    load_config
    parse_domains
    detect_pihole
    key=$STATE_DIR/key.pem
    chain=$STATE_DIR/fullchain.pem
    dest=$PIHOLE_DIR/$CERT_NAME
    [[ -s $key && -s $chain ]] || die "No certificate in $STATE_DIR - run '$NAME install' first"
    openssl x509 -in "$chain" -noout -checkend 0 >/dev/null || die "$chain has expired - not deploying it"
    [[ $(openssl x509 -in "$chain" -noout -pubkey) == "$(openssl pkey -in "$key" -pubout)" ]] \
        || die "Key and certificate in $STATE_DIR do not match - not deploying them"

    # Build the combined PEM next to the target and swap it in atomically,
    # owned by the same user as pihole.toml (pihole, or the container's UID)
    owner=$(stat -c '%u:%g' "$PIHOLE_DIR/pihole.toml")
    tmp=$(mktemp "$dest.XXXXXX")
    cat "$chain" "$key" > "$tmp"
    chown "$owner" "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$dest"

    ftl_set webserver.tls.cert "$(ftl_cert_path)" \
        || die "Could not set webserver.tls.cert. If FTLCONF_webserver_tls_cert is set for the container, set it to $(ftl_cert_path) instead."
    if [[ -n $WEB_HOST ]]; then
        ftl_set webserver.domain "$WEB_HOST" \
            || warn "Could not set webserver.domain (locked by FTLCONF_webserver_domain?) - set it to $WEB_HOST yourself"
    fi
    restart_ftl
    log "Pi-hole now uses $dest (valid until $(openssl x509 -in "$chain" -noout -enddate | cut -d= -f2))"
}

cmd_renew() {
    local rc=0 args
    need_root
    load_config
    parse_domains
    [[ -x $ACME_HOME/acme.sh ]] || die "acme.sh not found in $ACME_HOME - run '$NAME install' first"
    args=(--renew -d "${DOMAIN_LIST[0]}" ${ECC[@]+"${ECC[@]}"})
    if [[ $FORCE == 1 ]]; then args+=(--force); fi
    acme "${args[@]}" || rc=$?
    case $rc in
        0) ;;
        2) log "Not due for renewal yet (use --force to renew now)" ;;
        *) die "Renewal failed - see the acme.sh output above" ;;
    esac
}

cmd_status() {
    local dest end days port live file_fp live_fp next
    need_root
    load_config
    parse_domains
    detect_pihole
    dest=$PIHOLE_DIR/$CERT_NAME

    echo "${B}Pi-hole${N}"
    if [[ -n $DOCKER_CONTAINER ]]; then echo "  container           $DOCKER_CONTAINER ($PIHOLE_DIR)"; fi
    echo "  webserver.domain    $(ftl_get webserver.domain)"
    echo "  webserver.tls.cert  $(ftl_get webserver.tls.cert)"
    echo "  webserver.port      $(ftl_get webserver.port)"

    echo "${B}Certificate${N}"
    if [[ -f $dest ]]; then
        end=$(openssl x509 -in "$dest" -noout -enddate | cut -d= -f2)
        days=$(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
        echo "  file                $dest"
        echo "  names               $(openssl x509 -in "$dest" -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^,]*' | cut -d: -f2 | xargs)"
        echo "  issuer              $(openssl x509 -in "$dest" -noout -issuer | sed 's/^issuer=//')"
        echo "  expires             $end ($days days)"
    else
        echo "  ${Y}not installed${N} - run: sudo $NAME install"
    fi
    if [[ -x $ACME_HOME/acme.sh ]]; then
        next=$(acme --info -d "${DOMAIN_LIST[0]}" ${ECC[@]+"${ECC[@]}"} 2>/dev/null | sed -n 's/^Le_NextRenewTimeStr=//p' | tr -d "'\"")
        echo "  next renewal        ${next:-unknown}"
    fi

    port=$(https_port)
    if [[ -n $port && -f $dest && -n $WEB_HOST ]]; then
        file_fp=$(openssl x509 -in "$dest" -noout -fingerprint -sha256)
        live=$(timeout 5 openssl s_client -connect "127.0.0.1:$port" -servername "$WEB_HOST" </dev/null 2>/dev/null || true)
        live_fp=$(openssl x509 -noout -fingerprint -sha256 <<<"$live" 2>/dev/null || true)
        if [[ -z $live_fp ]]; then
            echo "  served on :$port     ${Y}could not connect to 127.0.0.1:$port${N}"
        elif [[ $live_fp == "$file_fp" ]]; then
            echo "  served on :$port     ${G}yes${N}"
        else
            echo "  served on :$port     ${R}no - a different certificate is served${N} (try: sudo $NAME deploy)"
        fi
    fi
}

cmd_uninstall() {
    need_root
    load_config
    parse_domains
    detect_pihole
    if [[ -x $ACME_HOME/acme.sh ]]; then
        acme --remove -d "${DOMAIN_LIST[0]}" ${ECC[@]+"${ECC[@]}"} || warn "acme.sh could not remove ${DOMAIN_LIST[0]}"
    fi
    if [[ $(ftl_get webserver.tls.cert) == "$(ftl_cert_path)" ]]; then
        ftl_set webserver.tls.cert /etc/pihole/tls.pem || warn "Could not reset webserver.tls.cert"
    fi
    rm -f "${PIHOLE_DIR:?}/$CERT_NAME"
    rm -rf "${STATE_DIR:?}"
    restart_ftl
    log "Pi-hole is back on its own self-signed certificate."
    log "Kept $CONF (contains your API token - delete it if you no longer need it)"
    log "Kept acme.sh in $ACME_HOME (remove with: $ACME_HOME/acme.sh --uninstall && rm -rf $ACME_HOME)"
    rm -f "$INSTALL_PATH"
}

# --- Main -------------------------------------------------------------------------------
cmd=""
while (($#)); do
    case $1 in
        install|deploy|renew|status|uninstall) cmd=$1 ;;
        --force) FORCE=1 ;;
        --staging) STAGING=1 ;;
        -y|--non-interactive) NONINTERACTIVE=1 ;;
        -h|--help|help) usage; exit 0 ;;
        -V|--version) echo "$NAME $VERSION"; exit 0 ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
    shift
done
[[ -n $cmd ]] || { usage >&2; exit 1; }
"cmd_$cmd"
