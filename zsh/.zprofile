eval "$(/opt/homebrew/bin/brew shellenv)"

export DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"

# Machine profile. Parsed, never sourced — a config file must not run code.
_dotfiles_config="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/config"
if [[ -r $_dotfiles_config ]]; then
    while IFS='=' read -r _k _v; do
        case $_k in
            profile) export DOTFILES_PROFILE=$_v ;;
            slug) export DOTFILES_SLUG=$_v ;;
            provider) export DOTFILES_PROVIDER=$_v ;;
        esac
    done <$_dotfiles_config
fi
[[ -n ${DOTFILES_SLUG:-} ]] && export DOTFILES_LOCAL="$HOME/.dotfiles-local/$DOTFILES_SLUG"
unset _dotfiles_config _k _v

# pyenv is initialized here and ONLY here. Repeating it in .zshrc costs a full
# extra init on every interactive shell.
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
command -v pyenv >/dev/null && eval "$(pyenv init - zsh)"

# Added by OrbStack: command-line tools and integration
# This won't be added again if you remove it.
source ~/.orbstack/shell/init.zsh 2>/dev/null || :
