#!/usr/bin/env bash
# Colored output helpers shared by install.sh and the other lib/ modules.

NC=$'\033[0m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
RED=$'\033[0;31m'
BLUE=$'\033[0;34m'
CYAN=$'\033[1;36m'
DIM=$'\033[2m'

banner() {
    printf '%s\n' "$CYAN"
    echo "############################################################"
    echo "#                                                          #"
    echo "#          Welcome to Masteorion DotFiles Setup!           #"
    echo "#                                                          #"
    echo "############################################################"
    printf '%s\n' "$NC"
}

info() { printf '%s\n' "${BLUE}$*${NC}"; }
step() { printf '%s\n' "${YELLOW}$*${NC}"; }
ok() { printf '%s\n' "${GREEN}   ok  $*${NC}"; }
skip() { printf '%s\n' "${DIM}   --  $*${NC}"; }
warn() { printf '%s\n' "${YELLOW}   !   $*${NC}" >&2; }
err() { printf '%s\n' "${RED}   x   $*${NC}" >&2; }
die() {
    err "$*"
    exit 1
}
