#!/usr/bin/env bash
# shellcheck disable=SC2088  # tildes in log strings are display text
# Claude Code settings.
#
# Claude Code loads settings user -> project -> local, with no user-level local
# override, so symlinking ~/.claude/settings.json would share EVERY key -
# including the permission posture. Instead the file is generated from three
# layers, each one winning over the one above it:
#
#   claude/settings.base.json                    tracked, every machine
#   claude/settings.personal.json                tracked, personal machines only
#   ~/.config/dotfiles/claude-settings.json      untracked, this machine only
#
# The personal layer exists because a client machine runs that client's
# workflow, not ours. A hook pointing at a tool a work machine never installs
# would fail on every single prompt, silently.

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CLAUDE_LOCAL_SETTINGS="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/claude-settings.json"
CLAUDE_STAMP="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/.claude-settings.sha"

# The layers that apply to this machine, in merge order. Echoes one path a line.
claude_layers() {
    printf '%s\n' "$DOTFILES_DIR/claude/settings.base.json"
    [[ "$DOTFILES_PROFILE" == "personal" && -f "$DOTFILES_DIR/claude/settings.personal.json" ]] &&
        printf '%s\n' "$DOTFILES_DIR/claude/settings.personal.json"
    printf '%s\n' "$CLAUDE_LOCAL_SETTINGS"
}

# Merge every layer and point statusLine at wherever this repo actually lives.
claude_merge() {
    local -a layers=()
    while IFS= read -r line; do layers+=("$line"); done < <(claude_layers)
    jq -s --arg dir "$DOTFILES_DIR" '
        reduce .[] as $l ({}; . * $l)
        | if .statusLine then .statusLine.command = ($dir + "/claude/statusline.sh") else . end
    ' "${layers[@]}" 2>/dev/null
}

claude_settings_apply() {
    [[ -f "$DOTFILES_DIR/claude/settings.base.json" ]] || return 0

    if ! has jq; then
        warn "jq not installed; leaving ~/.claude/settings.json alone"
        return 0
    fi

    mkdir -p "$(dirname "$CLAUDE_SETTINGS")" "$(dirname "$CLAUDE_LOCAL_SETTINGS")"
    [[ -f "$CLAUDE_LOCAL_SETTINGS" ]] || echo '{}' >"$CLAUDE_LOCAL_SETTINGS"

    # Claude Code edits this file itself (/config, permission dialogs). If it
    # changed since we last wrote it, those edits would be silently discarded -
    # so name them and keep a copy instead.
    if [[ -f "$CLAUDE_SETTINGS" && -f "$CLAUDE_STAMP" ]]; then
        local now
        now="$(shasum -a 256 "$CLAUDE_SETTINGS" | awk '{print $1}')"
        if [[ "$now" != "$(cat "$CLAUDE_STAMP")" ]]; then
            claude_report_drift
        fi
    fi

    local merged
    merged="$(claude_merge)" || {
        err "could not merge Claude settings; leaving the existing file alone"
        return 0
    }
    [[ -n "$merged" ]] || {
        err "could not merge Claude settings; leaving the existing file alone"
        return 0
    }

    printf '%s\n' "$merged" >"$CLAUDE_SETTINGS"
    shasum -a 256 "$CLAUDE_SETTINGS" | awk '{print $1}' >"$CLAUDE_STAMP"
    ok "~/.claude/settings.json (shared base + this machine's overrides)"
}

# Show which keys drifted, so a /config change is not lost without a word.
claude_report_drift() {
    local backup
    backup="$DOTFILES_BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-claude-settings.json"
    mkdir -p "$DOTFILES_BACKUP_ROOT"
    cp "$CLAUDE_SETTINGS" "$backup"

    local expected drifted
    expected="$(claude_merge)"
    [[ -n "$expected" ]] || expected='{}'
    drifted="$(jq -r --argjson e "$expected" '
        to_entries
        | map(select(.value != ($e[.key])))
        | map(.key) | join(", ")
    ' "$CLAUDE_SETTINGS" 2>/dev/null || true)"

    warn "~/.claude/settings.json changed outside these dotfiles"
    [[ -n "$drifted" ]] && echo "         keys that differ: $drifted"
    echo "         a copy is at ${backup/#$HOME/~}"
    echo "         keep any you want by moving them into:"
    echo "           ${CLAUDE_LOCAL_SETTINGS/#$HOME/~}   (this machine only)"
    echo "           claude/settings.personal.json              (personal machines)"
    echo "           claude/settings.base.json                  (every machine)"
}
