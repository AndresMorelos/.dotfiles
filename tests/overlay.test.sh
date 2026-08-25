#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2088  # "cond && pass || fail" is the assertion idiom here
# Exercises overlay_sync_work / overlay_sync_personal against a mock provider,
# then asserts what git actually resolves.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DOTFILES_DIR
SANDBOX="$(cd "$(mktemp -d)" && pwd -P)"  # -P: git compares real paths in gitdir:
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"
HOME="$SANDBOX"
export HOME

source "$DOTFILES_DIR/lib/log.sh"
source "$DOTFILES_DIR/lib/profile.sh"
source "$DOTFILES_DIR/lib/overlay.sh"

# ---- mock provider ---------------------------------------------------------
MOCK_STATE="$SANDBOX/.mockstate"
: >"$MOCK_STATE.exists"
MOCK_CAN_KEYGEN="${MOCK_CAN_KEYGEN:-1}"
MOCK_PUB="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEKEYFORTESTINGONLY0000000000000"
provider_require() { :; }
provider_unlock() { :; }
provider_load_overlay() { :; }
provider_uses_agent_toml() { return 0; }
provider_agent_socket() { printf '%s\n' "$HOME/mock-agent.sock"; }
provider_ssh_sign_program() { printf '%s\n' "/Applications/1Password.app/Contents/MacOS/op-ssh-sign"; }
provider_supports_keygen() { [[ "$MOCK_CAN_KEYGEN" == 1 ]]; }
provider_create_key() {
    echo x >>"$MOCK_STATE.created"
    : >"$MOCK_STATE.exists"
}
provider_keygen_hint() { echo "create '$1' in the desktop app"; }
provider_pubkey() {
    [[ -f "$MOCK_STATE.exists" ]] || return 1
    printf '%s' "$MOCK_PUB"
}
provider_fetch() {
    case "$1" in
        email) printf '%s' "dev@acme.example" ;;
        name) printf '%s' "Andres Morelos" ;;
        workdir) printf '%s' "~/Dev/acme/" ;;
        zsh) printf '%s' 'export ACME_ENV=staging' ;;
        brewfile) printf '%s' 'brew "terraform"' ;;
        agent-keys) printf '%s' '[[ssh-keys]]\nvault = "AcmeVault"' ;;
        *) return 1 ;;
    esac
}

fail() {
    printf '\033[0;31mFAIL: %s\033[0m\n' "$*"
    exit 1
}
pass() { printf '\033[0;32mPASS: %s\033[0m\n' "$*"; }

# ---- work profile ----------------------------------------------------------
echo "=============== WORK PROFILE (1Password-style) ==============="
DOTFILES_PROFILE="work"
DOTFILES_SLUG="acme"
DOTFILES_PROVIDER="onepassword"
DOTFILES_VAULT="AcmeVault"
profile_derive
overlay_sync_work "$(provider_ssh_sign_program)" >/dev/null
overlay_write_ssh_config_local >/dev/null

[[ -d "$DOTFILES_LOCAL" ]] || fail "overlay dir missing"
perms="$(stat -f '%Lp' "$DOTFILES_LOCAL")"
[[ "$perms" == "700" ]] && pass "overlay dir is mode 700" || fail "overlay dir is $perms, expected 700"

[[ -f "$DOTFILES_LOCAL/allowed_signers" ]] && pass "allowed_signers written" || fail "no allowed_signers"
[[ -f "$DOTFILES_LOCAL/zsh.zsh" ]] && pass "overlay zsh fragment written" || fail "no zsh fragment"
[[ -f "$DOTFILES_LOCAL/Brewfile" ]] && pass "overlay Brewfile written" || fail "no Brewfile"

# Build a real repo tree and ask git what it resolves.
mkdir -p "$HOME/Dev/acme/probe" "$HOME/Dev/personal-thing"
ln -sf "$DOTFILES_DIR/git/gitconfig" "$HOME/.gitconfig"
git -C "$HOME/Dev/acme/probe" init -q
git -C "$HOME/Dev/personal-thing" init -q

work_email="$(git -C "$HOME/Dev/acme/probe" config user.email)"
[[ "$work_email" == "dev@acme.example" ]] &&
    pass "inside workdir -> work email ($work_email)" ||
    fail "inside workdir got '$work_email'"

work_sign="$(git -C "$HOME/Dev/acme/probe" config commit.gpgsign)"
[[ "$work_sign" == "true" ]] && pass "inside workdir -> signing ON" || fail "signing is '$work_sign'"

pers_sign="$(git -C "$HOME/Dev/personal-thing" config commit.gpgsign)"
[[ "$pers_sign" == "false" ]] &&
    pass "outside workdir -> signing OFF (key is unreachable here)" ||
    fail "outside workdir signing is '$pers_sign'"

key="$(git -C "$HOME/Dev/acme/probe" config user.signingkey)"
[[ "$key" == "$MOCK_PUB" ]] && pass "signingkey resolved from the vault" || fail "signingkey is '$key'"

signers="$(git -C "$HOME/Dev/acme/probe" config gpg.ssh.allowedSignersFile)"
[[ "$signers" == "$DOTFILES_LOCAL/allowed_signers" ]] &&
    pass "allowedSignersFile wired up" || fail "allowedSignersFile is '$signers'"

# ---- key generation --------------------------------------------------------
echo
echo "=============== SIGNING KEY PROVISIONING ==============="
rm -f "$MOCK_STATE.exists" "$MOCK_STATE.created"
got="$(overlay_ensure_signing_key "git-signing-key" 2>/dev/null)"
created=$(wc -l <"$MOCK_STATE.created" 2>/dev/null | tr -d ' ' || echo 0)
[[ "$got" == "$MOCK_PUB" && "$created" == "1" ]] &&
    pass "1Password-style: key auto-created when missing" || fail "keygen did not happen (created=$created)"

rm -f "$MOCK_STATE.created"
got="$(overlay_ensure_signing_key "git-signing-key" 2>/dev/null)"
[[ ! -f "$MOCK_STATE.created" ]] && pass "second run does NOT create a duplicate" || fail "created a duplicate key"

rm -f "$MOCK_STATE.exists"
MOCK_CAN_KEYGEN=0
if overlay_ensure_signing_key "git-signing-key" >/dev/null 2>&1; then
    fail "Bitwarden-style should have failed, not succeeded"
else
    pass "Bitwarden-style: fails loudly instead of improvising"
fi
before="$(fd . "$HOME/.ssh" -H -t f 2>/dev/null | wc -l | tr -d ' ')"
[[ "$before" == "1" ]] &&
    pass "no private key was written to disk (only config.local)" ||
    fail "unexpected files in ~/.ssh: $before"

# ---- purge -----------------------------------------------------------------
echo
echo "=============== PURGE ==============="
MOCK_CAN_KEYGEN=1
: >"$MOCK_STATE.exists"
overlay_purge >/dev/null 2>&1
[[ ! -e "$HOME/.dotfiles-local" ]] && pass "overlay removed" || fail "overlay survived"
[[ ! -e "$HOME/.gitconfig.local" ]] && pass "~/.gitconfig.local removed" || fail "gitconfig.local survived"

[[ ! -e "$HOME/.gitconfig.base.local" ]] && pass "personal include removed too" || fail "base include survived"
after_email="$(git -C "$HOME/Dev/acme/probe" config user.email || true)"
[[ -z "$after_email" ]] &&
    pass "no identity left at all after purge" ||
    fail "after purge git still resolves '$after_email'"

# ---- deferred guard (fresh Mac, manager not signed in yet) ------------------
echo
echo "=============== DEFERRED GUARD (new Mac, not signed in) ==============="
DOTFILES_PROFILE="work"
profile_derive
"$DOTFILES_DIR/lib/../lib/log.sh" >/dev/null 2>&1 || true
source "$DOTFILES_DIR/lib/links.sh"
links_write_git_base >/dev/null
overlay_write_deferred_guard 2>/dev/null
guard_email="$(git -C "$HOME/Dev/acme/probe" config user.email || true)"
[[ -z "$guard_email" ]] &&
    pass "work machine has NO identity until sync (cannot commit as personal)" ||
    fail "guard leaked identity '$guard_email'"
uco="$(git -C "$HOME/Dev/acme/probe" config user.useConfigOnly || true)"
[[ "$uco" == "true" ]] && pass "useConfigOnly forces git to refuse to guess" || fail "useConfigOnly is '$uco'"

DOTFILES_PROFILE="personal"
DOTFILES_SLUG=""
profile_derive
links_write_git_base >/dev/null
overlay_write_deferred_guard 2>/dev/null
p_email="$(git -C "$HOME/Dev/personal-thing" config user.email || true)"
p_sign="$(git -C "$HOME/Dev/personal-thing" config commit.gpgsign || true)"
[[ "$p_email" == "6563162+AndresMorelos@users.noreply.github.com" && "$p_sign" == "false" ]] &&
    pass "personal machine still usable, just unsigned ($p_email)" ||
    fail "personal deferred got email='$p_email' sign='$p_sign'"

echo
printf '\033[0;32mAll overlay assertions passed.\033[0m\n'
