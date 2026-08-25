#!/usr/bin/env bash
#
# Application-level iTerm2 preferences.
#
# Everything that belongs to a *profile* lives in iterm/profile.json, which
# iTerm reads live as a Dynamic Profile. The settings below are global to the
# app, have no profile equivalent, and can only be written through `defaults`.
#
# The plist itself is deliberately NOT tracked: it is binary, iTerm rewrites it
# on every window move, and it carries machine state that must never reach a
# neutral repo.

ITERM_DOMAIN="com.googlecode.iterm2"

# Must match the Guid in iterm/profile.json. Checked at apply time rather
# than trusted, because a mismatch silently leaves the profile unused.
ITERM_PROFILE_GUID="dotfiles-dev-profile"

# pgrep is no use here: macOS reports an app bundle's `comm` as a full path, so
# `pgrep -x iTerm2` never matches, and the main process refuses to hand over its
# argv, so `pgrep -f` misses it too. Scan `ps` output and match the path instead.
iterm_is_running() {
    local proc
    while IFS= read -r proc; do
        [[ "$proc" == */iTerm.app/Contents/MacOS/iTerm2 ]] && return 0
    done < <(ps -Ao comm=)
    return 1
}

# iTerm holds its preferences in memory and flushes them on quit, so anything
# written while it is running is overwritten the moment it exits. Refuse to
# write rather than report a success that will not survive.
iterm_defaults_guard() {
    iterm_is_running || return 0
    warn "iTerm2 is running; its app settings were left untouched"
    echo "         quit iTerm2 completely, then run: ./install.sh --link"
    echo "         (the profile itself is already linked and needs no restart)"
    return 1
}

# The GUID is written in two places by necessity: iTerm reads it from the
# JSON, `defaults` needs it as a plain string. Catch them drifting apart.
iterm_guid_check() {
    local json="$DOTFILES_DIR/iterm/profile.json" declared
    [[ -f "$json" ]] || return 0
    command -v jq >/dev/null || return 0

    declared="$(jq -r '.Profiles[0].Guid // empty' "$json" 2>/dev/null)"
    [[ "$declared" == "$ITERM_PROFILE_GUID" ]] && return 0

    err "iterm/profile.json declares Guid '${declared:-none}', expected '$ITERM_PROFILE_GUID'"
    echo "         the profile would be installed but never used; fix one of the two"
    return 1
}

iterm_defaults_apply() {
    info "Configuring iTerm2..."

    iterm_guid_check || return 0

    if ! iterm_defaults_guard; then
        return 0
    fi

    local -a bools=(
        # Appearance
        "HideScrollbar true"             # the scrollback is unlimited; a bar is noise
        "UseBorder false"
        "DimInactiveSplitPanes true"     # makes the focused pane obvious at a glance
        "HideTabNumber true"
        "HideTabCloseButton true"
        "ShowFullScreenTabBar true"

        # Behaviour
        "PromptOnQuit false"
        "QuitWhenAllWindowsClosed false"
        "OnlyWhenMoreTabs false"         # never prompt when closing a single tab
        "AlternateMouseScroll true"      # scroll wheel drives less/man/vim
        "FocusFollowsMouse false"
        "SUEnableAutomaticChecks true"

        # Copy/paste
        "CopySelection true"
        "CopyWithStylesByDefault false"  # paste code, not colours
        "AllowClipboardAccess true"

        # Keep history intact when a program clears the screen
        "PreventEscapeSequenceFromClearingHistory true"
    )

    local entry key value
    for entry in "${bools[@]}"; do
        read -r key value <<<"$entry"
        defaults write "$ITERM_DOMAIN" "$key" -bool "$value"
    done

    # 5 = minimal tab style: no chrome competing with the prompt.
    defaults write "$ITERM_DOMAIN" TabStyleWithAutomaticOption -int 5
    # 0 = tabs on top.
    defaults write "$ITERM_DOMAIN" TabViewType -int 0

    # Make the tracked profile the one new windows open with. Without this the
    # profile is present but never used, which looks like nothing happened.
    defaults write "$ITERM_DOMAIN" "Default Bookmark Guid" -string "$ITERM_PROFILE_GUID"

    ok "iTerm2 configured"
}
