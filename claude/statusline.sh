#!/usr/bin/env bash
# Claude Code status line.
#
# Reads the session payload as JSON on stdin and prints one line.
# Payload shape (verified against the 2.1.x binary):
#   .model.display_name
#   .workspace.current_dir | .project_dir | .repo?
#   .output_style.name
#   .cost.total_cost_usd | .total_lines_added | .total_lines_removed
#   .exceeds_200k_tokens
#
# The point of this line is the identity segment: on a machine that serves a
# client, seeing WHICH git identity is active in this directory - before
# committing - is worth more than any other status it could show.

set -uo pipefail

C_RESET=$'\033[0m'
C_DIM=$'\033[2m'
C_MODEL=$'\033[38;5;110m'
C_DIR=$'\033[38;5;180m'
C_GIT=$'\033[38;5;108m'
C_DIRTY=$'\033[38;5;215m'
C_PERSONAL=$'\033[38;5;114m'
C_WORK=$'\033[38;5;204m'
C_WARN=$'\033[38;5;203m'

payload="$(cat)"
j() { printf '%s' "$payload" | jq -r "$1 // empty" 2>/dev/null; }

model="$(j '.model.display_name')"
cwd="$(j '.workspace.current_dir')"
[[ -z "$cwd" ]] && cwd="$(j '.cwd')"
[[ -z "$cwd" ]] && cwd="$PWD"
cost="$(j '.cost.total_cost_usd')"
over200k="$(j '.exceeds_200k_tokens')"

segments=()

# --- model ------------------------------------------------------------------
[[ -n "$model" ]] && segments+=("${C_MODEL}${model}${C_RESET}")

# --- directory --------------------------------------------------------------
short_dir="${cwd/#$HOME/\~}"
segments+=("${C_DIR}${short_dir##*/}${C_RESET}")

# --- git branch -------------------------------------------------------------
if branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)"; then
    dirty=""
    git -C "$cwd" diff --quiet --ignore-submodules HEAD 2>/dev/null || dirty="*"
    if [[ -n "$dirty" ]]; then
        segments+=("${C_GIT}${branch}${C_DIRTY}${dirty}${C_RESET}")
    else
        segments+=("${C_GIT}${branch}${C_RESET}")
    fi
fi

# --- identity: the reason this status line exists ---------------------------
# Read the profile straight from the machine config; never guess from the repo.
profile="" slug=""
cfg="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/config"
if [[ -r "$cfg" ]]; then
    while IFS='=' read -r k v; do
        case "$k" in
            profile) profile="$v" ;;
            slug) slug="$v" ;;
        esac
    done <"$cfg"
fi

# Only inside a repository: outside one there is no commit to get wrong, and
# git would happily report the global address anyway.
in_repo=0
git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 && in_repo=1

# Resolved from inside $cwd, so includeIf rules are honoured - this is the
# address the next commit will actually carry.
email=""
[[ $in_repo -eq 1 ]] && email="$(git -C "$cwd" config user.email 2>/dev/null || true)"

# A GitHub noreply address is unambiguous long before its 46th character.
case "$email" in
    *+*@users.noreply.github.com)
        email="${email#*+}"
        email="${email%@users.noreply.github.com}@noreply"
        ;;
esac

if [[ -n "$email" ]]; then
    if [[ "$profile" == "work" ]]; then
        segments+=("${C_WORK}${slug:-work}:${email}${C_RESET}")
    else
        segments+=("${C_PERSONAL}${email}${C_RESET}")
    fi
elif [[ $in_repo -eq 1 ]]; then
    # In a repo with no identity at all: commits will be refused. Say so loudly.
    segments+=("${C_WARN}no git identity${C_RESET}")
fi

# Signing off inside a repo is worth knowing before you write the commit.
if [[ $in_repo -eq 1 ]]; then
    [[ "$(git -C "$cwd" config commit.gpgsign 2>/dev/null)" == "true" ]] ||
        segments+=("${C_DIM}unsigned${C_RESET}")
fi

# --- cost -------------------------------------------------------------------
if [[ -n "$cost" && "$cost" != "0" ]]; then
    segments+=("$(printf '%s$%.2f%s' "$C_DIM" "$cost" "$C_RESET")")
fi

[[ "$over200k" == "true" ]] && segments+=("${C_WARN}200k+${C_RESET}")

# --- render -----------------------------------------------------------------
out=""
for s in "${segments[@]}"; do
    [[ -n "$out" ]] && out+="${C_DIM} · ${C_RESET}"
    out+="$s"
done
printf '%s' "$out"
