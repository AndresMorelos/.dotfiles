#!/usr/bin/env bash
# Bitwarden provider.
#
# The session token is held in the environment for the lifetime of the run and
# never written to disk. An EXIT trap re-locks the vault if we unlocked it.
# https://bitwarden.com/help/cli/

_bw_overlay_json=""
_bw_we_unlocked=""

provider_require() {
    command -v bw >/dev/null 2>&1 ||
        die "Bitwarden CLI not found. Install it with: brew install bitwarden-cli"
    command -v jq >/dev/null 2>&1 ||
        die "jq not found. Install it with: brew install jq"
}

# Non-fatal probe: "locked" still counts as ready, we can unlock interactively.
provider_accounts() { :; }

# Bitwarden CLI cannot filter by item category, so there is nothing to offer.
provider_list_keys() { :; }

provider_ready() {
    local s
    s="$(bw status 2>/dev/null | jq -r '.status // "unauthenticated"')"
    [[ "$s" == "locked" || "$s" == "unlocked" ]]
}

provider_gui_app() { printf '%s\n' "/Applications/Bitwarden.app"; }

provider_setup_hint() {
    cat <<EOF
Bitwarden is installed but this machine is not logged in yet.

On a fresh Mac you still have to do this once, by hand:

  1. Open Bitwarden and log in
  2. Settings > enable "SSH agent"
  3. In a terminal:  bw login

No secret can be fetched until then — that is the point of the vault.
EOF
}

provider_unlock() {
    local status
    status="$(bw status 2>/dev/null | jq -r '.status // "unauthenticated"')"

    case "$status" in
        unauthenticated)
            die "Not logged in to Bitwarden. Run: bw login"
            ;;
        locked)
            step "Unlocking Bitwarden vault..."
            BW_SESSION="$(bw unlock --raw)" ||
                die "Bitwarden unlock failed"
            export BW_SESSION
            _bw_we_unlocked=1
            trap provider_lock EXIT
            ;;
        unlocked)
            [[ -n "${BW_SESSION:-}" ]] ||
                die "Bitwarden reports unlocked but BW_SESSION is unset. Run: export BW_SESSION=\$(bw unlock --raw)"
            ;;
    esac

    bw sync --session "$BW_SESSION" >/dev/null 2>&1 || true
}

provider_lock() {
    [[ -n "$_bw_we_unlocked" ]] || return 0
    bw lock >/dev/null 2>&1 || true
    _bw_we_unlocked=""
}

provider_load_overlay() {
    _bw_overlay_json="$(bw get item "$OVERLAY_ITEM" --session "$BW_SESSION" 2>/dev/null)" || return 1
    [[ -n "$_bw_overlay_json" ]]
}

provider_fetch() {
    [[ -n "$_bw_overlay_json" ]] || return 1
    printf '%s' "$_bw_overlay_json" |
        jq -er --arg f "$1" '.fields[]? | select(.name == $f) | .value' 2>/dev/null
}

# provider_pubkey <item> [vault]  -- Bitwarden has no vault dimension here.
provider_pubkey() {
    bw get item "$1" --session "$BW_SESSION" 2>/dev/null |
        jq -er '.sshKey.publicKey' 2>/dev/null
}

# `bw` has no documented SSH key generation. We refuse to improvise with a
# temporary ssh-keygen file: a client's private key must never touch that
# client's disk, not even briefly.
provider_supports_keygen() { return 1; }

provider_create_key() {
    die "internal: bitwarden cannot generate keys"
}

provider_keygen_hint() {
    cat <<EOF
Bitwarden CLI cannot generate SSH keys.
   Create it in Bitwarden Desktop:

     Settings -> SSH agent -> Add SSH key -> Ed25519
     Name it exactly: $1

   Then re-run:  ./install.sh --sync-overlay
EOF
}

# Two install methods, two socket locations.
# https://bitwarden.com/help/ssh-agent/
provider_agent_socket() {
    local dmg="$HOME/.bitwarden-ssh-agent.sock"
    local appstore="$HOME/Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock"

    if [[ -S "$appstore" ]]; then
        printf '%s\n' "$appstore"
    elif [[ -S "$dmg" ]]; then
        printf '%s\n' "$dmg"
    else
        # Neither socket exists yet (agent not enabled, or app not running).
        # Emit the direct-download default so the config is valid once it is.
        printf '%s\n' "$dmg"
    fi
}

# Deliberately empty: with no gpg.ssh.program, git signs with `ssh-keygen -Y sign`
# against whichever agent IdentityAgent points at. That is what Bitwarden needs.
provider_ssh_sign_program() { printf '\n'; }

provider_uses_agent_toml() { return 1; }
