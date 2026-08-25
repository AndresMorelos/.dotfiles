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
# shellcheck source=lib/adopt.sh
source "$DOTFILES_DIR/lib/adopt.sh"

ALL_GROUPS=(dev productivity macos streaming)

ACTION="bootstrap"
declare -a SELECTED_GROUPS=()
declare -a SKIP_GROUPS=()

# Values given on the command line. Kept separate because profile_load reads the
# stored config into the same variables; an explicit flag must win over it,
# otherwise a mistake in the saved config could never be corrected.
CLI_PROFILE="" CLI_SLUG="" CLI_PROVIDER="" CLI_ACCOUNT=""
CLI_VAULT="" CLI_ITEM="" CLI_KEY_ITEM="" CLI_KEY_VAULT=""

print_help() {
    cat <<EOF
Usage: ./install.sh [COMMAND] [OPTIONS]

Commands (default: full bootstrap):
  --link                    Relink dotfiles only. Fast, no network.
  --update                  Pull, relink, re-sync overlay, update packages.
  --sync-overlay            Re-fetch this machine's overlay from its vault.
  --purge-overlay           Remove all machine-local config. For handing a laptop back.
  --show-signing-key        Print the active signing key and where to register it.
  --adopt                   Inspect a machine that was set up by hand and adopt
                            its existing identity, keys and packages.
  --doctor                  Report profile, links, packages, and neutrality.
  --dump                    Write current Homebrew state to Brewfile.new.
  --help, -h                Show this message.

Profile options (persisted to ~/.config/dotfiles/config, never committed):
  --profile personal|work
  --slug NAME               Short client name. Local only. Work profiles only.
  --provider onepassword|bitwarden
  --account ADDRESS         1Password sign-in address (auto-detected if only one)
  --vault NAME              1Password vault holding the overlay
  --item NAME               Bitwarden item name (default: dotfiles-overlay)
  --signing-key-item NAME   Reuse an existing SSH-key item instead of creating one
  --signing-key-vault NAME  Vault holding that key

Package options:
  --packages GROUPS         Comma-separated groups to install
  --skip-packages GROUPS    Comma-separated groups to skip

Package groups:
  dev           cursor, iterm2, cleanshot, slack, tableplus, orbstack, ...
  productivity  numi, raycast, rectangle
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
            --adopt) ACTION="adopt" ;;
            --profile)
                CLI_PROFILE="${2:?--profile needs a value}"
                shift
                ;;
            --slug)
                CLI_SLUG="${2:?--slug needs a value}"
                shift
                ;;
            --provider)
                CLI_PROVIDER="${2:?--provider needs a value}"
                shift
                ;;
            --account)
                CLI_ACCOUNT="${2:?--account needs a value}"
                shift
                ;;
            --vault)
                CLI_VAULT="${2:?--vault needs a value}"
                shift
                ;;
            --item)
                CLI_ITEM="${2:?--item needs a value}"
                shift
                ;;
            --signing-key-item)
                CLI_KEY_ITEM="${2:?--signing-key-item needs a value}"
                shift
                ;;
            --signing-key-vault)
                CLI_KEY_VAULT="${2:?--signing-key-vault needs a value}"
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

# Does an app with this cask's name already sit in /Applications without brew
# knowing about it? Common on a machine that was set up by hand first.
_app_installed_manually() {
    local token="$1" artifact
    brew list --cask --versions "$token" >/dev/null 2>&1 && return 1
    while IFS= read -r artifact; do
        [[ -n "$artifact" && -e "/Applications/$artifact" ]] && return 0
    done < <(brew info --cask --json=v2 "$token" 2>/dev/null |
        jq -r '.casks[0].artifacts[]? | .app[]? // empty' 2>/dev/null)
    return 1
}

install_brew_packages() {
    info "Installing packages with brew bundle..."
    brew update >/dev/null 2>&1 || warn "brew update failed; continuing with the local index"

    # --adopt lets brew take over an app that was installed by hand instead of
    # refusing or clobbering it. Without this, any machine that predates these
    # dotfiles fails to converge.
    local f
    export HOMEBREW_CASK_OPTS="${HOMEBREW_CASK_OPTS:-} --adopt"
    while IFS= read -r f; do
        step "  ${f#"$DOTFILES_DIR"/}"
        brew bundle install --file="$f" >/dev/null ||
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
    # env -u ZSH: the installer reads $ZSH from the environment, and our own
    # .zshrc exports it. Inheriting it makes the installer refuse to run.
    # The installer also exits 0 when it refuses, so its status proves nothing -
    # check for the file it is supposed to produce instead.
    local log
    log="$(env -u ZSH RUNZSH=no KEEP_ZSHRC=yes CHSH=no sh -c \
        "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
        "" --unattended 2>&1)" || true

    if [[ ! -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]]; then
        err "Oh My Zsh did not install. Installer said:"
        printf '%s\n' "$log" | tail -12 >&2
        die "fix the above, then re-run ./install.sh"
    fi
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

# strict=0 for commands that only touch the filesystem: linking needs no vault,
# so it must not demand provider credentials to run.
# Apply command-line overrides on top of whatever was stored.
# Sets CLI_OVERRODE=1 if anything changed. Deliberately NOT called in a command
# substitution: a subshell would discard every assignment it makes.
CLI_OVERRODE=0
apply_cli_overrides() {
    CLI_OVERRODE=0
    _override() {
        local name="$1" cli="$2" current="$3"
        [[ -z "$cli" || "$cli" == "$current" ]] && return 0
        eval "$name=\"\$cli\""
        CLI_OVERRODE=1
    }
    _override DOTFILES_PROFILE "$CLI_PROFILE" "$DOTFILES_PROFILE"
    _override DOTFILES_SLUG "$CLI_SLUG" "$DOTFILES_SLUG"
    _override DOTFILES_PROVIDER "$CLI_PROVIDER" "$DOTFILES_PROVIDER"
    _override DOTFILES_ACCOUNT "$CLI_ACCOUNT" "$DOTFILES_ACCOUNT"
    _override DOTFILES_VAULT "$CLI_VAULT" "$DOTFILES_VAULT"
    _override DOTFILES_ITEM "$CLI_ITEM" "$DOTFILES_ITEM"
    _override DOTFILES_KEY_ITEM "$CLI_KEY_ITEM" "$DOTFILES_KEY_ITEM"
    _override DOTFILES_KEY_VAULT "$CLI_KEY_VAULT" "$DOTFILES_KEY_VAULT"
    profile_derive
}

require_profile() {
    local strict="${1:-1}"
    # Seed from the flags so a first run does not re-ask what was already given.
    DOTFILES_PROFILE="$CLI_PROFILE" DOTFILES_SLUG="$CLI_SLUG"
    DOTFILES_PROVIDER="$CLI_PROVIDER" DOTFILES_ACCOUNT="$CLI_ACCOUNT"
    DOTFILES_VAULT="$CLI_VAULT" DOTFILES_ITEM="$CLI_ITEM"
    DOTFILES_KEY_ITEM="$CLI_KEY_ITEM" DOTFILES_KEY_VAULT="$CLI_KEY_VAULT"

    if profile_load; then
        apply_cli_overrides
        if [[ "$CLI_OVERRODE" == "1" ]]; then
            profile_save >/dev/null
            ok "machine config updated from the command line"
        fi
    else
        profile_prompt
    fi
    if [[ "$strict" == "1" ]]; then
        if [[ "$DOTFILES_PROVIDER" == "onepassword" && -z "$DOTFILES_ACCOUNT" ]]; then
            profile_detect_account
            profile_save >/dev/null
        fi
        profile_validate
    else
        case "$DOTFILES_PROFILE" in
            personal | work) ;;
            *) die "profile must be 'personal' or 'work' (got: '${DOTFILES_PROFILE:-empty}')" ;;
        esac
    fi
}

cmd_bootstrap() {
    banner
    ensure_curl
    install_xcode_clt
    ensure_git
    require_profile
    install_brew
    install_brew_packages
    # Before links_apply: the linked .zshrc expects oh-my-zsh to be there.
    install_oh_my_zsh
    install_oh_my_zsh_plugins
    links_apply
    local overlay_ok=1
    overlay_bootstrap || overlay_ok=0
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
    require_profile 0
    [[ -d "$HOME/.oh-my-zsh" ]] || warn "oh-my-zsh is not installed; run ./install.sh to complete the setup"
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

    local na="(none - personal profile)"
    [[ "$DOTFILES_PROFILE" == "work" ]] && na="(unset)"

    info "Profile"
    echo "   profile     ${DOTFILES_PROFILE:-?}"
    echo "   provider    ${DOTFILES_PROVIDER:-?}"
    echo "   account     ${DOTFILES_ACCOUNT:-(n/a)}"
    echo "   slug        ${DOTFILES_SLUG:-$na}"
    echo "   vault       ${DOTFILES_VAULT:-$na}"
    echo "   overlay     ${DOTFILES_LOCAL:-$na}"
    echo

    info "Signing"
    if [[ -n "$DOTFILES_KEY_ITEM" ]]; then
        echo "   key item    $DOTFILES_KEY_ITEM  [vault: ${DOTFILES_KEY_VAULT:-?}]"
    else
        warn "no signing key pinned yet - run ./install.sh --sync-overlay"
    fi
    local signers gsign signer workdir
    signers="$(git config gpg.ssh.allowedSignersFile || true)"
    gsign="$(git config commit.gpgsign || echo false)"
    signer="$(git config gpg.ssh.program || true)"

    # On a client machine the interesting values live INSIDE the work directory;
    # reading them from here reports the deliberate global "off" and looks broken.
    if [[ "$DOTFILES_PROFILE" == "work" && -f "$HOME/.gitconfig.local" ]]; then
        workdir="$(rg -o 'gitdir:(.+)"' -r '$1' "$HOME/.gitconfig.local" 2>/dev/null | head -1)"
        if [[ -n "$workdir" && -d "$workdir" ]]; then
            echo "   workdir     ${workdir/#$HOME/~}"
            local in_gsign in_email
            in_gsign="$(git -C "$workdir" config commit.gpgsign 2>/dev/null || echo false)"
            in_email="$(git -C "$workdir" config user.email 2>/dev/null || true)"
            signers="$(git -C "$workdir" config gpg.ssh.allowedSignersFile 2>/dev/null || true)"
            signer="$(git -C "$workdir" config gpg.ssh.program 2>/dev/null || true)"
            echo "   inside      $in_email  gpgsign=$in_gsign"
            echo "   outside     gpgsign=$gsign  (intentional: the personal key is not on this machine)"
            gsign="$in_gsign"
        else
            warn "work directory ${workdir:-?} does not exist yet"
        fi
    else
        echo "   gpgsign     $gsign"
    fi
    if [[ -n "$signer" ]]; then
        if [[ -x "$signer" ]]; then
            echo "   signer      $signer"
        else
            err "gpg.ssh.program points at a missing binary: $signer"
            echo "         every signed commit will fail; re-run --sync-overlay"
        fi
    else
        echo "   signer      ssh-keygen (no vendor signer)"
        # ssh-keygen reads SSH_AUTH_SOCK, not ssh_config's IdentityAgent.
        if [[ -z "${SSH_AUTH_SOCK:-}" || ! -S "${SSH_AUTH_SOCK:-}" ]]; then
            err "SSH_AUTH_SOCK is not a live socket, so ssh-keygen cannot sign"
            echo "         open a new shell, or re-run --sync-overlay"
        fi
    fi

    if [[ "$gsign" == "true" && -n "$signers" && -f "$signers" ]]; then
        ok "signatures verify (allowed_signers present)"
    elif [[ "$gsign" == "true" ]]; then
        err "signing is on but allowed_signers is missing - signatures will not verify"
    else
        # Say WHY it is off, not just that it is.
        if [[ -z "$DOTFILES_KEY_ITEM" ]]; then
            warn "unsigned because the overlay has never synced on this machine"
            if [[ "$DOTFILES_PROFILE" == "work" ]]; then
                echo "         the vault needs an item called '''dotfiles-overlay''' with an"
                echo "         '''email''' field. Create it, then: ./install.sh --sync-overlay"
            else
                echo "         run: ./install.sh --sync-overlay"
            fi
        else
            warn "unsigned: a key is pinned but ~/.gitconfig.local was not written"
            echo "         run: ./install.sh --sync-overlay"
        fi
    fi
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
    local f missing=0 detail
    while IFS= read -r f; do
        if brew bundle check --file="$f" >/dev/null 2>&1; then
            ok "${f#"$DOTFILES_DIR"/}"
        else
            err "${f#"$DOTFILES_DIR"/}"
            # "needs to be installed or updated" covers both, so separate them:
            # anything brew already knows about is merely outdated.
            detail="$(brew bundle check --file="$f" --verbose 2>&1 |
                rg -o '(Formula|Cask) \S+' || true)"
            local kind name
            while read -r kind name; do
                [[ -z "${name:-}" ]] && continue
                if [[ "$kind" == "Formula" ]] && brew list --formula --versions "$name" >/dev/null 2>&1; then
                    echo "         $name (outdated)"
                elif [[ "$kind" == "Cask" ]] && brew list --cask --versions "$name" >/dev/null 2>&1; then
                    echo "         $name (outdated)"
                elif [[ "$kind" == "Cask" ]] && _app_installed_manually "$name"; then
                    echo "         $name (installed outside brew — will be adopted)"
                else
                    echo "         $name (missing)"
                fi
            done <<<"$detail"
            missing=1
        fi
    done < <(active_brewfiles)
    [[ $missing -eq 1 ]] && echo "   run ./install.sh to converge"
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
        adopt) cmd_adopt ;;
    esac
}

main "$@"
