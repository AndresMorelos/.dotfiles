#!/usr/bin/env bash
# Claude Code status line.
#
# Reads the session payload as JSON on stdin and prints one line.
# Payload shape (verified against the 2.1.x binary):
#   .model.display_name
#   .workspace.current_dir | .project_dir | .repo?
#   .output_style.name
#   .cost.total_cost_usd | .total_lines_added | .total_lines_removed
#   .context_window.used_percentage
#   .rate_limits.five_hour.{used_percentage,resets_at}
#   .rate_limits.seven_day.{used_percentage,resets_at}
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
ctx_pct="$(j '.context_window.used_percentage')"
h5_pct="$(j '.rate_limits.five_hour.used_percentage')"
h5_at="$(j '.rate_limits.five_hour.resets_at')"
d7_pct="$(j '.rate_limits.seven_day.used_percentage')"
d7_at="$(j '.rate_limits.seven_day.resets_at')"

# Green while there is room, amber when it is worth noticing, red when it is
# about to change what you can do.
pct_colour() {
    local p="${1%%.*}"
    if [[ "$p" -ge 80 ]]; then
        printf '%s' "$C_WARN"
    elif [[ "$p" -ge 50 ]]; then
        printf '%s' "$C_DIRTY"
    else
        printf '%s' "$C_DIM"
    fi
}

# resets_at may be epoch seconds or an ISO timestamp; if neither parses, say
# nothing rather than print something wrong.
until_reset() {
    local at="$1" target now diff
    [[ -z "$at" ]] && return 0
    if [[ "$at" =~ ^[0-9]+$ ]]; then
        target="$at"
        [[ ${#at} -ge 13 ]] && target=$((at / 1000))
    else
        target="$(date -j -f '%Y-%m-%dT%H:%M:%S' "${at%%.*}" +%s 2>/dev/null)" || return 0
    fi
    [[ -z "$target" ]] && return 0
    now="$(date +%s)"
    diff=$((target - now))
    [[ "$diff" -le 0 ]] && return 0
    if [[ "$diff" -lt 3600 ]]; then
        printf '%dm' $((diff / 60))
    elif [[ "$diff" -lt 86400 ]]; then
        printf '%dh' $((diff / 3600))
    else
        printf '%dd' $((diff / 86400))
    fi
}

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

# --- usage ------------------------------------------------------------------
# Context fill only once it is worth acting on; below half it is just noise.
if [[ -n "$ctx_pct" ]] && [[ "${ctx_pct%%.*}" -ge 50 ]]; then
    segments+=("$(pct_colour "$ctx_pct")$(printf 'ctx %.0f%%' "$ctx_pct")${C_RESET}")
fi

# Plan limits. The reset countdown appears only when the window is nearly
# spent - that is the moment it stops being trivia and starts being a plan.
for w in "5h|$h5_pct|$h5_at" "7d|$d7_pct|$d7_at"; do
    label="${w%%|*}"
    rest="${w#*|}"
    pct="${rest%%|*}"
    at="${rest#*|}"
    [[ -z "$pct" ]] && continue
    seg="$(pct_colour "$pct")$(printf '%s %.0f%%' "$label" "$pct")"
    if [[ "${pct%%.*}" -ge 80 ]]; then
        left="$(until_reset "$at")"
        [[ -n "$left" ]] && seg+=" ${C_DIM}(${left})$(pct_colour "$pct")"
    fi
    segments+=("${seg}${C_RESET}")
done

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
