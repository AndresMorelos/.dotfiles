# Aliases shared by every machine.

alias python="python3"

# Modern replacements (installed by the base Brewfile).
command -v eza >/dev/null && {
    alias ls="eza"
    alias ll="eza -la --git"
    alias tree="eza --tree"
}
command -v bat >/dev/null && alias cat="bat"
