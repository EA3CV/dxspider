#!/usr/bin/env bash
#
# DXSpider upgrade helper
#
# A guided upgrade for the mojo branch:
#   - checks the tree and remote
#   - refuses local changes
#   - takes a code and configuration/data snapshot
#   - stops services, fast-forwards, checks syntax, restarts and verifies
#   - keeps rollback instructions and a rollback mode
#
# Run as root: sudo bash upgrade.sh
# Copyright (c) 2026 the DXSpider contributors
# Artistic License 2.0, see COPYING and LICENSE.

set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
LOG="${DXSPIDER_UPGRADE_LOG:-/var/log/dxspider-upgrade.log}"

DIR="/spider"
BRANCH=""
REPO=""
BACKUP_DIR="/var/backups/dxspider"
DO_BACKUP=1
SKIP_WEB=0
REFRESH_WEB=0
NO_RESTART=0
CHECK_ONLY=0
DRY_RUN=0
ASSUME_YES=0
AUTO_ROLLBACK=0
RESTART_ONLY=0
ROLLBACK=0
ROLLBACK_TO=""
STEP=0
TOTAL=10
SPIN_PID=""
SERVICES_STOPPED=0
UPGRADE_OK=0
ROLLING_BACK=0
START_FAILED=0

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
    local rc=$?
    if [ -n "$SPIN_PID" ]; then
        kill "$SPIN_PID" 2>/dev/null || true
        wait "$SPIN_PID" 2>/dev/null || true
    fi
    [ "$ANIMATE" = 1 ] && printf '\033[?25h'
    if [ "$SERVICES_STOPPED" = 1 ] && [ "$UPGRADE_OK" != 1 ] && [ "$ROLLING_BACK" != 1 ]; then
        warn "Upgrade did not complete; attempting to restart services"
        start_services >/dev/null 2>&1 || true
    fi
    return 0
}

say() { printf '%s\n' "$*"; }
ok() { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail() { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() { fail "$*"; exit 1; }

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
    local pid=$1 label=$2 start now elapsed pct spin tick=0
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    start=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
        now=$(date +%s)
        elapsed=$(( now - start ))
        pct=$(( STEP * 100 / TOTAL ))
        (( pct > 99 )) && pct=99
        local bar="" width=28 filled=$(( pct * width / 100 )) i r g b
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
        [ -s "$LOG" ] && tail -n 30 "$LOG" >&2 || true
        exit "$rc"
    fi
    ok "$label"
}

ask_yes_no() {
    local prompt=$1 default=${2:-n} answer
    if [ "$ASSUME_YES" = 1 ]; then
        [ "$default" = "y" ]
        return
    fi
    printf '%s (y/n) [%s]: ' "$prompt" "$default" >&2
    if [ -r /dev/tty ]; then
        IFS= read -r answer </dev/tty || true
    else
        IFS= read -r answer || true
    fi
    answer=${answer:-$default}
    case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

as_user() {
    if [ "$(id -u)" -ne 0 ]; then
        "$@"
    elif command -v runuser >/dev/null 2>&1; then
        runuser -u "$RUN_USER" -- "$@"
    else
        local cmd
        cmd=$(printf '%q ' "$@")
        su -s /bin/sh "$RUN_USER" -c "$cmd"
    fi
}

usage() {
    cat <<EOF
DXSpider upgrade helper ${SCRIPT_VERSION}

Usage:
  sudo bash upgrade.sh [options]

Options:
  --dir DIR              DXSpider tree, default /spider
  --branch NAME          Branch to follow, default the current branch
  --repo URL             Git remote, default the tree's origin
  --backup-dir DIR       Snapshot directory, default /var/backups/dxspider
  --no-backup            Skip the snapshot (not recommended)
  --skip-web             Do not restart DXWeb or DXWeb Admin
  --refresh-web          Re-run the web installer after the code update
  --no-restart           Stop after the code update and syntax check
  --restart              Restart services without updating code
  --check                Preflight only, then exit
  --dry-run              Show the plan and commands, change nothing
  --auto-rollback        Restore the snapshot if startup fails
  -y, --yes              Accept the plan without asking
  --rollback             Restore the latest snapshot
  --rollback-to DIR      Restore a specific snapshot
  -h, --help             This help

Examples:
  sudo bash upgrade.sh
  sudo bash upgrade.sh --check
  sudo bash upgrade.sh --dry-run
  sudo bash upgrade.sh --branch mojo --no-restart
  sudo bash upgrade.sh --rollback
EOF
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

ORIG_ARGS=("$@")
while [ $# -gt 0 ]; do
    case "$1" in
        --dir) DIR=${2:-}; shift ;;
        --dir=*) DIR=${1#*=} ;;
        --branch) BRANCH=${2:-}; shift ;;
        --branch=*) BRANCH=${1#*=} ;;
        --repo) REPO=${2:-}; shift ;;
        --repo=*) REPO=${1#*=} ;;
        --backup-dir) BACKUP_DIR=${2:-}; shift ;;
        --backup-dir=*) BACKUP_DIR=${1#*=} ;;
        --no-backup) DO_BACKUP=0 ;;
        --skip-web) SKIP_WEB=1 ;;
        --refresh-web) REFRESH_WEB=1 ;;
        --no-restart) NO_RESTART=1 ;;
        --restart) RESTART_ONLY=1 ;;
        --check) CHECK_ONLY=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --auto-rollback) AUTO_ROLLBACK=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        --rollback) ROLLBACK=1 ;;
        --rollback-to) ROLLBACK_TO=${2:-}; ROLLBACK=1; shift ;;
        --rollback-to=*) ROLLBACK_TO=${1#*=}; ROLLBACK=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Root, logging and tree detection
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" = 0 ] && [ "$CHECK_ONLY" = 0 ] && [ "$(id -u)" -ne 0 ]; then
    [ -f "$0" ] || die "Run this script from a file: download it, then sudo bash <file>"
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$0" "${ORIG_ARGS[@]}"
    fi
    die "Root is required. Re-run as root or install sudo."
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
if ! ( : >>"$LOG" ) 2>/dev/null; then
    LOG="/tmp/dxspider-upgrade.log"
    ( : >>"$LOG" ) 2>/dev/null || die "Cannot write to $LOG"
fi
log "DXSpider upgrade helper $SCRIPT_VERSION started"

say ""
printf '%s\n' "${C_BOLD}DXSpider upgrade${C_RESET}"
printf '%s\n' "${C_DIM}Fast-forward, verify and roll back safely${C_RESET}"
say ""

# A rollback snapshot records the tree it belongs to. Read it before the
# default tree check so the snapshot script works from any directory.
if [ "$ROLLBACK" = 1 ]; then
    if [ -z "$ROLLBACK_TO" ]; then
        ROLLBACK_TO=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name 'upgrade-*' 2>/dev/null | sort | tail -1)
    fi
    if [ -n "$ROLLBACK_TO" ] && [ -f "$ROLLBACK_TO/metadata" ]; then
        # shellcheck disable=SC1090
        . "$ROLLBACK_TO/metadata"
    fi
fi

DIR=$(readlink -f "$DIR" 2>/dev/null || true)
[ -n "$DIR" ] && [ -d "$DIR" ] || die "Installation directory not found"
[ -f "$DIR/perl/cluster.pl" ] || die "$DIR does not look like a DXSpider tree"
[ -d "$DIR/.git" ] || die "$DIR is not a Git checkout. Use the manual procedure in Guide_DXS_EN section 15."

RUN_USER=$(systemctl show -p User --value dxspider.service 2>/dev/null || true)
if [ -z "$RUN_USER" ] || [ "$RUN_USER" = "root" ]; then
    RUN_USER=$(stat -c %U "$DIR" 2>/dev/null || echo sysop)
fi
[ "$RUN_USER" != "root" ] || die "Refusing to run the node as root"

PERL_BIN=$(command -v perl || true)
[ -n "$PERL_BIN" ] || die "Perl is not installed"

if [ -z "$REPO" ]; then
    REPO=$(git -c safe.directory="$DIR" -C "$DIR" remote get-url origin 2>/dev/null || true)
fi
[ -n "$REPO" ] || die "No Git remote found. Use --repo URL or add origin."

if [ -z "$BRANCH" ]; then
    BRANCH=$(git -c safe.directory="$DIR" -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
fi
case "$BRANCH" in
    ""|HEAD) die "Detached HEAD or missing branch. Use --branch NAME." ;;
esac

BEFORE_REV=$(git -c safe.directory="$DIR" -C "$DIR" rev-parse HEAD)
BEFORE_DESC=$(git -c safe.directory="$DIR" -C "$DIR" describe --tags --always --dirty 2>/dev/null || echo "$BEFORE_REV")
BEFORE_DXWEB=$(cat "$DIR/dxweb/VERSION" 2>/dev/null | tr -d '[:space:]' || true)
BEFORE_ADMIN=$(cat "$DIR/dxweb-admin/VERSION" 2>/dev/null | tr -d '[:space:]' || true)

has_service() {
    systemctl list-unit-files 2>/dev/null | grep -q "^$1"
}
SERVICES=()
has_service dxspider.service && SERVICES+=(dxspider.service)
has_service dxweb.service && SERVICES+=(dxweb.service)
has_service dxweb-admin.service && SERVICES+=(dxweb-admin.service)

stop_services() {
    [ "$SERVICES_STOPPED" = 1 ] && return 0
    local svc
    for svc in dxweb-admin.service dxweb.service dxspider.service; do
        if [[ " ${SERVICES[*]} " == *" $svc "* ]]; then
            systemctl stop "$svc" || true
        fi
    done
    SERVICES_STOPPED=1
}

start_services() {
    local svc
    for svc in dxspider.service dxweb.service dxweb-admin.service; do
        if [[ " ${SERVICES[*]} " == *" $svc "* ]]; then
            systemctl start "$svc" || true
        fi
    done
}

config_port() {
    local svc=$1 key=$2 default=$3 value
    value=$(systemctl show -p Environment --value "$svc" 2>/dev/null \
        | tr ' ' '\n' | sed -n "s/^${key}=//p" | head -1)
    printf '%s' "${value:-$default}"
}

wait_port() {
    local port=$1 tries=0
    [ -n "$port" ] || return 0
    while (( tries < 30 )); do
        if ss -ltn 2>/dev/null | grep -q ":$port "; then
            return 0
        fi
        tries=$(( tries + 1 ))
        sleep 1
    done
    return 1
}

wait_http() {
    local base=$1 tries=0 path
    while (( tries < 30 )); do
        for path in /version.json /software-version.json /healthz; do
            if curl -fsS "$base$path" >/dev/null 2>&1; then
                return 0
            fi
        done
        tries=$(( tries + 1 ))
        sleep 1
    done
    return 1
}

verify_services() {
    local rc=0 port web_port admin_port
    if has_service dxspider.service; then
        if systemctl is-active --quiet dxspider.service; then
            port=$(perl -0ne 'print $1 if /\@listen\s*=\s*\(\s*\[\s*"[^"]*"\s*,\s*(\d+)/s' \
                "$DIR/local/Listeners.pm" 2>/dev/null | head -1)
            if [ -n "$port" ] && ! wait_port "$port"; then
                warn "dxspider.service is active but port $port is not listening"
                rc=1
            fi
        else
            warn "dxspider.service is not active"
            rc=1
        fi
    fi
    if [ "$SKIP_WEB" = 0 ]; then
        if has_service dxweb.service; then
            web_port=$(config_port dxweb.service HTTP_PORT 7380)
            if ! wait_http "http://127.0.0.1:$web_port"; then
                warn "DXWeb did not become ready on port $web_port"
                rc=1
            fi
        fi
        if has_service dxweb-admin.service; then
            admin_port=$(config_port dxweb-admin.service DXWEB_PORT 7381)
            if ! wait_http "http://127.0.0.1:$admin_port"; then
                warn "DXWeb Admin did not become ready on port $admin_port"
                rc=1
            fi
        fi
    fi
    return "$rc"
}

# ---------------------------------------------------------------------------
# Rollback
# ---------------------------------------------------------------------------

restore_snapshot() {
    local snap=$1
    [ -d "$snap" ] || die "Snapshot not found: $snap"
    [ -f "$snap/metadata" ] || die "Snapshot has no metadata: $snap"
    # shellcheck disable=SC1090
    . "$snap/metadata"
    [ -n "${OLDREV:-}" ] || die "Snapshot has no revision"
    say ""
    say "Snapshot : $snap"
    say "Revision : $OLDREV"
    say "Created  : ${SNAP_DATE:-unknown}"
    say ""
    if [ "$ASSUME_YES" = 0 ] && [ "$AUTO_ROLLBACK" = 0 ]; then
        if ! ask_yes_no "Restore this snapshot and restart services?" "n"; then
            say "Cancelled."
            exit 0
        fi
        printf 'Type ROLLBACK to continue: ' >&2
        local answer
        IFS= read -r answer </dev/tty || true
        [ "$answer" = "ROLLBACK" ] || die "Rollback cancelled"
    fi
    ROLLING_BACK=1
    stop_services
    run_step "Restore tracked files" as_user git -c safe.directory="$DIR" -C "$DIR" reset --hard "$OLDREV"
    if [ -f "$snap/local.tar.gz" ]; then
        run_step "Restore local configuration" tar -xzf "$snap/local.tar.gz" -C "$DIR"
    fi
    if [ -f "$snap/data.tar.gz" ]; then
        run_step "Restore local_data" tar -xzf "$snap/data.tar.gz" -C "$DIR"
    fi
    run_step "Start services" start_services
    verify_services || warn "Services need attention after rollback"
    UPGRADE_OK=1
    ok "Rollback complete"
    say "Revision: $(git -c safe.directory="$DIR" -C "$DIR" rev-parse --short HEAD)"
    exit 0
}

if [ "$ROLLBACK" = 1 ]; then
    if [ -z "$ROLLBACK_TO" ]; then
        ROLLBACK_TO=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name 'upgrade-*' 2>/dev/null | sort | tail -1)
    fi
    [ -n "$ROLLBACK_TO" ] || die "No snapshot found under $BACKUP_DIR"
    restore_snapshot "$ROLLBACK_TO"
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

say "Installation : $DIR"
say "Owner        : $RUN_USER"
say "Branch       : $BRANCH"
say "Remote       : $REPO"
say "Current      : $BEFORE_DESC ($BEFORE_REV)"
[ -n "$BEFORE_DXWEB" ] && say "DXWeb        : $BEFORE_DXWEB"
[ -n "$BEFORE_ADMIN" ] && say "DXWeb Admin  : $BEFORE_ADMIN"
say ""

if [ -n "$(git -c safe.directory="$DIR" -C "$DIR" status --porcelain 2>/dev/null)" ]; then
    git -c safe.directory="$DIR" -C "$DIR" status --short >&2 || true
    die "The tree has local changes. Commit or stash them before upgrading."
fi

if [ "$CHECK_ONLY" = 1 ] || [ "$DRY_RUN" = 1 ]; then
    TARGET_SHA=$(git ls-remote --heads "$REPO" "refs/heads/$BRANCH" 2>/dev/null | awk '$2 == "refs/heads/'"$BRANCH"'" { print $1 }' | head -1)
    [ -n "$TARGET_SHA" ] || die "Cannot read $BRANCH from $REPO"
else
    run_step "Fetch $BRANCH" as_user git -c safe.directory="$DIR" -C "$DIR" fetch --prune "$REPO" \
        "+refs/heads/$BRANCH:refs/remotes/upgrade/$BRANCH"
    TARGET_SHA=$(git -c safe.directory="$DIR" -C "$DIR" rev-parse "refs/remotes/upgrade/$BRANCH")
fi

if [ "$TARGET_SHA" = "$BEFORE_REV" ]; then
    say ""
    ok "Already up to date at $BEFORE_DESC"
    if [ "$RESTART_ONLY" = 1 ]; then
        step_msg="Restart services"
        say "$step_msg"
        stop_services
        run_step "Start services" start_services
        UPGRADE_OK=1
        verify_services || die "Services did not become ready"
    fi
    exit 0
fi

# Compare revisions that exist locally. A check or dry run must not change the
# worktree, but fetching the object is acceptable and does not touch services.
if ! git -c safe.directory="$DIR" -C "$DIR" cat-file -e "$TARGET_SHA^{commit}" 2>/dev/null; then
    if [ "$CHECK_ONLY" = 1 ] || [ "$DRY_RUN" = 1 ]; then
        as_user git -c safe.directory="$DIR" -C "$DIR" fetch --prune "$REPO" \
            "+refs/heads/$BRANCH:refs/remotes/upgrade/$BRANCH" >>"$LOG" 2>&1 || \
            die "Cannot fetch $BRANCH from $REPO"
    else
        run_step "Fetch $BRANCH" as_user git -c safe.directory="$DIR" -C "$DIR" fetch --prune "$REPO" \
            "+refs/heads/$BRANCH:refs/remotes/upgrade/$BRANCH"
    fi
fi
read -r AHEAD BEHIND <<<"$(git -c safe.directory="$DIR" -C "$DIR" rev-list --left-right --count "HEAD...$TARGET_SHA")"
TARGET_DESC=$(git -c safe.directory="$DIR" -C "$DIR" describe --tags --always "$TARGET_SHA" 2>/dev/null || echo "$TARGET_SHA")
TARGET_DXWEB=$(git -c safe.directory="$DIR" -C "$DIR" show "$TARGET_SHA:dxweb/VERSION" 2>/dev/null | tr -d '[:space:]' || true)
TARGET_ADMIN=$(git -c safe.directory="$DIR" -C "$DIR" show "$TARGET_SHA:dxweb-admin/VERSION" 2>/dev/null | tr -d '[:space:]' || true)

say ""
say "Target       : $TARGET_DESC ($TARGET_SHA)"
[ -n "$TARGET_DXWEB" ] && say "DXWeb        : $TARGET_DXWEB"
[ -n "$TARGET_ADMIN" ] && say "DXWeb Admin  : $TARGET_ADMIN"
say "Commits      : $BEHIND behind, $AHEAD ahead"
say ""

if (( AHEAD > 0 )); then
    die "The local branch has commits that are not on $REPO/$BRANCH. Resolve them before upgrading."
fi
if (( BEHIND == 0 )); then
    ok "Already up to date"
    exit 0
fi

if [ -n "$(git -c safe.directory="$DIR" -C "$DIR" status --porcelain 2>/dev/null)" ]; then
    die "The tree became dirty during the check. Stop and investigate."
fi

# Detect new configuration variables in the target template.
NEW_VARS=""
if git -c safe.directory="$DIR" -C "$DIR" cat-file -e "$TARGET_SHA:perl/DXVars.pm.issue" 2>/dev/null; then
    TMP_VARS=$(mktemp)
    git -c safe.directory="$DIR" -C "$DIR" show "$TARGET_SHA:perl/DXVars.pm.issue" >"$TMP_VARS"
    TARGET_VARS=$(perl -ne 'print "$1\n" if /^\s*(?:our\s+)?\$([A-Za-z_]\w*)\s*=/' "$TMP_VARS" | sort -u)
    LOCAL_VARS=$(perl -ne 'print "$1\n" if /^\s*(?:our\s+)?\$([A-Za-z_]\w*)\s*=/' "$DIR/local/DXVars.pm" | sort -u)
    NEW_VARS=$(comm -23 <(printf '%s\n' "$TARGET_VARS") <(printf '%s\n' "$LOCAL_VARS") || true)
    rm -f "$TMP_VARS"
fi

if [ -n "$NEW_VARS" ]; then
    warn "The new template has variables missing from local/DXVars.pm:"
    printf '  %s\n' $NEW_VARS >&2
    warn "Review Guide_DXS_EN section 15.1 after the upgrade. The file will be backed up first."
fi

if [ "$CHECK_ONLY" = 1 ]; then
    say ""
    ok "Preflight passed"
    exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
    say "Plan:"
    say "  stop services, create a snapshot under $BACKUP_DIR, fast-forward to $TARGET_SHA,"
    say "  check syntax, restart services and verify readiness."
    say ""
    ok "Dry run complete; no changes were made"
    exit 0
fi

if [ "$ASSUME_YES" = 0 ]; then
    say "This will stop the node, update the code and restart it."
    ask_yes_no "Continue?" "y" || { say "Cancelled."; exit 0; }
fi

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------

SNAP=""
if [ "$DO_BACKUP" = 1 ]; then
    STAMP=$(date +%Y%m%d-%H%M%S)
    SNAP="$BACKUP_DIR/upgrade-$STAMP"
    run_step "Create backup directory" install -d -m 0700 "$SNAP"
fi

if [ "${#SERVICES[@]}" -gt 0 ]; then
    say ""
    say "Stopping services"
    stop_services
    ok "Services stopped"
else
    warn "No DXSpider systemd units found; continuing without service control"
fi

if [ "$DO_BACKUP" = 1 ]; then
    run_step "Save code history" git -c safe.directory="$DIR" -C "$DIR" bundle create "$SNAP/code.bundle" HEAD
    LOCAL_ITEMS=()
    for item in local local_cmd connect; do
        [ -e "$DIR/$item" ] && LOCAL_ITEMS+=("$item")
    done
    if [ "${#LOCAL_ITEMS[@]}" -gt 0 ]; then
        run_step "Save local configuration" tar -czf "$SNAP/local.tar.gz" -C "$DIR" "${LOCAL_ITEMS[@]}"
    fi
    if [ -d "$DIR/local_data" ]; then
        run_step "Save local_data" tar -czf "$SNAP/data.tar.gz" -C "$DIR" \
            --exclude='local_data/debug' --exclude='local_data/*.log' \
            --exclude='local_data/dxhistory.db*' --exclude='local_data/badlist-backups' \
            local_data
    fi
    {
        printf 'DIR=%q\n' "$DIR"
        printf 'OLDREV=%q\n' "$BEFORE_REV"
        printf 'BRANCH=%q\n' "$BRANCH"
        printf 'REPO=%q\n' "$REPO"
        printf 'SNAP_DATE=%q\n' "$(date -Is)"
        printf 'SERVICES=%q\n' "${SERVICES[*]}"
    } >"$SNAP/metadata"
    cp "$0" "$SNAP/upgrade.sh" 2>/dev/null || true
    chmod 700 "$SNAP/upgrade.sh" 2>/dev/null || true
    ok "Snapshot: $SNAP"
fi

# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------

run_step "Fast-forward to $BRANCH" as_user git -c safe.directory="$DIR" -C "$DIR" merge --ff-only "$TARGET_SHA"

AFTER_REV=$(git -c safe.directory="$DIR" -C "$DIR" rev-parse HEAD)
[ "$AFTER_REV" = "$TARGET_SHA" ] || die "Merge did not reach the target revision"

run_step "Check cluster syntax" as_user env DXSPIDER_ROOT="$DIR" "$PERL_BIN" -c "$DIR/perl/cluster.pl"

# ---------------------------------------------------------------------------
# Restart
# ---------------------------------------------------------------------------

if [ "$NO_RESTART" = 1 ]; then
    UPGRADE_OK=1
    ok "Code updated to $TARGET_DESC. Services remain stopped."
    say "Start them with: systemctl start dxspider.service"
    exit 0
fi

if [ "$REFRESH_WEB" = 1 ] && [ "$SKIP_WEB" = 0 ] && [ -f "$DIR/dxweb/dxweb-manager.pl" ]; then
    COMPONENTS=""
    has_service dxweb.service && COMPONENTS="dxweb"
    has_service dxweb-admin.service && COMPONENTS="${COMPONENTS:+$COMPONENTS,}admin"
    if [ -n "$COMPONENTS" ]; then
        run_step "Refresh web services" "$PERL_BIN" "$DIR/dxweb/dxweb-manager.pl" \
            --action install --root "$DIR" --components "$COMPONENTS" --apply
    fi
fi

run_step "Start services" start_services
if ! verify_services; then
    UPGRADE_OK=0
    fail "The upgrade completed but services are not healthy"
    if [ "$AUTO_ROLLBACK" = 1 ] && [ -n "$SNAP" ]; then
        warn "Auto-rollback to $SNAP"
        ROLLING_BACK=1
        restore_snapshot "$SNAP"
    fi
    if [ -n "$SNAP" ]; then
        say "Rollback with: sudo bash $SNAP/upgrade.sh --rollback-to $SNAP"
    fi
    exit 1
fi

UPGRADE_OK=1

say ""
printf '%sUpgrade complete%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
say "  Previous : $BEFORE_DESC"
say "  Current  : $TARGET_DESC"
[ -n "$TARGET_DXWEB" ] && say "  DXWeb    : ${BEFORE_DXWEB:-?} -> $TARGET_DXWEB"
[ -n "$TARGET_ADMIN" ] && say "  Admin    : ${BEFORE_ADMIN:-?} -> $TARGET_ADMIN"
[ -n "$SNAP" ] && say "  Snapshot : $SNAP"
say ""
say "Next steps:"
say "  systemctl status dxspider.service"
say "  journalctl -u dxspider.service -n 50 --no-pager"
say "  sh/version and sh/health from the cluster console"
if [ -n "$NEW_VARS" ]; then
    say "  Review new configuration variables in Guide_DXS_EN section 15.1"
fi
if [ -n "$SNAP" ]; then
    say "  Rollback: sudo bash $SNAP/upgrade.sh --rollback-to $SNAP"
fi
say ""
say "Log: $LOG"
