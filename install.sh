#!/usr/bin/env bash
#
# DXSpider and DXWeb installer
#
# Installs a complete DXSpider node and, optionally, the DXWeb browser client
# and the DXWeb Admin supervision UI.
#
# Designed for Debian, Ubuntu and Raspberry Pi OS. Other distributions are
# detected and reported; the script will not guess package names.
#
# Run with sudo. The script is idempotent only in the sense that it refuses to
# overwrite an existing installation; use --upgrade for code updates.
#
# Copyright (c) 2026 the DXSpider contributors
# Artistic License 2.0, see COPYING and LICENSE.

set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
DEFAULT_REPO="https://github.com/EA3CV/dxspider.git"
DEFAULT_BRANCH="mojo"
LOG="${DXSPIDER_INSTALL_LOG:-/var/log/dxspider-install.log}"

# ---------------------------------------------------------------------------
# Defaults and state
# ---------------------------------------------------------------------------

RUN_USER="sysop"
RUN_GROUP="spider"
INSTALL_DIR=""
NODE_CALL=""
NODE_ALIAS=""
NODE_NAME=""
NODE_QTH=""
NODE_LOCATOR=""
NODE_LAT=""
NODE_LON=""
NODE_EMAIL=""
LISTEN_ADDR="0.0.0.0"
LISTEN_PORT="7300"
REPO="$DEFAULT_REPO"
BRANCH="$DEFAULT_BRANCH"
SOURCE_DIR=""
COMPONENTS="none"
WEB_MODE="direct"
WEB_SCHEME="http"
WEB_HOSTNAME=""
WEB_CERT=""
WEB_KEY=""
DO_DEPS=1
DO_SERVICE=1
DO_START=1
ASSUME_YES=0
NON_INTERACTIVE=0
DRY_RUN=0
UPGRADE=0
STEP=0
TOTAL=8
SPIN_PID=""

# ---------------------------------------------------------------------------
# Presentation
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_CYAN=$'\033[36m'
    C_GREEN=$'\033[32m'
    C_RED=$'\033[31m'
    C_YELLOW=$'\033[33m'
    ANIMATE=1
else
    C_RESET=""
    C_BOLD=""
    C_DIM=""
    C_CYAN=""
    C_GREEN=""
    C_RED=""
    C_YELLOW=""
    ANIMATE=0
fi

cleanup() {
    if [ -n "$SPIN_PID" ]; then
        kill "$SPIN_PID" 2>/dev/null || true
        wait "$SPIN_PID" 2>/dev/null || true
    fi
    [ "$ANIMATE" = 1 ] && printf '\033[?25h'
    return 0
}

trap cleanup EXIT
trap 'printf "\n"; die "Interrupted"' INT TERM

say() { printf '%s\n' "$*"; }
step_msg() { printf '%s==>%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok() { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail() { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

die() {
    fail "$*"
    exit 1
}

log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG"; }

bar_plain() {
    local pct=$1 width=24 filled i out=""
    filled=$(( pct * width / 100 ))
    for ((i = 0; i < width; i++)); do
        if (( i < filled )); then out+="#"; else out+="-"; fi
    done
    printf '[%s]' "$out"
}

animate() {
    local pid=$1 label=$2 start now elapsed pct spin i r g b tick=0
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    start=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
        now=$(date +%s)
        elapsed=$(( now - start ))
        pct=$(( STEP * 100 / TOTAL ))
        (( pct > 99 )) && pct=99
        local bar="" width=28 filled=$(( pct * width / 100 ))
        for ((i = 0; i < width; i++)); do
            if (( i < filled )); then
                r=$(( 34 + 90 * i / width ))
                g=$(( 211 - 40 * i / width ))
                b=$(( 238 - 60 * i / width ))
                if (( i == tick % width )); then
                    bar+=$'\033[38;2;255;255;255m█'
                else
                    bar+=$'\033[38;2;'"$r"';'"$g"';'"$b"'m█'
                fi
            else
                bar+=$'\033[38;2;55;65;81m░'
            fi
        done
        local eta="--:--"
        if (( pct > 0 )); then
            local rem=$(( elapsed * (100 - pct) / pct ))
            printf -v eta '%02d:%02d' $(( rem / 60 )) $(( rem % 60 ))
        fi
        printf '\r\033[K%s %s %b\033[0m %d/%d %-34s %3d%% %02d:%02d ETA %s' \
            "${frames[tick % 10]}" "$C_CYAN" "$bar" "$STEP" "$TOTAL" \
            "${label:0:34}" "$pct" $(( elapsed / 60 )) $(( elapsed % 60 )) "$eta"
        tick=$(( tick + 1 ))
        sleep 0.12
    done
    printf '\r\033[K'
}

run_step() {
    local label=$1
    shift

    STEP=$(( STEP + 1 ))
    (( STEP >= TOTAL )) && TOTAL=$(( STEP + 1 ))
    log "STEP $STEP/$TOTAL $label: $*"

    if [ "$DRY_RUN" = 1 ]; then
        printf '[dry-run] %s: %s\n' "$label" "$*"
        return 0
    fi

    if [ "$ANIMATE" = 1 ]; then
        printf '\033[?25l'
        ( "$@" >>"$LOG" 2>&1 ) &
        SPIN_PID=$!
        animate "$SPIN_PID" "$label"
        local rc=0
        wait "$SPIN_PID" || rc=$?
        SPIN_PID=""
        printf '\033[?25h'
    else
        printf '%s %s/%s %s\n' "$(bar_plain $(( STEP * 100 / TOTAL )))" "$STEP" "$TOTAL" "$label"
        local rc=0
        "$@" >>"$LOG" 2>&1 || rc=$?
    fi

    if [ "$rc" -ne 0 ]; then
        fail "$label (exit $rc)"
        if [ -s "$LOG" ]; then
            tail -n 30 "$LOG" >&2 || true
        fi
        exit "$rc"
    fi
    ok "$label"
    STEP_LAST=$label
}

ask() {
    local prompt=$1 default=${2:-} answer=""
    if [ "$NON_INTERACTIVE" = 1 ]; then
        printf '%s' "$default"
        return 0
    fi
    printf '%s%s: ' "$prompt" "${default:+ [$default]}" >&2
    if [ -r /dev/tty ]; then
        IFS= read -r answer </dev/tty || true
    else
        IFS= read -r answer || true
    fi
    printf '%s' "${answer:-$default}"
}

ask_yes_no() {
    local prompt=$1 default=${2:-y} answer
    if [ "$ASSUME_YES" = 1 ] || [ "$NON_INTERACTIVE" = 1 ]; then
        [ "$default" = "y" ]
        return
    fi
    answer=$(ask "$prompt (y/n)" "$default")
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

is_debian() {
    [ -r /etc/os-release ] || return 1
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-} ${ID_LIKE:-}" in
        *debian*|*ubuntu*|*raspbian*) return 0 ;;
    esac
    return 1
}

as_user() {
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$RUN_USER" -- "$@"
    else
        local cmd
        cmd=$(printf '%q ' "$@")
        su -s /bin/sh "$RUN_USER" -c "$cmd"
    fi
}

valid_call() {
    local c=$1
    [[ "$c" =~ ^[A-Z0-9][A-Z0-9/]{1,12}(-[0-9]{1,2})?$ ]] &&
        [[ "$c" != Q* ]]
}

valid_qra() {
    [[ "$1" =~ ^[A-R]{2}[0-9]{2}([A-X]{2})?$ ]]
}

valid_email() {
    [[ "$1" =~ ^[^@[:space:]\'\"]+@[^@[:space:]\'\"]+$ ]]
}

usage() {
    cat <<EOF
DXSpider installer ${SCRIPT_VERSION}

Usage:
  sudo bash install.sh [options]

Interactive by default. It asks what to install, collects the station data
and shows a plan before changing anything.

Components:
  --with-web            Install DXWeb as well
  --with-admin          Install DXWeb Admin as well
  --all                 Install DXSpider, DXWeb and DXWeb Admin
  --dxspider-only       Install DXSpider only (default when non-interactive)

Node data (skips the matching prompt):
  --call CALL           Node callsign, for example GB7ABC-2
  --alias CALL          SYSOP callsign, default is the base callsign
  --name NAME           Operator name
  --qth TEXT            QTH description
  --locator QRA         Maidenhead locator, for example JO02AA
  --lat DEGREES         Latitude, south is negative
  --lon DEGREES         Longitude, west is negative
  --email ADDRESS       Contact address
  --port PORT           Telnet listener port, default 7300
  --listen ADDRESS      Listener address, default 0.0.0.0

Paths and source:
  --dir DIR             Install directory, default /home/sysop/spider
  --user USER           Unix user, default sysop
  --group GROUP         Unix group, default spider
  --repo URL            Git repository
  --branch NAME         Git branch, default mojo
  --source DIR          Copy from a local tree instead of cloning

Web:
  --web-mode MODE       direct or nginx, default direct
  --web-scheme SCHEME   http or https, default http
  --web-hostname NAME   Public hostname for HTTPS
  --web-cert FILE       TLS certificate for direct HTTPS
  --web-key FILE        TLS private key for direct HTTPS

Behaviour:
  --upgrade             Update the code of an existing installation
  --no-deps             Do not install system packages
  --no-service          Do not create or start systemd units
  --no-start            Create services but do not start them
  -y, --yes             Accept the plan without asking
  --non-interactive     Never prompt; requires --call
  --dry-run             Print the plan and commands, change nothing
  -h, --help            This help

Examples:
  sudo bash install.sh
  sudo bash install.sh --all --call GB7ABC-2 --email sysop@example.org
  sudo bash install.sh --with-web --web-mode nginx --web-scheme https \\
       --web-hostname dx.example.org
  sudo bash install.sh --upgrade
EOF
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

ORIG_ARGS=("$@")
COMPONENTS_SET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --with-web)
            if [ "$COMPONENTS" = "admin" ]; then COMPONENTS="both"; else COMPONENTS="dxweb"; fi
            COMPONENTS_SET=1
            ;;
        --with-admin)
            if [ "$COMPONENTS" = "dxweb" ]; then COMPONENTS="both"; else COMPONENTS="admin"; fi
            COMPONENTS_SET=1
            ;;
        --all) COMPONENTS="both"; COMPONENTS_SET=1 ;;
        --dxspider-only) COMPONENTS="none"; COMPONENTS_SET=1 ;;
        --call) NODE_CALL=${2:-}; shift ;;
        --call=*) NODE_CALL=${1#*=} ;;
        --alias) NODE_ALIAS=${2:-}; shift ;;
        --alias=*) NODE_ALIAS=${1#*=} ;;
        --name) NODE_NAME=${2:-}; shift ;;
        --name=*) NODE_NAME=${1#*=} ;;
        --qth) NODE_QTH=${2:-}; shift ;;
        --qth=*) NODE_QTH=${1#*=} ;;
        --locator) NODE_LOCATOR=${2:-}; shift ;;
        --locator=*) NODE_LOCATOR=${1#*=} ;;
        --lat) NODE_LAT=${2:-}; shift ;;
        --lat=*) NODE_LAT=${1#*=} ;;
        --lon) NODE_LON=${2:-}; shift ;;
        --lon=*) NODE_LON=${1#*=} ;;
        --email) NODE_EMAIL=${2:-}; shift ;;
        --email=*) NODE_EMAIL=${1#*=} ;;
        --port) LISTEN_PORT=${2:-}; shift ;;
        --port=*) LISTEN_PORT=${1#*=} ;;
        --listen) LISTEN_ADDR=${2:-}; shift ;;
        --listen=*) LISTEN_ADDR=${1#*=} ;;
        --dir) INSTALL_DIR=${2:-}; shift ;;
        --dir=*) INSTALL_DIR=${1#*=} ;;
        --user) RUN_USER=${2:-}; shift ;;
        --user=*) RUN_USER=${1#*=} ;;
        --group) RUN_GROUP=${2:-}; shift ;;
        --group=*) RUN_GROUP=${1#*=} ;;
        --repo) REPO=${2:-}; shift ;;
        --repo=*) REPO=${1#*=} ;;
        --branch) BRANCH=${2:-}; shift ;;
        --branch=*) BRANCH=${1#*=} ;;
        --source) SOURCE_DIR=${2:-}; shift ;;
        --source=*) SOURCE_DIR=${1#*=} ;;
        --web-mode) WEB_MODE=${2:-}; shift ;;
        --web-mode=*) WEB_MODE=${1#*=} ;;
        --web-scheme) WEB_SCHEME=${2:-}; shift ;;
        --web-scheme=*) WEB_SCHEME=${1#*=} ;;
        --web-hostname) WEB_HOSTNAME=${2:-}; shift ;;
        --web-hostname=*) WEB_HOSTNAME=${1#*=} ;;
        --web-cert) WEB_CERT=${2:-}; shift ;;
        --web-cert=*) WEB_CERT=${1#*=} ;;
        --web-key) WEB_KEY=${2:-}; shift ;;
        --web-key=*) WEB_KEY=${1#*=} ;;
        --upgrade) UPGRADE=1 ;;
        --no-deps) DO_DEPS=0 ;;
        --no-service) DO_SERVICE=0 ;;
        --no-start) DO_START=0 ;;
        -y|--yes) ASSUME_YES=1 ;;
        --non-interactive) NON_INTERACTIVE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Root and early checks
# ---------------------------------------------------------------------------

say ""
printf '%s\n' "${C_BOLD}DXSpider installer ${SCRIPT_VERSION}${C_RESET}"
printf '%s\n' "${C_DIM}DX cluster node, optional web client and admin UI${C_RESET}"
say ""

if [ "$DRY_RUN" != 1 ] && [ "$(id -u)" -ne 0 ]; then
    if [ ! -f "$0" ]; then
        die "Run this script from a file: download it, then sudo bash <file>"
    fi
    if command -v sudo >/dev/null 2>&1; then
        say "Root is required, re-running with sudo..."
        exec sudo -E bash "$0" "${ORIG_ARGS[@]}"
    fi
    die "Root is required. Re-run as root or install sudo."
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
if ! ( : >>"$LOG" ) 2>/dev/null; then
    LOG="/tmp/dxspider-install.log"
    ( : >>"$LOG" ) 2>/dev/null || die "Cannot write to $LOG"
fi
log "DXSpider installer $SCRIPT_VERSION started"

if [ -n "$SOURCE_DIR" ] && [ ! -d "$SOURCE_DIR" ]; then
    die "Source directory does not exist: $SOURCE_DIR"
fi

# ---------------------------------------------------------------------------
# Interactive plan
# ---------------------------------------------------------------------------

if [ "$NON_INTERACTIVE" = 1 ] && [ -z "$NODE_CALL" ]; then
    die "--non-interactive requires --call"
fi

if [ "$NON_INTERACTIVE" = 0 ] && [ "$COMPONENTS_SET" = 0 ] && [ "$UPGRADE" = 0 ]; then
    say "What would you like to install?"
    say "  1) DXSpider only"
    say "  2) DXSpider + DXWeb"
    say "  3) DXSpider + DXWeb Admin"
    say "  4) DXSpider + DXWeb + DXWeb Admin"
    say ""
    say "  Default is 2. Choose 4 only when you need the admin interface."
    choice=$(ask "Choose 1-4" "2")
    case "$choice" in
        1) COMPONENTS="none" ;;
        2) COMPONENTS="dxweb" ;;
        3) COMPONENTS="admin" ;;
        4) COMPONENTS="both" ;;
        *) die "Invalid choice: $choice" ;;
    esac
fi

if [ -z "$INSTALL_DIR" ]; then
    INSTALL_DIR="/home/$RUN_USER/spider"
fi
INSTALL_DIR=${INSTALL_DIR%/}

if [ "$UPGRADE" = 0 ]; then
    if [ -f "$INSTALL_DIR/perl/cluster.pl" ]; then
        die "An installation already exists at $INSTALL_DIR. Use --upgrade to update it, or see Guide_DXS_EN."
    fi
    if [ -e /spider ] && [ ! -L /spider ]; then
        die "/spider exists and is not a symlink. Move it away or choose --dir, then re-run."
    fi
    if [ -L /spider ]; then
        current=$(readlink -f /spider || true)
        target=$(readlink -f "$INSTALL_DIR" 2>/dev/null || true)
        if [ -n "$target" ] && [ "$current" != "$target" ]; then
            die "/spider points to $current, not $target. Move it away or choose --dir."
        fi
    fi
fi

if [ "$UPGRADE" = 0 ]; then
    if [ -z "$NODE_CALL" ]; then
        NODE_CALL=$(ask "Node callsign (for example GB7ABC-2)")
    fi
    NODE_CALL=$(printf '%s' "$NODE_CALL" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')
    valid_call "$NODE_CALL" || die "Invalid node callsign: '$NODE_CALL'"

    if [ -z "$NODE_ALIAS" ]; then
        base=${NODE_CALL%%-*}
        NODE_ALIAS=$(ask "SYSOP callsign" "$base")
    fi
    NODE_ALIAS=$(printf '%s' "$NODE_ALIAS" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')
    valid_call "$NODE_ALIAS" || die "Invalid SYSOP callsign: '$NODE_ALIAS'"
    [ "$NODE_ALIAS" != "$NODE_CALL" ] || die "Node and SYSOP callsigns must be different"

    [ -n "$NODE_NAME" ] || NODE_NAME=$(ask "Operator name" "Sysop")
    [ -n "$NODE_QTH" ] || NODE_QTH=$(ask "QTH" "Somewhere")
    [ -n "$NODE_LOCATOR" ] || NODE_LOCATOR=$(ask "Maidenhead locator" "AA00AA")
    NODE_LOCATOR=$(printf '%s' "$NODE_LOCATOR" | tr '[:lower:]' '[:upper:]')
    valid_qra "$NODE_LOCATOR" || die "Invalid locator: '$NODE_LOCATOR'"

    if [ -z "$NODE_LAT" ]; then
        NODE_LAT=$(ask "Latitude (south negative)" "0.0")
    fi
    if [ -z "$NODE_LON" ]; then
        NODE_LON=$(ask "Longitude (west negative)" "0.0")
    fi
    [[ "$NODE_LAT" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || die "Invalid latitude: $NODE_LAT"
    [[ "$NODE_LON" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || die "Invalid longitude: $NODE_LON"
    awk -v v="$NODE_LAT" 'BEGIN{exit !(v >= -90 && v <= 90)}' || die "Latitude must be between -90 and 90"
    awk -v v="$NODE_LON" 'BEGIN{exit !(v >= -180 && v <= 180)}' || die "Longitude must be between -180 and 180"

    case "$NODE_NAME$NODE_QTH" in
        *[\"\\]*) die "Name and QTH must not contain quotes or backslashes" ;;
    esac

    if [ -z "$NODE_EMAIL" ]; then
        NODE_EMAIL=$(ask "Contact email" "sysop@$(hostname -f 2>/dev/null || hostname)")
    fi
    valid_email "$NODE_EMAIL" || die "Invalid email address: $NODE_EMAIL"

    [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] && (( LISTEN_PORT >= 1 && LISTEN_PORT <= 65535 )) ||
        die "Invalid listener port: $LISTEN_PORT"
fi

case "$WEB_MODE" in direct|nginx) ;; *) die "Web mode must be direct or nginx" ;; esac
case "$WEB_SCHEME" in http|https) ;; *) die "Web scheme must be http or https" ;; esac
if [ "$WEB_SCHEME" = "https" ]; then
    [ -n "$WEB_CERT" ] && [ -f "$WEB_CERT" ] || die "HTTPS needs --web-cert FILE"
    [ -n "$WEB_KEY" ] && [ -f "$WEB_KEY" ] || die "HTTPS needs --web-key FILE"
    [ -n "$WEB_HOSTNAME" ] || die "HTTPS needs --web-hostname"
fi

TOTAL=6
[ "$DO_DEPS" = 1 ] && TOTAL=$(( TOTAL + 1 ))
[ "$DO_SERVICE" = 1 ] && TOTAL=$(( TOTAL + 1 ))
[ "$COMPONENTS" != "none" ] && TOTAL=$(( TOTAL + 1 ))

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

say ""
printf '%sPlan%s\n' "$C_BOLD" "$C_RESET"
say "  Install directory : $INSTALL_DIR"
say "  Unix user/group   : $RUN_USER:$RUN_GROUP"
if [ "$UPGRADE" = 1 ]; then
    say "  Action            : upgrade existing code"
else
    say "  Node callsign     : $NODE_CALL"
    say "  SYSOP callsign    : $NODE_ALIAS"
    say "  Locator           : $NODE_LOCATOR"
    say "  Listener          : $LISTEN_ADDR:$LISTEN_PORT"
fi
case "$COMPONENTS" in
    none) say "  Web               : none" ;;
    dxweb) say "  Web               : DXWeb" ;;
    admin) say "  Web               : DXWeb Admin" ;;
    both) say "  Web               : DXWeb + DXWeb Admin" ;;
esac
if [ "$COMPONENTS" != "none" ]; then
    say "  Web access        : $WEB_MODE $WEB_SCHEME"
fi
say "  System packages   : $([ "$DO_DEPS" = 1 ] && echo yes || echo no)"
say "  Service           : $([ "$DO_SERVICE" = 1 ] && echo yes || echo no)"
say ""

if [ "$DRY_RUN" = 1 ]; then
    warn "Dry run: no changes will be made"
fi

if [ "$ASSUME_YES" = 0 ] && [ "$NON_INTERACTIVE" = 0 ] && [ "$DRY_RUN" = 0 ]; then
    ask_yes_no "Continue with this plan?" "y" || { say "Cancelled."; exit 0; }
fi

# ---------------------------------------------------------------------------
# System preparation
# ---------------------------------------------------------------------------

PERL_BIN=$(command -v perl || true)
[ -n "$PERL_BIN" ] || die "Perl is not installed"

if [ "$DO_DEPS" = 1 ]; then
    pkg_extra=()
    if [ "$COMPONENTS" != "none" ] && [ "$WEB_MODE" = "nginx" ]; then
        pkg_extra+=(nginx)
    fi
    if command -v apt-get >/dev/null 2>&1; then
        run_step "Refresh package lists" env DEBIAN_FRONTEND=noninteractive apt-get update -qq
        run_step "Install system packages" env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y -qq \
            git curl ca-certificates iproute2 gzip procps tar \
            build-essential cpanminus libssl-dev zlib1g-dev \
            libev-perl libmojolicious-perl libjson-perl libjson-xs-perl \
            libdata-structure-util-perl libmath-round-perl libnet-cidr-lite-perl \
            libdbi-perl libdbd-sqlite3-perl libtimedate-perl libhtml-parser-perl \
            libio-socket-inet6-perl libarchive-zip-perl libcurses-perl \
            libmailtools-perl libwww-perl libio-pty-perl libauthen-sasl-perl \
            libnet-smtp-ssl-perl libemail-sender-perl "${pkg_extra[@]}"
    elif is_debian; then
        die "apt-get is missing on a Debian-like system"
    else
        warn "Unsupported package manager. Install the packages listed in Guide_DXS_EN section 3, then re-run with --no-deps."
    fi
fi

if [ "$DRY_RUN" = 1 ]; then
    $PERL_BIN -MMojolicious -e 'exit($Mojolicious::VERSION >= 7.26 ? 0 : 1)' 2>/dev/null ||
        warn "Mojolicious >= 7.26 is missing (dry run continues)"
    $PERL_BIN -MDBI -MDBD::SQLite -e 1 2>/dev/null ||
        warn "DBI and DBD::SQLite are missing (dry run continues)"
else
    if ! $PERL_BIN -MMojolicious -e 'exit($Mojolicious::VERSION >= 7.26 ? 0 : 1)'; then
        die "Mojolicious >= 7.26 is missing or broken. Install it and re-run with --no-deps."
    fi
    if ! $PERL_BIN -MDBI -MDBD::SQLite -e 1; then
        die "DBI and DBD::SQLite are missing or broken. Install them and re-run with --no-deps."
    fi
fi

# ---------------------------------------------------------------------------
# User and group
# ---------------------------------------------------------------------------

if ! getent group "$RUN_GROUP" >/dev/null 2>&1; then
    run_step "Create group $RUN_GROUP" groupadd "$RUN_GROUP"
fi

if ! id -u "$RUN_USER" >/dev/null 2>&1; then
    run_step "Create user $RUN_USER" useradd -m -s /bin/sh "$RUN_USER"
fi

if id -u "$RUN_USER" >/dev/null 2>&1; then
    if ! id -nG "$RUN_USER" | tr ' ' '\n' | grep -qx "$RUN_GROUP"; then
        run_step "Add $RUN_USER to $RUN_GROUP" usermod -aG "$RUN_GROUP" "$RUN_USER"
    fi
fi

# ---------------------------------------------------------------------------
# Code
# ---------------------------------------------------------------------------

if [ "$UPGRADE" = 1 ]; then
    [ -f "$INSTALL_DIR/perl/cluster.pl" ] ||
        die "No installation found at $INSTALL_DIR"

    if [ "$DO_SERVICE" = 1 ] && systemctl list-unit-files 2>/dev/null | grep -q '^dxspider\.service'; then
        run_step "Stop DXSpider" systemctl stop dxspider.service
    fi
    run_step "Back up current code" tar -C "$(dirname "$INSTALL_DIR")" -czf \
        "$INSTALL_DIR.pre-upgrade-$(date +%Y%m%d-%H%M%S).tgz" \
        "$(basename "$INSTALL_DIR")"

    if [ -d "$INSTALL_DIR/.git" ]; then
        run_step "Fetch upstream" as_user git -C "$INSTALL_DIR" fetch --prune origin
        run_step "Fast-forward $BRANCH" as_user git -C "$INSTALL_DIR" merge --ff-only "origin/$BRANCH"
    else
        warn "$INSTALL_DIR is not a Git checkout; update it manually"
    fi
else
    if [ "$UPGRADE" = 0 ] && [ -d "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
        die "Install directory is not empty: $INSTALL_DIR"
    fi

    if [ ! -d "$(dirname "$INSTALL_DIR")" ]; then
        run_step "Create parent directory" install -d -o "$RUN_USER" -g "$RUN_GROUP" -m 0755 "$(dirname "$INSTALL_DIR")"
    fi
    run_step "Create $INSTALL_DIR" install -d -o "$RUN_USER" -g "$RUN_GROUP" -m 0755 "$INSTALL_DIR"

    if [ -n "$SOURCE_DIR" ] && [ "$(readlink -f "$SOURCE_DIR")" = "$(readlink -f "$INSTALL_DIR")" ]; then
        die "--source cannot be the same directory as --dir"
    fi
    if [ -n "$SOURCE_DIR" ]; then
        run_step "Copy local source tree" bash -c \
            "tar -C '$SOURCE_DIR' --exclude=.git --exclude=node_modules -cf - . | tar -C '$INSTALL_DIR' -xf - && chown -R '$RUN_USER:$RUN_GROUP' '$INSTALL_DIR'"
    else
        run_step "Clone $BRANCH from $REPO" as_user git clone --branch "$BRANCH" --single-branch "$REPO" "$INSTALL_DIR"
    fi
fi

if [ ! -L /spider ]; then
    run_step "Create /spider link" ln -s "$INSTALL_DIR" /spider
elif [ "$(readlink -f /spider)" != "$(readlink -f "$INSTALL_DIR")" ]; then
    die "/spider no longer points to $INSTALL_DIR"
fi

if [ "$UPGRADE" = 0 ]; then
    run_step "Prepare runtime directories" bash -c \
        "install -d -o '$RUN_USER' -g '$RUN_GROUP' -m 2775 '$INSTALL_DIR/local' '$INSTALL_DIR/local_cmd' '$INSTALL_DIR/local_data'"

    if [ ! -f "$INSTALL_DIR/local/DXVars.pm" ]; then
        run_step "Create local/DXVars.pm" cp -p "$INSTALL_DIR/perl/DXVars.pm.issue" "$INSTALL_DIR/local/DXVars.pm"
    fi
    if [ ! -f "$INSTALL_DIR/local/Listeners.pm" ]; then
        run_step "Create local/Listeners.pm" cp -p "$INSTALL_DIR/perl/Listeners.pm" "$INSTALL_DIR/local/Listeners.pm"
    fi

    if [ "$DRY_RUN" = 0 ]; then
        step_msg "Apply node identity to local/DXVars.pm"
        set_var() {
            local var=$1 value=$2 file="$INSTALL_DIR/local/DXVars.pm"
            VAR="$var" VALUE="$value" perl -0pi -e \
                's/^\Q$ENV{VAR}\E\s*=\s*"[^"]*";/$ENV{VAR} = "$ENV{VALUE}";/m' "$file"
            log "SET $var in $file"
        }
        set_var '$mycall' "$NODE_CALL"
        set_var '$myalias' "$NODE_ALIAS"
        set_var '$myname' "$NODE_NAME"
        set_var '$myqth' "$NODE_QTH"
        set_var '$mylocator' "$NODE_LOCATOR"
        set_var '$myemail' "$NODE_EMAIL"
        VARIABLE='$mylatitude' VALUE="$NODE_LAT" perl -0pi -e \
            's/^\Q$ENV{VARIABLE}\E\s*=\s*[-+]?[0-9.]+;/$ENV{VARIABLE} = $ENV{VALUE};/m' \
            "$INSTALL_DIR/local/DXVars.pm"
        VARIABLE='$mylongitude' VALUE="$NODE_LON" perl -0pi -e \
            's/^\Q$ENV{VARIABLE}\E\s*=\s*[-+]?[0-9.]+;/$ENV{VARIABLE} = $ENV{VALUE};/m' \
            "$INSTALL_DIR/local/DXVars.pm"
        # The email line uses single quotes in the shipped template.
        VALUE="$NODE_EMAIL" perl -0pi -e \
            "s/^\\\$myemail\\s*=\\s*'[^']*';/\\\$myemail = '\$ENV{VALUE}';/m" \
            "$INSTALL_DIR/local/DXVars.pm"
        chown "$RUN_USER:$RUN_GROUP" "$INSTALL_DIR/local/DXVars.pm"
    fi

    # Only write a listener when the template still has no active entry.
    if [ "$DRY_RUN" = 0 ] && ! grep -Eq '^\s*\[\s*"' "$INSTALL_DIR/local/Listeners.pm"; then
        step_msg "Enable listener $LISTEN_ADDR:$LISTEN_PORT"
        cat >"$INSTALL_DIR/local/Listeners.pm" <<EOF
package main;

use vars qw(@listen);

@listen = (
    ["$LISTEN_ADDR", $LISTEN_PORT],
);

1;
EOF
        chown "$RUN_USER:$RUN_GROUP" "$INSTALL_DIR/local/Listeners.pm"
    fi

    run_step "Create node and SYSOP records" as_user env DXSPIDER_ROOT="$INSTALL_DIR" \
        "$PERL_BIN" "$INSTALL_DIR/perl/create_sysop.pl"
fi

# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------

if [ "$DO_SERVICE" = 1 ]; then
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemd is not available; skipping service creation"
    else
        if [ "$DRY_RUN" = 0 ]; then
            step_msg "Write dxspider.service"
            cat >/etc/systemd/system/dxspider.service <<EOF
[Unit]
Description=DXSpider DX Cluster (mojo)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=/spider
ExecStart=$PERL_BIN -w /spider/perl/cluster.pl
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
        fi
        run_step "Reload systemd" systemctl daemon-reload
        if [ "$DO_START" = 1 ]; then
            run_step "Enable and start DXSpider" systemctl enable --now dxspider.service
        else
            run_step "Enable DXSpider" systemctl enable dxspider.service
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Web components
# ---------------------------------------------------------------------------

if [ "$COMPONENTS" != "none" ]; then
    if [ "$DRY_RUN" = 0 ] && [ ! -f "$INSTALL_DIR/dxweb/dxweb-manager.pl" ]; then
        die "DXWeb files are missing from $INSTALL_DIR"
    fi
    manager_args=(
        "$PERL_BIN" "$INSTALL_DIR/dxweb/dxweb-manager.pl"
        --action install
        --root "$INSTALL_DIR"
        --components "$COMPONENTS"
        --mode "$WEB_MODE"
        --scheme "$WEB_SCHEME"
        --apply
    )
    if [ "$WEB_MODE" = "direct" ] && [ "$WEB_SCHEME" = "https" ]; then
        manager_args+=(--hostname "$WEB_HOSTNAME" --cert "$WEB_CERT" --key "$WEB_KEY")
    fi
    if [ "$WEB_MODE" = "nginx" ] && [ "$WEB_SCHEME" = "https" ]; then
        manager_args+=(--hostname "$WEB_HOSTNAME" --cert "$WEB_CERT" --key "$WEB_KEY")
    fi
    if [ "$DO_START" = 0 ]; then
        # The manager always starts what it configures, so stop afterwards.
        run_step "Configure $COMPONENTS" "${manager_args[@]}"
        run_step "Stop web services" systemctl stop dxweb.service dxweb-admin.service
    else
        run_step "Configure $COMPONENTS" "${manager_args[@]}"
    fi
fi

# ---------------------------------------------------------------------------
# Verification and summary
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = 1 ]; then
    ok "Dry run complete; no changes were made"
    exit 0
fi

if [ "$DO_SERVICE" = 1 ] && [ "$DO_START" = 1 ]; then
    step_msg "Verify services"
    sleep 2
    if systemctl is-active --quiet dxspider.service; then
        ok "dxspider.service is active"
    else
        warn "dxspider.service is not active. Recent log:"
        journalctl -u dxspider.service -n 20 --no-pager >&2 || true
    fi
    if [ "$COMPONENTS" != "none" ]; then
        if [ -x "$INSTALL_DIR/dxweb/dxwebctl" ]; then
            "$PERL_BIN" "$INSTALL_DIR/dxweb/dxwebctl" status || true
        fi
    fi
fi

HOST_SHOW=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -n "$HOST_SHOW" ] || HOST_SHOW="<server-ip>"
WEB_PORT_SHOW=7380
ADMIN_PORT_SHOW=7381

say ""
printf '%sInstallation complete%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
say "  Node             : $NODE_CALL (SYSOP $NODE_ALIAS)"
say "  Directory        : $INSTALL_DIR"
say "  Telnet           : $HOST_SHOW:$LISTEN_PORT"
say "  Service          : dxspider.service"
case "$COMPONENTS" in
    none) ;;
    dxweb)
        say "  DXWeb            : $WEB_SCHEME://${WEB_HOSTNAME:-$HOST_SHOW}:${WEB_PORT_SHOW}"
        ;;
    admin)
        say "  DXWeb Admin      : $WEB_SCHEME://${WEB_HOSTNAME:-$HOST_SHOW}:${ADMIN_PORT_SHOW}"
        ;;
    both)
        say "  DXWeb            : $WEB_SCHEME://${WEB_HOSTNAME:-$HOST_SHOW}:${WEB_PORT_SHOW}"
        say "  DXWeb Admin      : $WEB_SCHEME://${WEB_HOSTNAME:-$HOST_SHOW}:${ADMIN_PORT_SHOW}"
        ;;
esac
say ""
say "Next steps:"
say "  systemctl status dxspider.service"
say "  journalctl -u dxspider.service -f"
say "  sudo -iu $RUN_USER"
if [ "$COMPONENTS" != "none" ]; then
    if [ -x "$INSTALL_DIR/dxweb/dxwebctl" ]; then
        say "  perl $INSTALL_DIR/dxweb/dxwebctl status"
    else
        say "  perl $INSTALL_DIR/dxweb/dxweb-manager.pl --action status"
    fi
    say "  Read README_DXWeb and configure Cloudflare Turnstile if the node is public."
fi
say "  Read Guide_DXS_EN for peers, filters, registration and upgrades."
say ""
say "Log: $LOG"
