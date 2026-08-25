#!/usr/bin/env bash
# 1Password provider.
#
# Multiple accounts are addressed with `op --account <sign-in address>`, which
# is what lets a personal account and a client account coexist on one machine.
# https://developer.1password.com/docs/cli/use-multiple-accounts/

_op_overlay_json=""

provider_require() {
    command -v op >/dev/null 2>&1 ||
        die "1Password CLI not found. Install it with: brew install 1password-cli"
}

# Non-fatal probe: can we actually reach this account right now?
provider_ready() {
    op --account "$DOTFILES_ACCOUNT" vault list >/dev/null 2>&1
}

provider_unlock() {
    provider_ready ||
        die "Not signed in to $DOTFILES_ACCOUNT. Run: eval \$(op signin --account $DOTFILES_ACCOUNT)"
}

provider_gui_app() { printf '%s\n' "/Applications/1Password.app"; }

provider_setup_hint() {
    cat <<EOF
1Password is installed but this machine cannot reach account
  $DOTFILES_ACCOUNT

On a fresh Mac you still have to do this once, by hand:

  1. Open 1Password and sign in to $DOTFILES_ACCOUNT
  2. Settings > Developer > enable "Integrate with 1Password CLI"
  3. Settings > Developer > enable "Use the SSH agent"

No secret can be fetched until then — that is the point of the vault.
EOF
}

provider_lock() { :; } # 1Password manages its own session lifetime

# Fetch the overlay item once; every field read is served from this JSON.
provider_load_overlay() {
    _op_overlay_json="$(
        op item get "$OVERLAY_ITEM" \
            --account "$DOTFILES_ACCOUNT" \
            --vault "$DOTFILES_VAULT" \
            --format json 2>/dev/null
    )" || return 1
    [[ -n "$_op_overlay_json" ]]
}

provider_fetch() {
    [[ -n "$_op_overlay_json" ]] || return 1
    printf '%s' "$_op_overlay_json" |
        jq -er --arg f "$1" '.fields[]? | select(.label == $f or .id == $f) | .value' 2>/dev/null
}

provider_pubkey() {
    op read --account "$DOTFILES_ACCOUNT" "op://$DOTFILES_VAULT/$1/public key" 2>/dev/null
}

provider_supports_keygen() { return 0; }

# `--category ssh` generates an Ed25519 pair inside the vault; the private half
# never reaches this machine. https://developer.1password.com/docs/cli/ssh-keys/
provider_create_key() {
    op item create \
        --category ssh \
        --title "$1" \
        --vault "$DOTFILES_VAULT" \
        --account "$DOTFILES_ACCOUNT" >/dev/null
}

provider_keygen_hint() {
    printf '%s\n' "Run: op item create --category ssh --title \"$1\" --vault \"$DOTFILES_VAULT\""
}

provider_agent_socket() {
    printf '%s\n' "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
}

# 1Password ships its own SSH signer, which git uses in place of ssh-keygen.
provider_ssh_sign_program() {
    printf '%s\n' "/Applications/1Password.app/Contents/MacOS/op-ssh-sign"
}

provider_uses_agent_toml() { return 0; }
