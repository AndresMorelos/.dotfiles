#!/usr/bin/env bash
# shellcheck disable=SC2088  # tildes in log strings are display text
# Claude Code settings.
#
# Claude Code loads settings user -> project -> local, with no user-level local
# override, so symlinking ~/.claude/settings.json would share EVERY key -
# including the permission posture. Instead the file is generated:
#
#   claude/settings.base.json                    tracked, shared by every machine
#   ~/.config/dotfiles/claude-settings.json      untracked, this machine only
#
# The local file wins on any key it defines.

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CLAUDE_LOCAL_SETTINGS="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/claude-settings.json"
CLAUDE_STAMP="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/.claude-settings.sha"

claude_settings_apply() {
    local base="$DOTFILES_DIR/claude/settings.base.json"
    [[ -f "$base" ]] || return 0

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
    merged="$(
        jq -s --arg dir "$DOTFILES_DIR" '
            (.[0] * .[1])
            | if .statusLine then .statusLine.command = ($dir + "/claude/statusline.sh") else . end
        ' "$base" "$CLAUDE_LOCAL_SETTINGS" 2>/dev/null
    )" || {
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
    # Apply the same statusLine rewrite the generator does, or the placeholder
    # in the base would show up as drift on every single run.
    expected="$(jq -s --arg dir "$DOTFILES_DIR" '
        (.[0] * .[1])
        | if .statusLine then .statusLine.command = ($dir + "/claude/statusline.sh") else . end
    ' "$DOTFILES_DIR/claude/settings.base.json" "$CLAUDE_LOCAL_SETTINGS" 2>/dev/null || echo '{}')"
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
    echo "           claude/settings.base.json                  (every machine)"
}
