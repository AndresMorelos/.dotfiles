# Environment shared by every machine.

export GOPATH="$HOME/go"
export GOBIN="$GOPATH/bin"

# fnm keeps its installs under Application Support. $HOME, never a literal
# username — this file has to work on a machine that is not yours.
export FNM_DIR="$HOME/Library/Application Support/fnm"

typeset -U path
path=(
    "$GOBIN"
    "/opt/homebrew/opt/ruby/bin"
    "$HOME/.local/bin"
    ${FNM_DIR:+"$FNM_DIR"}
    $path
)
export PATH

command -v fnm >/dev/null && eval "$(fnm env --use-on-cd --version-file-strategy=recursive)"

export STARSHIP_CONFIG="$DOTFILES_DIR/starship/starship.toml"
command -v starship >/dev/null && eval "$(starship init zsh)"

# Point ssh-keygen (git's signer) at the password manager agent.
[[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/agent-env.sh" ]] &&
    source "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/agent-env.sh"
