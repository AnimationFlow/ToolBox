#!/usr/bin/env bash
# claud-manager.sh — Claude Code instance manager

set -uo pipefail

MANAGER_VERSION="1.0.0"

# ── paths ─────────────────────────────────────────────────────────────────────
SYSTEMD_DIR="${HOME}/.config/systemd/user"
CLAUDE_BIN="${HOME}/.local/bin/claude"
CLAUDE_JSON="${HOME}/.claude.json"
WATCHDOG_LOG_DIR="${HOME}/.local/share/claude-watchdog"
WATCHDOG_BIN_DIR="${HOME}/.local/bin"
PNPM_HOME="${HOME}/.local/share/pnpm"
SVC_PATH_ENV="PATH=${PNPM_HOME}:${HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ── self-update: resolve repo dir from script's real path ─────────────────────
_SCRIPT_REAL="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
_TOOLBOX_DIR="$(dirname "$_SCRIPT_REAL")"

# ── background check state ────────────────────────────────────────────────────
_LATEST_VER_FILE=""
_VER_CHECK_STARTED=0
_SELF_UPDATE_FILE=""
_SELF_UPDATE_STARTED=0

# ── colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

# ── ui helpers ────────────────────────────────────────────────────────────────
info() { echo -e "${CYAN}  >${RESET} $*"; }
ok()   { echo -e "${GREEN}  ✓${RESET} $*"; }
warn() { echo -e "${YELLOW}  !${RESET} $*"; }
err()  { echo -e "${RED}  ✗${RESET} $*"; }
sep()  { echo -e "${DIM}────────────────────────────────────────────────────${RESET}"; }
hdr()  { echo; echo -e "  ${BOLD}${CYAN}$*${RESET}"; sep; }
pause(){ read -rp "  [press enter]" _; }

# Ensure systemctl --user can reach the D-Bus session bus (needed when invoked from tmux/cron)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"

is_active()  { systemctl --user is-active  --quiet "$1" 2>/dev/null; }
is_enabled() { systemctl --user is-enabled --quiet "$1" 2>/dev/null; }

# ── cc helpers ────────────────────────────────────────────────────────────────
cc_installed() { [[ -x "$CLAUDE_BIN" ]]; }

cc_version() {
    "$CLAUDE_BIN" --version 2>/dev/null | head -1 || echo "unknown"
}

_ensure_rc_json() {
    [[ -f "$CLAUDE_JSON" ]] || echo '{}' > "$CLAUDE_JSON"
    if ! python3 -c "import json; d=json.load(open('$CLAUDE_JSON')); exit(0 if d.get('remoteControlAtStartup') else 1)" 2>/dev/null; then
        python3 - <<PYEOF
import json
with open('$CLAUDE_JSON') as f:
    d = json.load(f)
d['remoteControlAtStartup'] = True
d.setdefault('remoteControlSpawnMode', 'same-dir')
with open('$CLAUDE_JSON', 'w') as f:
    json.dump(d, f, indent=2)
PYEOF
        ok "remoteControlAtStartup enabled in ~/.claude.json"
    fi
}

# Ensure loginctl linger is enabled so user services survive after logout
_ensure_linger() {
    [[ -f "/var/lib/systemd/linger/${USER}" ]] && return 0
    warn "Linger is not enabled — services will stop when you log out."
    read -rp "  Enable linger now? [Y/n] " _linger_ans
    [[ "${_linger_ans,,}" == "n" ]] && return 0
    loginctl enable-linger "$USER" && ok "Linger enabled."
}

# Detect or install a package manager; echoes "pnpm" or "npm", returns 1 on failure
_ensure_pkg_mgr() {
    # Fast path: pnpm already available
    if command -v pnpm &>/dev/null; then echo "pnpm"; return 0; fi

    # npm available but no pnpm — offer to install pnpm via npm
    if command -v npm &>/dev/null; then
        info "npm found but pnpm is not installed."
        read -rp "  Install pnpm via npm (recommended)? [Y/n] " _pm_ans
        if [[ "${_pm_ans,,}" != "n" ]]; then
            npm install -g pnpm && export PATH="${PNPM_HOME}:$PATH"
            if command -v pnpm &>/dev/null; then ok "pnpm installed."; echo "pnpm"; return 0; fi
            warn "pnpm install failed, falling back to npm."
        fi
        echo "npm"; return 0
    fi

    # Nothing available — offer pnpm standalone (manages its own Node)
    warn "Node.js / npm not found."
    read -rp "  Install pnpm standalone (will also manage Node via pnpm env)? [Y/n] " _pm_ans
    [[ "${_pm_ans,,}" == "n" ]] && { err "Cannot proceed without a package manager."; return 1; }

    info "Installing pnpm standalone…"
    curl -fsSL https://get.pnpm.io/install.sh | PNPM_HOME="$PNPM_HOME" sh - \
        || { err "pnpm install failed."; return 1; }
    export PATH="${PNPM_HOME}:$PATH"
    if ! command -v pnpm &>/dev/null; then
        err "pnpm not found after install — restart shell and rerun."; return 1
    fi
    ok "pnpm installed."

    info "Installing Node.js LTS via pnpm env…"
    pnpm env use --global lts \
        && ok "Node.js LTS installed." \
        || { err "Node install via pnpm failed."; return 1; }

    echo "pnpm"; return 0
}

# ── instance discovery ────────────────────────────────────────────────────────
# Returns the slug whose WorkingDirectory matches the given path, or empty string
_slug_for_dir() {
    local target; target=$(realpath "$1" 2>/dev/null) || return
    for svc in "${SYSTEMD_DIR}"/claude-*.service; do
        [[ -f "$svc" ]] || continue
        local base; base=$(basename "$svc" .service)
        [[ "$base" == claude-watchdog-* ]] && continue
        local slug="${base#claude-}"
        local wd; wd=$(_svc_field "$slug" workdir)
        wd=$(realpath "$wd" 2>/dev/null) || continue
        [[ "$wd" == "$target" ]] && { echo "$slug"; return; }
    done
}

list_instances() {
    local -a names=()
    for svc in "${SYSTEMD_DIR}"/claude-*.service; do
        [[ -f "$svc" ]] || continue
        local base; base=$(basename "$svc" .service)
        [[ "$base" == claude-watchdog-* ]] && continue
        names+=("${base#claude-}")
    done
    printf '%s\n' "${names[@]}"
}

_svc_field() {
    # _svc_field <slug> socket|session|workdir|rcname
    local slug="$1" field="$2"
    local svc="${SYSTEMD_DIR}/claude-${slug}.service"
    [[ -f "$svc" ]] || { echo ""; return; }
    case "$field" in
        socket)  grep -oP '(?<=-L )\S+'        "$svc" | head -1 || echo "$slug" ;;
        session) grep -oP '(?<=-s )\S+'        "$svc" | head -1 || echo "claude-${slug}" ;;
        workdir) grep 'WorkingDirectory' "$svc" | cut -d= -f2 | head -1 | sed "s|%h|$HOME|g" ;;
        rcname)  grep -oP "(?<=--name )\S+"    "$svc" | head -1 | tr -d "'" || echo "$slug" ;;
    esac
}

_tmux_cmd() {
    local socket="$1" session="$2"
    tmux -L "$socket" list-panes -t "$session" -F '#{pane_current_command}' 2>/dev/null || echo ""
}

_instance_row() {
    local slug="$1" idx="$2"
    local socket session rcname workdir
    socket=$(_svc_field  "$slug" socket)
    session=$(_svc_field "$slug" session)
    rcname=$(_svc_field  "$slug" rcname)
    workdir=$(_svc_field "$slug" workdir)

    # service status
    local svc_dot
    is_active "claude-${slug}" && svc_dot="${GREEN}●${RESET}" || svc_dot="${RED}○${RESET}"

    # tmux / claude alive
    local cmd; cmd=$(_tmux_cmd "$socket" "$session")
    local proc_info
    if [[ "$cmd" == "claude" ]]; then
        proc_info="${GREEN}claude${RESET}"
    elif [[ -n "$cmd" ]]; then
        proc_info="${YELLOW}${cmd}${RESET}"
    else
        proc_info="${DIM}no session${RESET}"
    fi

    # watchdog
    local wd_dot
    if [[ -f "${SYSTEMD_DIR}/claude-watchdog-${slug}.timer" ]]; then
        is_active "claude-watchdog-${slug}.timer" \
            && wd_dot="${GREEN}●${RESET}" || wd_dot="${RED}○${RESET}"
    else
        wd_dot="${DIM}—${RESET}"
    fi

    printf "  ${BOLD}%3s)${RESET} ${svc_dot} ${BOLD}%-16s${RESET}  proc:%-18b  wd:%b  ${DIM}%s${RESET}\n" \
        "$idx" "$rcname" "$proc_info" "$wd_dot" "$workdir"
}

# ── version helpers ───────────────────────────────────────────────────────────
_start_version_check() {
    _LATEST_VER_FILE=$(mktemp /tmp/claude-manager-ver.XXXXXX)
    (
        local v
        v=$(curl -s --max-time 8 \
            https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null \
            | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])" 2>/dev/null)
        echo "${v:-}" > "$_LATEST_VER_FILE"
    ) &
}

_start_self_check() {
    _SELF_UPDATE_FILE=$(mktemp /tmp/claude-manager-selfupdate.XXXXXX)
    # Needs a git repo and a reachable remote; silently skips if not available
    if [[ ! -d "${_TOOLBOX_DIR}/.git" ]]; then echo "" > "$_SELF_UPDATE_FILE"; return; fi
    (
        timeout 15 git -C "$_TOOLBOX_DIR" fetch origin --quiet 2>/dev/null || { echo "" > "$_SELF_UPDATE_FILE"; exit; }
        count=$(git -C "$_TOOLBOX_DIR" log HEAD..origin/main --oneline -- claude-manager.sh 2>/dev/null | wc -l)
        echo "${count//[[:space:]]/}"
    ) > "$_SELF_UPDATE_FILE" &
}

# true (0) when $1 is strictly newer than $2 (semver sort)
_ver_newer() {
    [[ "$1" == "$2" ]] && return 1
    [[ "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

_cc_cur_ver() {
    "$CLAUDE_BIN" --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1
}

# ── main menu ─────────────────────────────────────────────────────────────────
main_menu() {
    # Kick off background checks once per manager session
    if [[ "$_VER_CHECK_STARTED" -eq 0 ]]; then
        _start_version_check
        _VER_CHECK_STARTED=1
        trap 'rm -f "$_LATEST_VER_FILE" "$_SELF_UPDATE_FILE"' EXIT
    fi
    if [[ "$_SELF_UPDATE_STARTED" -eq 0 ]]; then
        _start_self_check
        _SELF_UPDATE_STARTED=1
    fi

    while true; do
        hdr "Claude Code Manager"

        # Self-update check result
        local self_update=0
        if [[ -s "$_SELF_UPDATE_FILE" ]]; then
            local _su_count; _su_count=$(cat "$_SELF_UPDATE_FILE")
            [[ "$_su_count" =~ ^[0-9]+$ && "$_su_count" -gt 0 ]] && self_update=1
        fi

        # CC status + background version result
        local cur_ver="" latest_ver="" update_available=0
        if cc_installed; then
            cur_ver=$(_cc_cur_ver)
            if [[ -s "$_LATEST_VER_FILE" ]]; then
                latest_ver=$(cat "$_LATEST_VER_FILE")
                _ver_newer "$latest_ver" "$cur_ver" && update_available=1
            fi
            if [[ "$update_available" -eq 1 ]]; then
                echo -e "  Claude Code : ${GREEN}${cur_ver}${RESET} ${YELLOW}→ ${latest_ver}${RESET}  ${BOLD}u)${RESET} update"
            else
                echo -e "  Claude Code : ${GREEN}${cur_ver}${RESET}"
            fi
        else
            echo -e "  Claude Code : ${RED}not installed${RESET}  ${BOLD}i)${RESET} install"
        fi

        # Manager version + self-update inline
        if [[ "$self_update" -eq 1 ]]; then
            echo -e "  Manager     : ${GREEN}${MANAGER_VERSION}${RESET} ${YELLOW}update available${RESET}  ${BOLD}s)${RESET} self-update"
        else
            echo -e "  Manager     : ${GREEN}${MANAGER_VERSION}${RESET}"
        fi

        # Linger
        [[ -f "/var/lib/systemd/linger/${USER}" ]] \
            && echo -e "  Linger      : ${GREEN}enabled${RESET}" \
            || echo -e "  Linger      : ${YELLOW}disabled${RESET}  (run: loginctl enable-linger $USER)"
        sep

        # Instances
        local -a instances=()
        mapfile -t instances < <(list_instances 2>/dev/null || true)

        if [[ ${#instances[@]} -gt 0 ]]; then
            echo -e "  ${BOLD}  # svc  name              proc               wd  dir${RESET}"
            local i=1
            for slug in "${instances[@]}"; do
                _instance_row "$slug" "$i"
                (( i++ ))
            done
            sep
        else
            echo -e "  ${DIM}No instances found.${RESET}"
            sep
        fi

        echo -e "  ${BOLD}n)${RESET} New instance"
        echo -e "  ${BOLD}m)${RESET} Manage MCPs (context7, mcp-installer)"
        echo -e "  ${BOLD}q)${RESET} Quit"
        sep
        read -rp "  Choice: " choice

        case "$choice" in
            q|Q) echo; ok "Bye."; echo; exit 0 ;;
            n|N) new_instance_wizard ;;
            m|M) mcp_menu ;;
            i|I)
                if ! cc_installed; then
                    install_cc_menu
                else
                    warn "Already installed. Wait for version check or use u) to update."
                fi
                ;;
            u|U)
                if [[ "$update_available" -eq 1 ]]; then
                    local pkg_mgr; pkg_mgr=$(_ensure_pkg_mgr) || continue
                    "$pkg_mgr" install -g @anthropic-ai/claude-code \
                        && ok "Updated to ${latest_ver}." \
                        || err "Update failed."
                    # Re-kick version check so display refreshes
                    rm -f "$_LATEST_VER_FILE"
                    _VER_CHECK_STARTED=0
                    _start_version_check
                    _VER_CHECK_STARTED=1
                else
                    warn "No update available."
                fi
                ;;
            s|S)
                if [[ "$self_update" -eq 1 ]]; then
                    info "Pulling latest claude-manager.sh from repo…"
                    if git -C "$_TOOLBOX_DIR" pull; then
                        ok "Updated. Restarting manager…"
                        sleep 1
                        exec "$0" "$@"
                    else
                        err "git pull failed."
                    fi
                else
                    warn "No self-update available."
                fi
                ;;
            ''|*[!0-9]*) warn "Unknown option." ;;
            *)
                local idx=$(( choice - 1 ))
                if [[ $idx -ge 0 && $idx -lt ${#instances[@]} ]]; then
                    instance_menu "${instances[$idx]}"
                else
                    warn "No such instance."
                fi
                ;;
        esac
    done
}

# ── instance menu ─────────────────────────────────────────────────────────────
instance_menu() {
    local slug="$1"
    local socket session workdir rcname
    socket=$(_svc_field  "$slug" socket)
    session=$(_svc_field "$slug" session)
    workdir=$(_svc_field "$slug" workdir)
    rcname=$(_svc_field  "$slug" rcname)
    local wlog="${WATCHDOG_LOG_DIR}/${slug}.log"

    while true; do
        hdr "Instance: ${rcname}"
        echo -e "  Slug:    ${DIM}${slug}${RESET}"
        echo -e "  Dir:     ${DIM}${workdir}${RESET}"
        echo -e "  Attach:  ${DIM}tmux -L ${socket} attach -t ${session}${RESET}"
        echo
        _instance_row "$slug" "–"

        # Last watchdog entry
        if [[ -f "$wlog" ]]; then
            echo -e "  ${DIM}Watchdog: $(tail -1 "$wlog")${RESET}"
        fi
        sep

        echo -e "  ${BOLD}1)${RESET} Start"
        echo -e "  ${BOLD}2)${RESET} Stop"
        echo -e "  ${BOLD}3)${RESET} Restart"
        echo -e "  ${BOLD}4)${RESET} Attach tmux ( Ctrl+B, D to detach )"
        echo -e "  ${BOLD}5)${RESET} Service logs"
        echo -e "  ${BOLD}6)${RESET} Watchdog logs"
        if [[ -f "${SYSTEMD_DIR}/claude-watchdog-${slug}.timer" ]]; then
            echo -e "  ${BOLD}7)${RESET} Remove watchdog"
        else
            echo -e "  ${BOLD}7)${RESET} Add watchdog"
        fi
        echo -e "  ${BOLD}r)${RESET} Rename display name"
        echo -e "  ${BOLD}m)${RESET} Manage MCPs"
        echo -e "  ${BOLD}d)${RESET} Delete instance"
        echo -e "  ${BOLD}b)${RESET} Back"
        sep
        read -rp "  Choice: " choice

        case "$choice" in
            1) systemctl --user start   "claude-${slug}" && ok "Started."   || err "Failed." ;;
            2) systemctl --user stop    "claude-${slug}" && ok "Stopped."   || err "Failed." ;;
            3) systemctl --user restart "claude-${slug}" && ok "Restarted." || err "Failed." ;;
            4)
                info "Attaching… (detach with Ctrl-B D)"
                tmux -L "$socket" attach -t "$session" || warn "Could not attach."
                ;;
            5)
                sep
                journalctl --user -u "claude-${slug}" -n 40 --no-pager 2>/dev/null || warn "No logs."
                sep; pause
                ;;
            6)
                sep
                if [[ -f "$wlog" ]]; then cat "$wlog"; else warn "No watchdog log."; fi
                sep; pause
                ;;
            7)
                if [[ -f "${SYSTEMD_DIR}/claude-watchdog-${slug}.timer" ]]; then
                    _remove_watchdog "$slug" && ok "Watchdog removed."
                else
                    _create_watchdog "$slug" "$socket" "$session" && ok "Watchdog added."
                    systemctl --user daemon-reload
                    systemctl --user enable --now "claude-watchdog-${slug}.timer" && ok "Timer enabled."
                fi
                ;;
            r|R)
                _rename_display_name "$slug"
                # refresh local rcname after rename
                rcname=$(_svc_field "$slug" rcname)
                ;;
            m|M) mcp_menu ;;
            d|D) delete_instance "$slug"; return ;;
            b|B) return ;;
            *) warn "Unknown option." ;;
        esac
    done
}

# ── new instance wizard ───────────────────────────────────────────────────────
new_instance_wizard() {
    local default_dir="${1:-$PWD}"

    hdr "New Claude Code Instance"

    # Name — default to the folder name
    local default_name; default_name=$(basename "$default_dir")
    read -rp "  Instance name [${default_name}]: " rcname
    rcname="${rcname:-$default_name}"
    [[ -n "$rcname" ]] || { warn "Name cannot be empty."; return; }

    local slug
    slug=$(echo "$rcname" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-')

    if [[ -f "${SYSTEMD_DIR}/claude-${slug}.service" ]]; then
        warn "Instance '${slug}' already exists."
        read -rp "  Open its instance menu? [Y/n] " ans
        [[ "${ans,,}" == "n" ]] || instance_menu "$slug"
        return
    fi

    # Working dir
    read -rp "  Working dir [${default_dir}]: " workdir
    workdir="${workdir:-$default_dir}"
    workdir="${workdir/#\~/$HOME}"

    if [[ ! -d "$workdir" ]]; then
        read -rp "  Directory doesn't exist. Create it? [Y/n] " ans
        [[ "${ans,,}" == "n" ]] || { mkdir -p "$workdir" && ok "Created ${workdir}"; }
    fi

    # Watchdog
    read -rp "  Add watchdog? [Y/n] " wd_ans
    wd_ans="${wd_ans:-y}"

    echo
    _ensure_linger
    info "Creating instance '${rcname}' (${slug}) → ${workdir}"
    sep

    _ensure_rc_json

    # Service
    mkdir -p "$SYSTEMD_DIR"
    cat > "${SYSTEMD_DIR}/claude-${slug}.service" <<EOF
[Unit]
Description=Claude Code Remote Control - ${rcname}
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
Environment="${SVC_PATH_ENV}"
WorkingDirectory=${workdir}
ExecStart=/usr/bin/tmux -L ${slug} new-session -d -s claude-${slug} -c ${workdir} '${CLAUDE_BIN} -c --name ${rcname}'
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
TimeoutStartSec=30

[Install]
WantedBy=default.target
EOF
    ok "Service: ${SYSTEMD_DIR}/claude-${slug}.service"

    # Watchdog
    if [[ "${wd_ans,,}" != "n" ]]; then
        _create_watchdog "$slug" "$slug" "claude-${slug}"
    fi

    systemctl --user daemon-reload
    systemctl --user enable "claude-${slug}"
    ok "Service enabled."

    if [[ "${wd_ans,,}" != "n" ]]; then
        systemctl --user enable --now "claude-watchdog-${slug}.timer"
        ok "Watchdog timer enabled."
    fi

    read -rp "  Start now? [Y/n] " ans
    if [[ "${ans,,}" != "n" ]]; then
        systemctl --user start "claude-${slug}"
        sleep 2
        if is_active "claude-${slug}"; then
            ok "Instance '${rcname}' running."
            info "Attach: tmux -L ${slug} attach -t claude-${slug}"
            # Warn if Claude Code has never been authenticated on this machine
            if [[ ! -f "${HOME}/.claude/auth_config.json" ]] && \
               ! python3 -c "import json,os; d=json.load(open(os.path.expanduser('~/.claude.json'))); exit(0 if d.get('oauthAccount') or d.get('apiKey') else 1)" 2>/dev/null; then
                echo
                warn "Claude Code does not appear to be authenticated."
                info "Attach to the instance and complete login before use."
            fi
        else
            err "Failed to start. Check: journalctl --user -u claude-${slug}"
        fi
    fi
    echo
}

# ── rename display name ───────────────────────────────────────────────────────
_rename_display_name() {
    local slug="$1"
    local svc="${SYSTEMD_DIR}/claude-${slug}.service"
    local old_name; old_name=$(_svc_field "$slug" rcname)

    read -rp "  New display name [${old_name}]: " new_name
    new_name="${new_name:-$old_name}"
    [[ "$new_name" == "$old_name" ]] && { info "No change."; return; }

    python3 - "$svc" "$new_name" "$old_name" <<'PYEOF'
import sys
path, new, old = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    content = f.read()
content = content.replace(f"--name '{old}'", f"--name '{new}'")
content = content.replace(f"Description=Claude Code Remote Control - {old}",
                          f"Description=Claude Code Remote Control - {new}")
with open(path, 'w') as f:
    f.write(content)
PYEOF

    systemctl --user daemon-reload
    ok "Renamed '${old_name}' → '${new_name}'. Restart instance to apply."
}

# ── watchdog creation / removal ───────────────────────────────────────────────
_create_watchdog() {
    local slug="$1" socket="$2" session="$3"
    local script="${WATCHDOG_BIN_DIR}/claude-watchdog-${slug}.sh"
    local wlog="${WATCHDOG_LOG_DIR}/${slug}.log"
    local wresume="${WATCHDOG_LOG_DIR}/${slug}.resume"
    local wtokens="${WATCHDOG_LOG_DIR}/${slug}.tokens"

    mkdir -p "$WATCHDOG_LOG_DIR"

    cat > "$script" <<WEOF
#!/bin/bash
LOG="${wlog}"
TOKEN_STATE="${wtokens}"
FROZEN_CHECKS=3    # 3 × 5min timer = 15min of unchanged tokens → declare stuck

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log_ok() {
    if [ -s "\$LOG" ] && tail -1 "\$LOG" | grep -q "\] ok\$"; then
        local tmp=\$(mktemp); head -n -1 "\$LOG" > "\$tmp" && mv "\$tmp" "\$LOG"
    fi
    echo "[\$(timestamp)] ok" >> "\$LOG"
}

trim_log() {
    [ -s "\$LOG" ] || return
    local cutoff tmp
    cutoff=\$(date -d '3 days ago' '+%Y-%m-%d')
    tmp=\$(mktemp)
    awk -v d="\$cutoff" '{if(!/^\[/ || substr(\$1,2,10) >= d) print}' "\$LOG" > "\$tmp" && mv "\$tmp" "\$LOG"
}
trim_log

CURRENT_CMD=\$(tmux -L ${socket} list-panes -t ${session} -F '#{pane_current_command}' 2>/dev/null)

if [ -z "\$CURRENT_CMD" ]; then
    echo "[\$(timestamp)] INTERVENED: tmux session missing, restarting claude-${slug}" | tee -a "\$LOG"
    systemctl --user restart claude-${slug}; exit 0
fi

if [ "\$CURRENT_CMD" != "claude" ]; then
    echo "[\$(timestamp)] INTERVENED: process is '\${CURRENT_CMD}' (not claude), restarting claude-${slug}" | tee -a "\$LOG"
    systemctl --user restart claude-${slug}; exit 0
fi

PANE_CONTENT=\$(tmux -L ${socket} capture-pane -t ${session} -p 2>/dev/null)

# Rate limit dialog — option 1 is pre-selected, just send Enter
if echo "\$PANE_CONTENT" | grep -q "rate-limit-options\|Stop and wait for limit"; then
    echo "[\$(timestamp)] rate limit dialog detected, sending Enter" >> "\$LOG"
    tmux -L ${socket} send-keys -t ${session} Enter
    exit 0
fi

# Scroll prompt — blocking dialog takes over the whole pane, so the ❯ prompt disappears.
# Only dismiss if scroll hint is present AND no ❯ prompt visible (rules out tool output).
if echo "\$PANE_CONTENT" | grep -q "to scroll · Space, Enter, or Escape to dismiss" && \
   ! echo "\$PANE_CONTENT" | grep -q "^❯"; then
    echo "[\$(timestamp)] scroll prompt detected (no input prompt visible), sending Escape" >> "\$LOG"
    tmux -L ${socket} send-keys -t ${session} Escape
    exit 0
fi

if echo "\$PANE_CONTENT" | grep -q "Resume from summary"; then
    RESUME_STATE="${wresume}"
    RESUME_COUNT=\$(cat "\$RESUME_STATE" 2>/dev/null || echo 0)
    RESUME_COUNT=\$(( RESUME_COUNT + 1 ))
    echo "\$RESUME_COUNT" > "\$RESUME_STATE"
    if [ "\$RESUME_COUNT" -ge 5 ]; then
        echo "[\$(timestamp)] INTERVENED: resume dialog stuck for \${RESUME_COUNT} checks, restarting claude-${slug}" | tee -a "\$LOG"
        systemctl --user restart claude-${slug}; rm -f "\$RESUME_STATE"
    else
        echo "[\$(timestamp)] resume dialog detected (attempt \${RESUME_COUNT}/5), sending Enter" >> "\$LOG"
        tmux -L ${socket} send-keys -t ${session} Enter
    fi
    exit 0
fi
rm -f "${wresume}"

# Stopwatch "(Xh Xm Xs · ↓ N tokens)" only appears during active tool calls.
# Log elapsed + tokens every check. If tokens unchanged for FROZEN_CHECKS consecutive
# checks (stopwatch keeps ticking = tool running but Claude isn't generating) → restart.
TIME_STR=\$(echo "\$PANE_CONTENT" | grep -oE '([0-9]+h )?([0-9]+m )?[0-9]+s ·' | head -1 | sed 's/ ·\$//')

if [ -z "\$TIME_STR" ]; then
    rm -f "\$TOKEN_STATE"
    log_ok
    exit 0
fi

TOKEN_STR=\$(echo "\$PANE_CONTENT" | grep -oE '[0-9]+(\.[0-9]+)?k? tokens' | head -1)

OLD_LINE=\$(cat "\$TOKEN_STATE" 2>/dev/null || echo ":")
OLD_TOKEN="\${OLD_LINE%%:*}"
OLD_COUNT="\${OLD_LINE##*:}"

if [ -n "\$OLD_TOKEN" ] && [ "\$TOKEN_STR" = "\$OLD_TOKEN" ]; then
    FROZEN_COUNT=\$(( \${OLD_COUNT:-0} + 1 ))
    if [ "\$FROZEN_COUNT" -ge "\$FROZEN_CHECKS" ]; then
        echo "[\$(timestamp)] INTERVENED: tokens stuck at \${TOKEN_STR} for \${FROZEN_COUNT} checks (\${TIME_STR}), restarting claude-${slug}" | tee -a "\$LOG"
        rm -f "\$TOKEN_STATE"
        systemctl --user restart claude-${slug}
    else
        echo "[\$(timestamp)] running \${TIME_STR} — tokens unchanged: \${TOKEN_STR} (\${FROZEN_COUNT}/\${FROZEN_CHECKS})" >> "\$LOG"
        echo "\${TOKEN_STR}:\${FROZEN_COUNT}" > "\$TOKEN_STATE"
    fi
else
    echo "[\$(timestamp)] running \${TIME_STR} — tokens: \${TOKEN_STR}" >> "\$LOG"
    echo "\${TOKEN_STR}:0" > "\$TOKEN_STATE"
fi
WEOF
    chmod +x "$script"
    ok "Watchdog script: ${script}"

    cat > "${SYSTEMD_DIR}/claude-watchdog-${slug}.service" <<EOF
[Unit]
Description=Claude Code Watchdog - ${slug}
After=claude-${slug}.service

[Service]
Type=oneshot
ExecStart=${script}
StandardOutput=journal
StandardError=journal
EOF

    cat > "${SYSTEMD_DIR}/claude-watchdog-${slug}.timer" <<EOF
[Unit]
Description=Claude Code Watchdog Timer - ${slug}

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
    ok "Watchdog service + timer created."
}

_remove_watchdog() {
    local slug="$1"
    systemctl --user disable --now "claude-watchdog-${slug}.timer" 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/claude-watchdog-${slug}.timer"
    rm -f "${SYSTEMD_DIR}/claude-watchdog-${slug}.service"
    rm -f "${WATCHDOG_BIN_DIR}/claude-watchdog-${slug}.sh"
    rm -f "${WATCHDOG_LOG_DIR}/${slug}.tokens"
    systemctl --user daemon-reload
}

# ── delete instance ───────────────────────────────────────────────────────────
delete_instance() {
    local slug="$1"
    local rcname; rcname=$(_svc_field "$slug" rcname)
    local socket;  socket=$(_svc_field  "$slug" socket)

    warn "This will stop, disable and remove all files for '${rcname}'."
    read -rp "  Are you sure? [y/N] " ans
    [[ "${ans,,}" == "y" ]] || { info "Aborted."; return; }

    systemctl --user stop    "claude-${slug}" 2>/dev/null || true
    systemctl --user disable "claude-${slug}" 2>/dev/null || true
    _remove_watchdog "$slug"
    tmux -L "$socket" kill-server 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/claude-${slug}.service"
    rm -f "${WATCHDOG_LOG_DIR}/${slug}.log" "${WATCHDOG_LOG_DIR}/${slug}.tokens" "${WATCHDOG_LOG_DIR}/${slug}.state" "${WATCHDOG_LOG_DIR}/${slug}.hang"
    systemctl --user daemon-reload
    ok "Instance '${rcname}' deleted."
}

# ── mcp management ───────────────────────────────────────────────────────────
# User MCPs live in ~/.claude.json .mcpServers  (apply to ALL instances)
# context7 and mcp-installer are the two managed here.

_mcp_exists_user() {
    python3 - "$CLAUDE_JSON" "$1" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f: d = json.load(f)
sys.exit(0 if sys.argv[2] in d.get('mcpServers', {}) else 1)
PYEOF
}

_add_user_mcp() {
    python3 - "$CLAUDE_JSON" "$1" "$2" <<'PYEOF'
import json, sys
path, name, cfg = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
with open(path) as f: d = json.load(f)
d.setdefault('mcpServers', {})[name] = cfg
with open(path, 'w') as f: json.dump(d, f, indent=2)
PYEOF
}

_remove_user_mcp() {
    python3 - "$CLAUDE_JSON" "$1" <<'PYEOF'
import json, sys
path, name = sys.argv[1], sys.argv[2]
with open(path) as f: d = json.load(f)
d.get('mcpServers', {}).pop(name, None)
with open(path, 'w') as f: json.dump(d, f, indent=2)
PYEOF
}

# context7 and mcp-installer configs
_mcp_cfg_context7()     { echo '{"type":"stdio","command":"npx","args":["-y","@upstash/context7-mcp@latest"]}'; }
_mcp_cfg_mcp_installer(){ echo '{"type":"stdio","command":"npx","args":["@anaisbetts/mcp-installer"]}'; }

mcp_menu() {
    while true; do
        hdr "MCP Manager  ${DIM}(user-level — all instances)${RESET}"

        local c7_status ins_status
        _mcp_exists_user context7      2>/dev/null && c7_status="${GREEN}✓ installed${RESET}" || c7_status="${RED}✗ not installed${RESET}"
        _mcp_exists_user mcp-installer 2>/dev/null && ins_status="${GREEN}✓ installed${RESET}" || ins_status="${RED}✗ not installed${RESET}"

        echo -e "  ${BOLD}1)${RESET} context7       — library/framework docs     ${c7_status}"
        echo -e "       ${DIM}Resolves library names → up-to-date docs for Claude${RESET}"
        echo -e "  ${BOLD}2)${RESET} mcp-installer  — Claude manages its own MCPs  ${ins_status}"
        echo -e "       ${DIM}Lets Claude search and install MCP servers itself${RESET}"
        sep
        echo -e "  ${DIM}Select to toggle on/off. Changes apply after instance restart.${RESET}"
        sep
        echo -e "  ${BOLD}b)${RESET} Back"
        sep
        read -rp "  Choice: " choice

        case "$choice" in
            1)
                if _mcp_exists_user context7 2>/dev/null; then
                    read -rp "  Remove context7? [y/N] " ans
                    [[ "${ans,,}" == "y" ]] && _remove_user_mcp context7 && ok "Removed context7."
                else
                    _add_user_mcp context7 "$(_mcp_cfg_context7)" && ok "Added context7."
                fi ;;
            2)
                if _mcp_exists_user mcp-installer 2>/dev/null; then
                    read -rp "  Remove mcp-installer? [y/N] " ans
                    [[ "${ans,,}" == "y" ]] && _remove_user_mcp mcp-installer && ok "Removed mcp-installer."
                else
                    _add_user_mcp mcp-installer "$(_mcp_cfg_mcp_installer)" && ok "Added mcp-installer."
                fi ;;
            b|B) return ;;
            *) warn "Unknown option." ;;
        esac
    done
}

# ── cc install ────────────────────────────────────────────────────────────────
install_cc_menu() {
    hdr "Install Claude Code"

    echo -e "  Install methods:"
    echo -e "  ${BOLD}1)${RESET} pnpm / npm  (auto-detected, pnpm preferred)"
    echo -e "  ${BOLD}2)${RESET} .deb package (provide URL)"
    echo -e "  ${BOLD}b)${RESET} Back"
    sep
    read -rp "  Choice: " choice

    local installed=0
    case "$choice" in
        1)
            local pkg_mgr; pkg_mgr=$(_ensure_pkg_mgr) || return
            "$pkg_mgr" install -g @anthropic-ai/claude-code \
                && ok "Installed via ${pkg_mgr}." && installed=1 \
                || err "Install failed."
            ;;
        2)
            read -rp "  .deb URL: " deb_url
            [[ -n "$deb_url" ]] || { warn "No URL given."; return; }
            local deb="/tmp/claude-code-install.deb"
            info "Downloading…"
            curl -fL "$deb_url" -o "$deb" || { err "Download failed."; return; }
            sudo dpkg -i "$deb" && rm -f "$deb" && ok "Installed." && installed=1
            ;;
        b|B) return ;;
        *) warn "Unknown option."; return ;;
    esac

    if [[ "$installed" -eq 1 ]] && cc_installed; then
        _ensure_rc_json
        _ensure_linger
        echo
        info "Installed: $(cc_version)"
        info "Authenticate before creating instances: run 'claude' once interactively,"
        info "or attach to a started instance and follow the login prompt there."
    fi
}

# ── entry point ───────────────────────────────────────────────────────────────
_open_dir() {
    local dir; dir=$(realpath "${1:-.}" 2>/dev/null) || dir="${1:-.}"
    local existing; existing=$(_slug_for_dir "$dir")
    if [[ -n "$existing" ]]; then
        instance_menu "$existing"
    else
        new_instance_wizard "$dir"
    fi
}

case "${1:-}" in
    new)    new_instance_wizard "${2:-$PWD}" ;;
    "")
        if [[ "$PWD" != "$HOME" ]]; then
            existing=$(_slug_for_dir "$PWD")
            [[ -n "$existing" ]] && { instance_menu "$existing"; exit 0; }
        fi
        main_menu
        ;;
    *)
        if [[ -d "$1" ]]; then
            _open_dir "$1"
        else
            echo "Usage: $0 [path]  — open manager (or go straight to new/existing instance in path)"
            echo "       $0 new [path]"
            exit 1
        fi
        ;;
esac
