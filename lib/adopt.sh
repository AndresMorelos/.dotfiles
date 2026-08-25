#!/usr/bin/env bash
# shellcheck disable=SC2088  # tildes in log strings are display text
# Guided adoption of a machine that was already set up by hand.
#
# Rather than interrogating the user for things the machine already knows,
# read the existing state, propose it, and let them correct it.

# Everything git currently resolves, wherever it comes from.
adopt_detect_git() {
    ADOPT_EMAIL="$(git config user.email 2>/dev/null || true)"
    ADOPT_NAME="$(git config user.name 2>/dev/null || true)"
    ADOPT_SIGNKEY="$(git config user.signingkey 2>/dev/null || true)"

    # A previous run may have displaced the original; it is still in the backup.
    if [[ -z "$ADOPT_EMAIL" ]]; then
        local candidate
        candidate="$(find "$DOTFILES_BACKUP_ROOT" -name '.gitconfig' -type f 2>/dev/null | sort | tail -1)"
        if [[ -n "$candidate" ]]; then
            ADOPT_EMAIL="$(git config --file "$candidate" user.email 2>/dev/null || true)"
            ADOPT_NAME="$(git config --file "$candidate" user.name 2>/dev/null || true)"
            ADOPT_SIGNKEY="$(git config --file "$candidate" user.signingkey 2>/dev/null || true)"
            [[ -n "$ADOPT_EMAIL" ]] && warn "recovered identity from ${candidate/#$HOME/~}"
        fi
    fi
}

# Which password managers are actually on this machine?
adopt_detect_provider() {
    local -a found=()
    [[ -d /Applications/1Password.app ]] || command -v op >/dev/null 2>&1 && found+=("onepassword")
    [[ -d /Applications/Bitwarden.app ]] || command -v bw >/dev/null 2>&1 && found+=("bitwarden")

    case ${#found[@]} in
        1) ADOPT_PROVIDER="${found[0]}" ;;
        *) ADOPT_PROVIDER="" ;;
    esac
}

# The point of the whole exercise: if git already signs with some key, find
# that same key in the vault instead of pinning a different one or minting a
# second key the user would have to register everywhere again.
adopt_match_signing_key() {
    [[ -n "$ADOPT_SIGNKEY" ]] || return 1

    local line vault item pub
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        vault="${line%%$'\t'*}"
        item="${line#*$'\t'}"
        pub="$(provider_pubkey "$item" "$vault" 2>/dev/null || true)"
        # Compare only the key body: comments and trailing space differ freely.
        if [[ -n "$pub" ]] && [[ "$(awk '{print $2}' <<<"$pub")" == "$(awk '{print $2}' <<<"$ADOPT_SIGNKEY")" ]]; then
            DOTFILES_KEY_VAULT="$vault"
            DOTFILES_KEY_ITEM="$item"
            ok "Matched your current signing key to: $item  [vault: $vault]"
            return 0
        fi
    done < <(provider_list_keys 2>/dev/null)

    warn "your current signing key is not in the vault; it cannot be used by the agent"
    return 1
}

# Packages installed on this machine that no Brewfile knows about.
adopt_scan_packages() {
    has brew || return 0

    local declared
    declared="$(cat "$DOTFILES_DIR"/Brewfile* "$DOTFILES_DIR"/profiles/*/Brewfile 2>/dev/null |
        rg -o '^(brew|cask) "([^"]+)"' -r '$2' | sort -u)"

    ADOPT_EXTRA_FORMULAE="$(comm -23 \
        <(brew leaves --installed-on-request 2>/dev/null | sort -u) \
        <(printf '%s\n' "$declared") 2>/dev/null || true)"

    ADOPT_EXTRA_CASKS="$(comm -23 \
        <(brew list --cask 2>/dev/null | sort -u) \
        <(printf '%s\n' "$declared") 2>/dev/null || true)"
}

adopt_report_packages() {
    local n_f n_c
    n_f="$(printf '%s' "$ADOPT_EXTRA_FORMULAE" | rg -c . || echo 0)"
    n_c="$(printf '%s' "$ADOPT_EXTRA_CASKS" | rg -c . || echo 0)"

    if [[ "$n_f" == "0" && "$n_c" == "0" ]]; then
        ok "every installed package is already declared"
        return 0
    fi

    info "Installed here but not in any Brewfile:"
    [[ "$n_c" != "0" ]] && printf '%s\n' "$ADOPT_EXTRA_CASKS" | sed 's/^/     cask   /'
    [[ "$n_f" != "0" ]] && printf '%s\n' "$ADOPT_EXTRA_FORMULAE" | sed 's/^/     brew   /'
    echo
    echo "   These survive on THIS machine but will not appear on a new one."
    echo "   Capture them with:  ./install.sh --dump   then move the lines you"
    echo "   want into the right Brewfile."
    return 0
}

# ----------------------------------------------------------------- entrypoint

cmd_adopt() {
    banner
    info "Reading what this machine already has..."
    echo

    adopt_detect_git
    adopt_detect_provider

    # --- identity -----------------------------------------------------------
    info "Git identity"
    if [[ -n "$ADOPT_EMAIL" ]]; then
        echo "   email       $ADOPT_EMAIL"
        echo "   name        ${ADOPT_NAME:-(unset)}"
        echo "   signingkey  ${ADOPT_SIGNKEY:0:40}${ADOPT_SIGNKEY:+...}"
        local repo_email
        repo_email="$(git config --file "$DOTFILES_DIR/profiles/personal/gitconfig" user.email || true)"
        if [[ "$ADOPT_EMAIL" != "$repo_email" ]]; then
            warn "profiles/personal/gitconfig says $repo_email"
            printf '   Update the repo to use %s instead? [y/N] ' "$ADOPT_EMAIL"
            local reply
            read -r reply || reply=n
            if [[ "$reply" == "y" || "$reply" == "Y" ]]; then
                git config --file "$DOTFILES_DIR/profiles/personal/gitconfig" user.email "$ADOPT_EMAIL"
                [[ -n "$ADOPT_NAME" ]] &&
                    git config --file "$DOTFILES_DIR/profiles/personal/gitconfig" user.name "$ADOPT_NAME"
                ok "profiles/personal/gitconfig updated"
            fi
        else
            ok "matches profiles/personal/gitconfig"
        fi
    else
        warn "no git identity configured yet"
    fi
    echo

    # --- profile ------------------------------------------------------------
    info "Machine profile"
    if profile_load; then
        ok "already configured: profile=$DOTFILES_PROFILE provider=$DOTFILES_PROVIDER"
    else
        [[ -z "$DOTFILES_PROVIDER" && -n "$ADOPT_PROVIDER" ]] && {
            DOTFILES_PROVIDER="$ADOPT_PROVIDER"
            ok "detected password manager: $ADOPT_PROVIDER"
        }
        profile_prompt
    fi
    echo

    # --- signing key --------------------------------------------------------
    info "Signing key"
    overlay_source_provider
    if provider_require 2>/dev/null && provider_ready 2>/dev/null; then
        if [[ -n "$DOTFILES_KEY_ITEM" ]]; then
            ok "already pinned: $DOTFILES_KEY_ITEM  [vault: $DOTFILES_KEY_VAULT]"
        elif adopt_match_signing_key; then
            profile_save >/dev/null
        else
            warn "will be resolved on the next --sync-overlay"
        fi
    else
        warn "$DOTFILES_PROVIDER is not reachable yet; skipping key detection"
    fi
    echo

    # --- packages -----------------------------------------------------------
    info "Packages"
    adopt_scan_packages
    adopt_report_packages
    echo

    ok "Adoption scan complete."
    echo "   Next:  ./install.sh          to install and link everything"
    echo "          ./install.sh --doctor to re-check at any time"
}
