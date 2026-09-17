# Wrap `claude` to pick a cswap profile via an fzf menu before launching. The
# profile functions (claude-personal, claude-personal-2, claude-work) live in
# custom_functions.zsh in the zsh dotfiles repo.
#
# This file is sourced from that repo's aliases.zsh. The wrapper is installed
# under a private name (_claude_menu) so it survives the claude-auto-retry
# snippet in ~/.zshrc, which is sourced *after* aliases.zsh and redefines
# `claude`.

# Selections are logged per-directory so the menu can offer the profile you last
# picked here as the first (default) choice. Capture this file's own dir at
# source time — inside a function $0 is the function name, not this file.
_CLAUDE_SELECT_DIR="${0:A:h}"

# Profile most recently chosen in $PWD, printed on stdout (nothing if none).
_claude_last_profile() {
  local hist="$_CLAUDE_SELECT_DIR/selection-history"
  [[ -r "$hist" ]] || return 1
  awk -F'\t' -v d="$PWD" '$2 == d { p = $3 } END { if (p != "") print p }' "$hist"
}

# Append the chosen profile for $PWD to the history log.
_claude_record_profile() {
  local hist="$_CLAUDE_SELECT_DIR/selection-history"
  mkdir -p "$_CLAUDE_SELECT_DIR" || return
  printf '%s\t%s\t%s\n' "$(date +%s)" "$PWD" "$1" >> "$hist"
}

# Where the usage numbers come from: a small JSON endpoint returning one object
# per account, [{account_email, five_hour_usage, weekly_usage}, ...], with both
# figures as percentages *used*.
: ${CLAUDE_USAGE_URL:=https://my-claude-usage.chiq.me}

# One tab-separated "<email> <5h%> <7d%>" row per account, e.g.
# hola@grillermo.com<TAB>50%<TAB>57%
# Prints nothing (rc 0) when curl/jq are missing or the endpoint is unreachable,
# so the menu degrades to bare emails instead of failing or hanging.
_claude_usage_rows() {
  command -v curl > /dev/null 2>&1 || return 0
  command -v jq   > /dev/null 2>&1 || return 0

  curl -fsS --max-time 3 "$CLAUDE_USAGE_URL" 2>/dev/null | jq -r '
    def pct($v): if $v == null then "--" else "\($v | floor)%" end;

    .[] | [ .account_email, pct(.five_hour_usage), pct(.weekly_usage) ] | @tsv
  ' 2>/dev/null
}

_claude_menu() {
  if ! command -v fzf > /dev/null 2>&1; then
    echo "fzf is not installed. Install with: brew install fzf" >&2
    return 1
  fi

  if (( ! ${#CLAUDE_PROFILES} )); then
    echo "CLAUDE_PROFILES is unset; is custom_functions.zsh sourced?" >&2
    return 1
  fi

  local args="$*"

  # Live 5h/7d usage per account, keyed by the same emails the profile
  # functions pass to cswap. Absent when the usage endpoint has nothing to say.
  local -A pct5 pct7
  local line
  local -a col
  for line in ${(f)"$(_claude_usage_rows)"}; do
    col=("${(@s:	:)line}")
    pct5[$col[1]]=$col[2]; pct7[$col[1]]=$col[3]
  done

  # Rows are labelled by account email — that's what the usage belongs to — but
  # what we invoke is still the profile function, so keep a way back.
  local -A profile_of
  local p e
  # Column widths, seeded with the headers so those never overflow their column.
  local -i wAcct=7 w5=2 w7=2   # len of ACCOUNT / 5H / 7D
  for p in $CLAUDE_PROFILES; do
    e=$CLAUDE_PROFILE_EMAILS[$p]
    profile_of[$e]=$p
    (( ${#e}        > wAcct )) && wAcct=${#e}
    (( ${#pct5[$e]} > w5    )) && w5=${#pct5[$e]}
    (( ${#pct7[$e]} > w7    )) && w7=${#pct7[$e]}
  done

  local -a opts=()
  local row
  for p in $CLAUDE_PROFILES; do
    e=$CLAUDE_PROFILE_EMAILS[$p]
    row=$(printf '%-*s  %*s  %*s' $wAcct "$e" $w5 "$pct5[$e]" $w7 "$pct7[$e]")
    opts+=("${row%"${row##*[![:space:]]}"}")   # drop the padding of empty tail columns
  done

  # Float the last-used-here profile to the top so it's the default selection.
  # The history log still keys on profile names, so map each option back first.
  local last
  last=$(_claude_last_profile)
  if [[ -n "$last" ]]; then
    local -a head rest o
    for o in "$opts[@]"; do
      if [[ "$profile_of[${o%% *}]" == "$last" ]]; then head+=("$o"); else rest+=("$o"); fi
    done
    opts=("$head[@]" "$rest[@]")
  fi

  # fzf prefixes every row with its 2-char pointer, so indent the column
  # headers to match. Args go up here rather than repeated on every row.
  local header="Which Claude account?${args:+  (claude $args)}"
  if (( ${#pct5} )); then
    header+=$(printf '\n  %-*s  %*s  %*s' $wAcct ACCOUNT $w5 5H $w7 7D)
  fi

  # fzf rather than `gum choose` because gum's list wraps around at both ends
  # (up from the top lands on the bottom row) with no flag to turn it off; fzf
  # stops at the ends unless --cycle is passed. --no-sort keeps our ordering,
  # so the last-used-here profile stays pinned to the top even while filtering.
  local choice
  choice=$(printf '%s\n' "$opts[@]" |
    fzf --no-multi --no-sort --reverse --info=hidden \
        --height='~100%' --header "$header") || return $?

  local profile="$profile_of[${choice%% *}]"
  _claude_record_profile "$profile"
  "$profile" "$@"
}
claude() { _claude_menu "$@" }

# ~/.zshrc redefines `claude` (claude-auto-retry) after aliases.zsh loads, so our
# wrapper loses. Reinstall it with a one-shot precmd hook that runs after
# ~/.zshrc finishes, then removes itself to avoid per-prompt overhead.
autoload -Uz add-zsh-hook
_reclaim_claude() {
  claude() { _claude_menu "$@" }
  add-zsh-hook -d precmd _reclaim_claude
  unfunction _reclaim_claude
}
add-zsh-hook precmd _reclaim_claude
