#!/usr/bin/env bash
# Machine profile resolution.
#
# The profile lives OUTSIDE the repo, at ~/.config/dotfiles/config, so the
# repository itself never learns which client a machine belongs to.
#
# Format (parsed, never sourced — a config file must not be able to run code):
#
#   profile=work
#   slug=acme
#   provider=bitwarden
#   item=dotfiles-overlay

# shellcheck disable=SC2034  # consumed by install.sh and lib/overlay.sh
DOTFILES_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles"
DOTFILES_CONFIG_FILE="$DOTFILES_CONFIG_DIR/config"

DOTFILES_PROFILE=""
DOTFILES_SLUG=""
DOTFILES_PROVIDER=""
DOTFILES_ACCOUNT=""
DOTFILES_VAULT=""
DOTFILES_ITEM=""
DOTFILES_LOCAL=""

# Read the config file into the DOTFILES_* variables. Returns 1 if absent.
profile_load() {
    [[ -f "$DOTFILES_CONFIG_FILE" ]] || return 1

    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == \#* || -z "${line// /}" ]] && continue
        [[ "$line" != *=* ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            profile) DOTFILES_PROFILE="$value" ;;
            slug) DOTFILES_SLUG="$value" ;;
            provider) DOTFILES_PROVIDER="$value" ;;
            account) DOTFILES_ACCOUNT="$value" ;;
            vault) DOTFILES_VAULT="$value" ;;
            item) DOTFILES_ITEM="$value" ;;
            *) ;; # unknown key: ignore rather than fail
        esac
    done <"$DOTFILES_CONFIG_FILE"

    profile_derive
}

# Derive values that are never stored, only computed.
profile_derive() {
    if [[ "$DOTFILES_PROFILE" == "work" && -n "$DOTFILES_SLUG" ]]; then
        DOTFILES_LOCAL="$HOME/.dotfiles-local/$DOTFILES_SLUG"
    else
        DOTFILES_LOCAL=""
    fi
    [[ "$DOTFILES_PROVIDER" == "bitwarden" && -z "$DOTFILES_ITEM" ]] && DOTFILES_ITEM="dotfiles-overlay"
    return 0
}

profile_save() {
    mkdir -p "$DOTFILES_CONFIG_DIR"
    {
        echo "# Written by install.sh. Machine-local: never commit this file."
        echo "profile=$DOTFILES_PROFILE"
        [[ -n "$DOTFILES_SLUG" ]] && echo "slug=$DOTFILES_SLUG"
        [[ -n "$DOTFILES_PROVIDER" ]] && echo "provider=$DOTFILES_PROVIDER"
        [[ -n "$DOTFILES_ACCOUNT" ]] && echo "account=$DOTFILES_ACCOUNT"
        [[ -n "$DOTFILES_VAULT" ]] && echo "vault=$DOTFILES_VAULT"
        [[ -n "$DOTFILES_ITEM" ]] && echo "item=$DOTFILES_ITEM"
    } >"$DOTFILES_CONFIG_FILE"
    chmod 600 "$DOTFILES_CONFIG_FILE"
    profile_derive
    ok "Profile saved to $DOTFILES_CONFIG_FILE"
}

# Fail loudly on a configuration that would produce a wrong-identity commit.
profile_validate() {
    case "$DOTFILES_PROFILE" in
        personal | work) ;;
        *) die "profile must be 'personal' or 'work' (got: '${DOTFILES_PROFILE:-empty}')" ;;
    esac

    case "$DOTFILES_PROVIDER" in
        onepassword | bitwarden) ;;
        *) die "provider must be 'onepassword' or 'bitwarden' (got: '${DOTFILES_PROVIDER:-empty}')" ;;
    esac

    if [[ "$DOTFILES_PROFILE" == "work" ]]; then
        [[ -n "$DOTFILES_SLUG" ]] || die "a work profile needs --slug (short client name, used only locally)"
        [[ "$DOTFILES_SLUG" =~ ^[a-z0-9-]+$ ]] || die "--slug must be lowercase letters, digits and dashes"
    fi

    if [[ "$DOTFILES_PROVIDER" == "onepassword" ]]; then
        [[ -n "$DOTFILES_ACCOUNT" ]] || die "1Password needs --account (e.g. my.1password.com)"
        [[ "$DOTFILES_PROFILE" == "work" && -z "$DOTFILES_VAULT" ]] && die "a 1Password work profile needs --vault"
    fi

    return 0
}

# First-run interactive setup. Only asks what was not supplied on the CLI.
profile_prompt() {
    info "No machine profile found. Let's set one up."
    echo

    if [[ -z "$DOTFILES_PROFILE" ]]; then
        printf 'Is this a [p]ersonal machine or a [w]ork machine? [p/w] '
        read -r reply
        case "$reply" in
            w | W | work) DOTFILES_PROFILE="work" ;;
            *) DOTFILES_PROFILE="personal" ;;
        esac
    fi

    if [[ "$DOTFILES_PROFILE" == "work" && -z "$DOTFILES_SLUG" ]]; then
        printf 'Short slug for this client (lowercase, e.g. acme): '
        read -r DOTFILES_SLUG
    fi

    if [[ -z "$DOTFILES_PROVIDER" ]]; then
        printf 'Password manager — [1]Password or [b]itwarden? [1/b] '
        read -r reply
        case "$reply" in
            b | B | bitwarden | bw) DOTFILES_PROVIDER="bitwarden" ;;
            *) DOTFILES_PROVIDER="onepassword" ;;
        esac
    fi

    if [[ "$DOTFILES_PROVIDER" == "onepassword" ]]; then
        [[ -z "$DOTFILES_ACCOUNT" ]] && {
            printf '1Password account sign-in address (e.g. my.1password.com): '
            read -r DOTFILES_ACCOUNT
        }
        if [[ "$DOTFILES_PROFILE" == "work" && -z "$DOTFILES_VAULT" ]]; then
            printf '1Password vault holding this client'"'"'s dotfiles-overlay item: '
            read -r DOTFILES_VAULT
        fi
    else
        [[ -z "$DOTFILES_ITEM" ]] && {
            printf 'Bitwarden item name [dotfiles-overlay]: '
            read -r DOTFILES_ITEM
            [[ -z "$DOTFILES_ITEM" ]] && DOTFILES_ITEM="dotfiles-overlay"
        }
    fi

    echo
    profile_validate
    profile_save
}
