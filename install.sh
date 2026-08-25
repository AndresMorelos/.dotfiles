#!/usr/bin/env bash
#
# Masteorion dotfiles installer.
#
# The repository is neutral: it is identical on every machine and contains no
# client name, work email or vault name. Per-job configuration is pulled from
# that job's own vault at install time. See README.md.

set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DOTFILES_DIR

# shellcheck source=lib/log.sh
source "$DOTFILES_DIR/lib/log.sh"
# shellcheck source=lib/profile.sh
source "$DOTFILES_DIR/lib/profile.sh"
# shellcheck source=lib/links.sh
source "$DOTFILES_DIR/lib/links.sh"
# shellcheck source=lib/overlay.sh
source "$DOTFILES_DIR/lib/overlay.sh"

ALL_GROUPS=(dev homeservices productivity security macos streaming)

ACTION="bootstrap"
declare -a SELECTED_GROUPS=()
declare -a SKIP_GROUPS=()

print_help() {
    cat <<EOF
Usage: ./install.sh [COMMAND] [OPTIONS]

Commands (default: full bootstrap):
  --link                    Relink dotfiles only. Fast, no network.
  --update                  Pull, relink, re-sync overlay, update packages.
  --sync-overlay            Re-fetch this machine's overlay from its vault.
  --purge-overlay           Remove all machine-local config. For handing a laptop back.
  --show-signing-key        Print the active signing key and where to register it.
  --doctor                  Report profile, links, packages, and neutrality.
  --dump                    Write current Homebrew state to Brewfile.new.
  --help, -h                Show this message.

Profile options (persisted to ~/.config/dotfiles/config, never committed):
  --profile personal|work
  --slug NAME               Short client name. Local only. Work profiles only.
  --provider onepassword|bitwarden
  --account ADDRESS         1Password sign-in address, e.g. my.1password.com
  --vault NAME              1Password vault holding the overlay
  --item NAME               Bitwarden item name (default: dotfiles-overlay)

Package options:
  --packages GROUPS         Comma-separated groups to install
  --skip-packages GROUPS    Comma-separated groups to skip

Package groups:
  dev           cursor, iterm2, cleanshot, slack, tableplus, orbstack, ...
  homeservices  vnc-viewer
  productivity  numi, raycast, rectangle, browserino
  security      knockknock, oversight
  macos         monitorcontrol, istat-menus
  streaming     spotify

Examples:
  ./install.sh
      Full setup. Prompts for profile and password manager on first run.

  ./install.sh --profile work --slug acme --provider bitwarden
      Set up a client machine backed by Bitwarden.

  ./install.sh --packages dev,macos
      Only install the dev and macos groups.

  ./install.sh --update
      Bring an existing machine up to date.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help | -h)
                print_help
                exit 0
                ;;
            --link) ACTION="link" ;;
            --update) ACTION="update" ;;
            --sync-overlay) ACTION="sync" ;;
            --purge-overlay) ACTION="purge" ;;
            --show-signing-key) ACTION="showkey" ;;
            --doctor) ACTION="doctor" ;;
            --dump) ACTION="dump" ;;
            --profile)
                DOTFILES_PROFILE="${2:?--profile needs a value}"
                shift
                ;;
            --slug)
                DOTFILES_SLUG="${2:?--slug needs a value}"
                shift
                ;;
            --provider)
                DOTFILES_PROVIDER="${2:?--provider needs a value}"
                shift
                ;;
            --account)
                DOTFILES_ACCOUNT="${2:?--account needs a value}"
                shift
                ;;
            --vault)
                DOTFILES_VAULT="${2:?--vault needs a value}"
                shift
                ;;
            --item)
                DOTFILES_ITEM="${2:?--item needs a value}"
                shift
                ;;
            --packages)
                IFS=',' read -ra SELECTED_GROUPS <<<"${2:?--packages needs a value}"
                shift
                ;;
            --skip-packages)
                IFS=',' read -ra SKIP_GROUPS <<<"${2:?--skip-packages needs a value}"
                shift
                ;;
            *) die "unknown option: $1  (try --help)" ;;
        esac
        shift
    done

    # Fail on a typo'd group name now, not silently at package time.
    local g
    for g in "${SELECTED_GROUPS[@]:-}" "${SKIP_GROUPS[@]:-}"; do
        [[ -z "$g" ]] && continue
        _is_group "$g" || die "unknown package group: '$g'  (see --help)"
    done
}

# ------------------------------------------------------------------ toolchain

has() { command -v "$1" >/dev/null 2>&1; }

ensure_curl() {
    has curl || die "curl is required but not installed."
}

install_xcode_clt() {
    info "Checking Xcode Command Line Tools..."
    if xcode-select -p &>/dev/null; then
        ok "already installed"
        return 0
    fi
    step "Installing Xcode Command Line Tools..."
    xcode-select --install || true
    until xcode-select -p &>/dev/null; do sleep 5; done
    ok "installed"
}

ensure_git() {
    has git && return 0
    step "git not found; installing Command Line Tools..."
    install_xcode_clt
    has git || {
        install_brew
        brew install git
    }
}

install_brew() {
    info "Checking Homebrew..."
    if has brew; then
        ok "already installed"
        return 0
    fi
    step "Installing Homebrew..."
    NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" >/dev/null ||
        die "Homebrew installation failed"
    [[ -d /opt/homebrew/bin ]] && export PATH="/opt/homebrew/bin:$PATH"
    [[ -d /usr/local/bin ]] && export PATH="/usr/local/bin:$PATH"
    ok "installed"
}

# ------------------------------------------------------------------- packages

resolve_groups() {
    local -a resolved=()
    local g

    if [[ ${#SELECTED_GROUPS[@]} -gt 0 ]]; then
        resolved=("${SELECTED_GROUPS[@]}")
    else
        for g in "${ALL_GROUPS[@]}"; do
            _in_list "$g" "${SKIP_GROUPS[@]:-}" && continue
            resolved+=("$g")
        done
    fi
    printf '%s\n' "${resolved[@]:-}"
}

_is_group() { _in_list "$1" "${ALL_GROUPS[@]}"; }

_in_list() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# Every Brewfile that applies to this machine, in application order.
active_brewfiles() {
    local -a files=("$DOTFILES_DIR/Brewfile" "$DOTFILES_DIR/Brewfile.fonts")
    local g

    while IFS= read -r g; do
        [[ -z "$g" ]] && continue
        files+=("$DOTFILES_DIR/Brewfile.$g")
    done < <(resolve_groups)

    [[ -n "$DOTFILES_PROVIDER" ]] &&
        files+=("$DOTFILES_DIR/Brewfile.provider.$DOTFILES_PROVIDER")

    [[ "$DOTFILES_PROFILE" == "personal" ]] &&
        files+=("$DOTFILES_DIR/profiles/personal/Brewfile")

    [[ -n "$DOTFILES_LOCAL" && -f "$DOTFILES_LOCAL/Brewfile" ]] &&
        files+=("$DOTFILES_LOCAL/Brewfile")

    local f
    for f in "${files[@]}"; do
        [[ -f "$f" ]] && printf '%s\n' "$f"
    done
}

install_brew_packages() {
    info "Installing packages with brew bundle..."
    brew update >/dev/null 2>&1 || warn "brew update failed; continuing with the local index"

    local f
    while IFS= read -r f; do
        step "  ${f#"$DOTFILES_DIR"/}"
        brew bundle install --file="$f" --no-lock >/dev/null ||
            warn "some packages in ${f##*/} failed"
    done < <(active_brewfiles)
    ok "packages installed"
}

cleanup_brew() {
    info "Cleaning up Homebrew..."
    brew cleanup >/dev/null 2>&1 || true
    brew autoremove >/dev/null 2>&1 || true
    ok "done"
}

# ----------------------------------------------------------------------- zsh

install_oh_my_zsh() {
    info "Checking Oh My Zsh..."
    if [[ -d "$HOME/.oh-my-zsh" ]]; then
        ok "already installed"
        return 0
    fi
    step "Installing Oh My Zsh..."
    RUNZSH=no KEEP_ZSHRC=yes sh -c \
        "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
        "" --unattended >/dev/null ||
        die "Oh My Zsh installation failed"
    ok "installed"
}

install_oh_my_zsh_plugins() {
    info "Checking Oh My Zsh plugins..."
    local custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
    local dir="$custom/plugins/zsh-npm-scripts-autocomplete"
    if [[ -d "$dir" ]]; then
        ok "zsh-npm-scripts-autocomplete already installed"
        return 0
    fi
    step "Cloning zsh-npm-scripts-autocomplete..."
    git clone --depth 1 https://github.com/grigorii-zander/zsh-npm-scripts-autocomplete.git \
        "$dir" >/dev/null 2>&1 || warn "clone failed"
    ok "plugins ready"
}

# -------------------------------------------------------------------- commands

require_profile() {
    profile_load || profile_prompt
    profile_validate
}

cmd_bootstrap() {
    banner
    ensure_curl
    install_xcode_clt
    ensure_git
    require_profile
    install_brew
    install_brew_packages
    links_apply
    local overlay_ok=1
    overlay_bootstrap || overlay_ok=0
    install_oh_my_zsh
    install_oh_my_zsh_plugins
    cleanup_brew
    echo
    if [[ $overlay_ok -eq 1 ]]; then
        ok "Setup complete. Open a new shell, or run: exec zsh"
    else
        warn "Setup finished, but identity is NOT configured yet."
        echo "   Sign in to your password manager, then run:  ./install.sh --sync-overlay"
    fi
}

cmd_link() {
    require_profile
    links_apply
}

cmd_update() {
    require_profile
    info "Pulling latest dotfiles..."
    git -C "$DOTFILES_DIR" pull --ff-only || warn "pull failed; continuing with the local copy"
    links_apply
    overlay_sync
    install_brew_packages
    info "Updating Oh My Zsh..."
    [[ -d "$HOME/.oh-my-zsh" ]] && "$HOME/.oh-my-zsh/tools/upgrade.sh" >/dev/null 2>&1 || true
    cleanup_brew
    ok "Update complete."
}

cmd_sync() {
    require_profile
    overlay_sync
}

cmd_purge() {
    info "Removing all machine-local configuration..."
    profile_load || true
    overlay_purge
}

cmd_show_key() {
    profile_load || die "no machine profile found; run ./install.sh first"
    local signers
    if [[ "$DOTFILES_PROFILE" == "work" ]]; then
        signers="$DOTFILES_LOCAL/allowed_signers"
    else
        signers="$DOTFILES_CONFIG_DIR/allowed_signers"
    fi
    [[ -f "$signers" ]] || die "no signing key recorded yet; run ./install.sh --sync-overlay"
    overlay_announce_key "$(awk '{print $2, $3}' "$signers")"
}

cmd_dump() {
    has brew || die "Homebrew is not installed"
    brew bundle dump --force --file="$DOTFILES_DIR/Brewfile.new"
    ok "Wrote Brewfile.new — diff it against the right Brewfile, then delete it."
}

cmd_doctor() {
    profile_load || die "no machine profile found; run ./install.sh first"

    info "Profile"
    echo "   profile   ${DOTFILES_PROFILE:-?}"
    echo "   slug      ${DOTFILES_SLUG:-(none)}"
    echo "   provider  ${DOTFILES_PROVIDER:-?}"
    echo "   vault     ${DOTFILES_VAULT:-(none)}"
    echo "   overlay   ${DOTFILES_LOCAL:-(none)}"
    echo

    info "Symlinks"
    links_check || true
    echo

    info "Provider"
    overlay_source_provider
    if provider_require 2>/dev/null; then
        ok "$DOTFILES_PROVIDER CLI present"
    else
        err "$DOTFILES_PROVIDER CLI missing"
    fi
    local socket
    socket="$(provider_agent_socket)"
    if [[ -S "$socket" ]]; then
        ok "agent socket live: ${socket/#$HOME/~}"
    else
        warn "agent socket not present: ${socket/#$HOME/~}"
    fi
    echo

    info "Packages"
    local f missing=0
    while IFS= read -r f; do
        if brew bundle check --file="$f" >/dev/null 2>&1; then
            ok "${f#"$DOTFILES_DIR"/}"
        else
            err "${f#"$DOTFILES_DIR"/} has missing entries"
            missing=1
        fi
    done < <(active_brewfiles)
    [[ $missing -eq 1 ]] && echo "   run ./install.sh to install what is missing"
    echo

    info "Neutrality"
    doctor_leak_scan
}

# The repo must contain no trace of this machine's client, and no absolute home
# path that would break on someone else's user account.
doctor_leak_scan() {
    local -a needles=()
    [[ -n "$DOTFILES_SLUG" && ${#DOTFILES_SLUG} -ge 3 ]] && needles+=("$DOTFILES_SLUG")
    [[ -n "$DOTFILES_VAULT" && ${#DOTFILES_VAULT} -ge 3 ]] && needles+=("$DOTFILES_VAULT")
    [[ -n "$DOTFILES_ACCOUNT" && ${#DOTFILES_ACCOUNT} -ge 3 ]] && needles+=("$DOTFILES_ACCOUNT")

    local clean=1

    has rg || {
        warn "ripgrep not installed; skipping the leak scan"
        return 0
    }

    if [[ "$DOTFILES_PROFILE" == "work" && ${#needles[@]} -gt 0 ]]; then
        local -a args=()
        local n
        for n in "${needles[@]}"; do args+=(-e "$n"); done
        if rg --fixed-strings --ignore-case --quiet "${args[@]}" "$DOTFILES_DIR" 2>/dev/null; then
            err "client identifiers found in the repo:"
            rg --fixed-strings --ignore-case --line-number "${args[@]}" "$DOTFILES_DIR" 2>/dev/null | head -20
            clean=0
        fi
    fi

    if rg --fixed-strings --quiet "/Users/$USER" "$DOTFILES_DIR" 2>/dev/null; then
        err "hardcoded home path found (breaks on another machine):"
        rg --fixed-strings --line-number "/Users/$USER" "$DOTFILES_DIR" 2>/dev/null | head -10
        clean=0
    fi

    [[ $clean -eq 1 ]] && ok "repo is neutral"
    return 0
}

# ----------------------------------------------------------------------- main

main() {
    parse_args "$@"
    case "$ACTION" in
        bootstrap) cmd_bootstrap ;;
        link) cmd_link ;;
        update) cmd_update ;;
        sync) cmd_sync ;;
        purge) cmd_purge ;;
        showkey) cmd_show_key ;;
        doctor) cmd_doctor ;;
        dump) cmd_dump ;;
    esac
}

main "$@"
