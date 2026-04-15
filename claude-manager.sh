#!/usr/bin/env bash
# claud-manager.sh — Claude Code instance manager

set -uo pipefail

# ── paths ─────────────────────────────────────────────────────────────────────
SYSTEMD_DIR="${HOME}/.config/systemd/user"
CLAUDE_BIN="${HOME}/.local/bin/claude"
CLAUDE_JSON="${HOME}/.claude.json"
WATCHDOG_LOG_DIR="${HOME}/.local/share/claude-watchdog"
WATCHDOG_BIN_DIR="${HOME}/.local/bin"
PNPM_HOME="${HOME}/.local/share/pnpm"
SVC_PATH_ENV="PATH=${PNPM_HOME}:${HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
HANG_TIMEOUT=600

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

# ── main menu ─────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        hdr "Claude Code Manager"

        # CC status
        if cc_installed; then
            echo -e "  CC: ${GREEN}$(cc_version)${RESET}"
        else
            echo -e "  CC: ${RED}not installed${RESET}"
        fi
        # Linger
        [[ -f "/var/lib/systemd/linger/${USER}" ]] \
            && echo -e "  Linger: ${GREEN}enabled${RESET}" \
            || echo -e "  Linger: ${YELLOW}disabled${RESET}  (run: loginctl enable-linger $USER)"
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
        echo -e "  ${BOLD}i)${RESET} Install / update Claude Code"
        echo -e "  ${BOLD}q)${RESET} Quit"
        sep
        read -rp "  Choice: " choice

        case "$choice" in
            q|Q) echo; ok "Bye."; echo; exit 0 ;;
            n|N) new_instance_wizard ;;
            m|M) mcp_menu ;;
            i|I) install_cc_menu ;;
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

    mkdir -p "$WATCHDOG_LOG_DIR"

    cat > "$script" <<WEOF
#!/bin/bash
LOG="${wlog}"
HANG_TIMEOUT=${HANG_TIMEOUT}

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log_ok() {
    if [ -s "\$LOG" ] && tail -1 "\$LOG" | grep -q "\] ok\$"; then
        local tmp=\$(mktemp); head -n -1 "\$LOG" > "\$tmp" && mv "\$tmp" "\$LOG"
    fi
    echo "[\$(timestamp)] ok" >> "\$LOG"
}

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

# The stopwatch "(Xh Xm Xs · ↓ N tokens)" only appears during active tool calls.
# When Claude is waiting for user input there is no stopwatch — idle sessions are never restarted.
TIME_STR=\$(echo "\$PANE_CONTENT" | grep -oE '([0-9]+h )?([0-9]+m )?[0-9]+s ·' | head -1 | sed 's/ ·\$//')

if [ -z "\$TIME_STR" ]; then
    log_ok; exit 0
fi

ELAPSED_SECS=\$(echo "\$TIME_STR" | awk '{
    t=0
    for(i=1;i<=NF;i++){
        if(\$i~/h\$/) t+=int(\$i)*3600
        else if(\$i~/m\$/) t+=int(\$i)*60
        else if(\$i~/s\$/) t+=int(\$i)
    }
    print t
}')

if [ "\$ELAPSED_SECS" -ge "\$HANG_TIMEOUT" ]; then
    echo "[\$(timestamp)] INTERVENED: tool call running for \${ELAPSED_SECS}s (>=\${HANG_TIMEOUT}s), restarting claude-${slug}" | tee -a "\$LOG"
    systemctl --user restart claude-${slug}
else
    echo "[\$(timestamp)] tool call running for \${ELAPSED_SECS}s, waiting..." >> "\$LOG"
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
OnBootSec=2min
OnUnitActiveSec=2min
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
    rm -f "${WATCHDOG_LOG_DIR}/${slug}.log" "${WATCHDOG_LOG_DIR}/${slug}.state" "${WATCHDOG_LOG_DIR}/${slug}.hang"
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
    hdr "Install / Update Claude Code"

    if cc_installed; then
        ok "Installed: $(cc_version)"
        read -rp "  Re-install / update? [y/N] " ans
        [[ "${ans,,}" == "y" ]] || return
    fi

    echo
    echo -e "  Install methods:"
    echo -e "  ${BOLD}1)${RESET} npm  (npm install -g @anthropic-ai/claude-code)"
    echo -e "  ${BOLD}2)${RESET} .deb (provide URL)"
    echo -e "  ${BOLD}b)${RESET} Back"
    sep
    read -rp "  Choice: " choice

    case "$choice" in
        1)
            if command -v npm &>/dev/null; then
                npm install -g @anthropic-ai/claude-code && ok "Installed via npm."
            else
                err "npm not found. Install Node.js first."
            fi
            ;;
        2)
            read -rp "  .deb URL: " deb_url
            [[ -n "$deb_url" ]] || { warn "No URL given."; return; }
            local deb="/tmp/claude-code-install.deb"
            info "Downloading…"
            curl -fL "$deb_url" -o "$deb" || { err "Download failed."; return; }
            sudo dpkg -i "$deb" && rm -f "$deb" && ok "Installed."
            ;;
        b|B) return ;;
        *) warn "Unknown option." ;;
    esac

    if cc_installed; then
        _ensure_rc_json
        # Ensure linger
        if [[ ! -f "/var/lib/systemd/linger/${USER}" ]]; then
            read -rp "  Enable linger (keep services alive after logout)? [Y/n] " ans
            [[ "${ans,,}" == "n" ]] || { loginctl enable-linger "$USER" && ok "Linger enabled."; }
        fi
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
