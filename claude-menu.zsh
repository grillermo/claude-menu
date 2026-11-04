# Wrap `claude` to pick a cswap profile via an fzf menu before launching. The
# profiles (CLAUDE_PROFILES / CLAUDE_PROFILE_EMAILS) and the functions that run
# them (claude-personal, claude-personal-2) are defined below.
#
# The menu shows up every time, with the account that has the most headroom
# floated to the top. `claude --last` (alias `cla`) skips the menu and resumes
# the newest conversation in this directory as the account that had it.
# `claude --auto` (alias `clauto`) skips the menu too and launches straight as
# that most-headroom account, e.g. `clauto "fix the failing tests"`.
#
# This file is sourced from ~/c/zsh/programs.zsh (register_fn) and depends on
# nothing else there.

# Run Claude Code under a cswap profile, right here in this terminal.
#
# cswap reads each account's credential backup out of the login Keychain, and
# those items need an Aqua (GUI) security session: over SSH this terminal is
# Background (verify with `launchctl managername`) and cswap reports "backup is
# in the macOS Keychain but it is unreadable right now".
#
# Cheapest check, no API call: `cswap switch <n>` from both sides and compare.
# Pre-answer Claude Code's per-folder consent dialogs for the current
# directory. Trust ("Do you trust the files in this folder?") is answered
# yes everywhere; "Allow external CLAUDE.md file imports?" is answered yes
# only under ~/c, excluding ~/c/third-parties, so cloned third-party repos
# still ask. The flags live in projects["<realpath>"] inside each .claude.json
# the machine's profiles read (the default login's and every cswap profile's).
# Silent and non-fatal: if python3 or the script is missing, the launch just
# proceeds and the dialog appears once, as before.
_claude_pretrust() {
  command -v python3 >/dev/null 2>&1 || return 0
  local script=$HOME/c/claude-menu/claude-pretrust.py
  [[ -r $script ]] || return 0
  python3 "$script" "$PWD" 2>/dev/null
}

_run_claude_cswap() {
  _claude_pretrust

  local profile=$1
  shift

  # --no-tmux is a leftover from when this ran claude in its own tmux session;
  # old tmux-resurrect saves and habits still pass it, so swallow it. So is
  # --dangerously-skip-permissions, which we add ourselves.
  local -a rest=()
  local arg
  for arg in "$@"; do
    case $arg in
      --no-tmux|--dangerously-skip-permissions) ;;
      *) rest+=("$arg") ;;
    esac
  done
  set -- "${rest[@]}"

  # An empty profile means the default ~/.claude login, no cswap at all.
  if [[ -n $profile ]]; then
    cswap run "$profile" -- --dangerously-skip-permissions "$@"
  else
    command claude --dangerously-skip-permissions "$@"
  fi
}

# Menu order, and the cswap account each profile runs as. `_claude_menu`
# (below) reads both: the emails are how it matches a profile to its live
# usage in `cswap list --json`, so they live here only.
typeset -ga CLAUDE_PROFILES=(claude-personal claude-personal-2 claude-personal-3)
typeset -gA CLAUDE_PROFILE_EMAILS=(
  claude-personal   guillermo.siliceo@gmail.com
  claude-personal-2 hola@grillermo.com
  claude-personal-3 claude@grillermo.com
)

claude-personal()   { _run_claude_cswap "$CLAUDE_PROFILE_EMAILS[claude-personal]" "$@" }
claude-personal-2() { _run_claude_cswap "$CLAUDE_PROFILE_EMAILS[claude-personal-2]" "$@" }
claude-personal-3() { _run_claude_cswap "$CLAUDE_PROFILE_EMAILS[claude-personal-3]" "$@" }

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

# One email per line for the accounts cswap still has. An account deleted from
# cswap can't be launched any more, so this is the source of truth for whether a
# profile in CLAUDE_PROFILES still means anything. Returns non-zero — rather than
# an empty list — when cswap or jq is missing or the listing fails, because "no
# accounts" is itself a real answer the caller has to act on, and a broken lookup
# must not be mistaken for it.
_claude_live_accounts() {
  command -v cswap > /dev/null 2>&1 || return 1
  command -v jq    > /dev/null 2>&1 || return 1
  local json
  json=$(cswap list --json 2>/dev/null) || return 1
  print -r -- "$json" | jq -r '.accounts[].email' 2>/dev/null || return 1
}

# True when either usage window for $1 (an account email) is at 100% or more, so
# it shouldn't be the default. Reads the pct5/pct7 maps out of the
# calling _claude_menu scope; an unknown figure ("--", or no usage at all) is
# not treated as maxed.
_claude_maxed() {
  local v
  for v in "$pct5[$1]" "$pct7[$1]"; do
    [[ "$v" == <->% ]] && (( ${v%\%} >= 100 )) && return 0
  done
  return 1
}

# With --auto as the first arg, launch the account the menu would have
# pre-selected instead of showing it. The menu still appears when no account
# qualifies (usage unknown, or every one maxed), since there is nothing to pick.
_claude_menu() {
  local -i auto=0
  [[ $1 == --auto ]] && { auto=1; shift }

  if (( ! auto )) && ! command -v fzf > /dev/null 2>&1; then
    echo "fzf is not installed. Install with: brew install fzf" >&2
    return 1
  fi

  if (( ! ${#CLAUDE_PROFILES} )); then
    echo "CLAUDE_PROFILES is unset; is claude-menu.zsh sourced?" >&2
    return 1
  fi

  local args="$*"
  local p e

  # The profiles still worth offering: those whose cswap account exists. Deleting
  # an account leaves its profile behind in CLAUDE_PROFILES, and picking it would
  # only fail inside cswap. When cswap can't be read nothing is filtered — see _claude_live_accounts.
  local -a profiles=()
  local -A live
  local -i known=0
  local accounts
  if accounts=$(_claude_live_accounts); then
    known=1
    for e in ${(f)accounts}; do live[$e]=1; done
  fi
  for p in $CLAUDE_PROFILES; do
    e=$CLAUDE_PROFILE_EMAILS[$p]
    [[ -n "$e" ]] || continue
    (( known )) && (( ! ${+live[$e]} )) && continue
    profiles+=("$p")
  done
  if (( ! ${#profiles} )); then
    echo "No profile in CLAUDE_PROFILES still has a cswap account. Run: cswap add" >&2
    return 1
  fi

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
  # Column widths, seeded with the headers so those never overflow their column.
  local -i wAcct=7 w5=2 w7=2   # len of ACCOUNT / 5H / 7D
  for p in $profiles; do
    e=$CLAUDE_PROFILE_EMAILS[$p]
    profile_of[$e]=$p
    (( ${#e}        > wAcct )) && wAcct=${#e}
    (( ${#pct5[$e]} > w5    )) && w5=${#pct5[$e]}
    (( ${#pct7[$e]} > w7    )) && w7=${#pct7[$e]}
  done

  local -a opts=()
  local row
  for p in $profiles; do
    e=$CLAUDE_PROFILE_EMAILS[$p]
    row=$(printf '%-*s  %*s  %*s' $wAcct "$e" $w5 "$pct5[$e]" $w7 "$pct7[$e]")
    opts+=("${row%"${row##*[![:space:]]}"}")   # drop the padding of empty tail columns
  done

  # The default is the account with the most headroom: lowest 5h usage, then
  # lowest weekly, among those not maxed out with both figures known. It's floated to
  # the top, where fzf's cursor starts, and emboldened.
  local best v5 v7 bestKey key
  for p in $profiles; do
    e=$CLAUDE_PROFILE_EMAILS[$p]
    v5=$pct5[$e] v7=$pct7[$e]
    [[ "$v5" == <->% && "$v7" == <->% ]] || continue
    _claude_maxed "$e" && continue
    key=$(printf '%03d%03d' ${v5%\%} ${v7%\%})
    if [[ -z "$best" || "$key" < "$bestKey" ]]; then best=$e bestKey=$key; fi
  done
  if (( auto )); then
    (( ${#profiles} == 1 )) && best=$CLAUDE_PROFILE_EMAILS[$profiles[1]]
    if [[ -n "$best" ]]; then
      print -u2 -- "Launching as $best (${pct5[$best]:---} 5h, ${pct7[$best]:---} 7d)"
      "$profile_of[$best]" "$@"
      return
    fi
    print -u2 -- "No account has known usage below 100%; pick one"
    if ! command -v fzf > /dev/null 2>&1; then
      echo "fzf is not installed. Install with: brew install fzf" >&2
      return 1
    fi
  fi

  (( ${#profiles} > 1 )) || best=
  if [[ -n "$best" ]]; then
    local -a head rest
    local o
    for o in "$opts[@]"; do
      if [[ "${o%% *}" == "$best" ]]; then head+=($'\e[1m'"$o"$'\e[0m'); else rest+=("$o"); fi
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
  # so the default stays pinned to the top even while filtering.
  local choice
  choice=$(printf '%s\n' "$opts[@]" |
    fzf --ansi --no-multi --no-sort --reverse --info=hidden \
        --height='~100%' --header "$header") || return $?

  "$profile_of[${choice%% *}]" "$@"
}

# Every config dir a conversation can live in, one "<email><TAB><dir>" per line:
# the default ~/.claude login first, with an empty email because it runs without
# cswap, then each cswap account's profile. cswap gives every account its own
# CLAUDE_CONFIG_DIR, so transcripts are per-account.
_claude_config_dirs() {
  local tool
  for tool in cswap jq; do
    command -v $tool > /dev/null 2>&1 || { echo "claude-menu needs $tool" >&2; return 1 }
  done

  # cswap's backup root, see claude_swap/paths.py get_backup_root().
  local root=$HOME/.claude-swap-backup
  [[ $OSTYPE == linux* ]] && root=${XDG_DATA_HOME:-$HOME/.local/share}/claude-swap

  local json
  json=$(cswap list --json 2>/dev/null) || { echo "cswap list failed" >&2; return 1 }

  print -r -- $'\t'"${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  # Account profiles live in sessions/<num>-<email-slug>; the number alone is
  # unique, so glob on it rather than re-deriving cswap's slug.
  local num email dir
  for num email in ${(f)"$(print -r -- "$json" | jq -r '.accounts[] | "\(.number)\n\(.email)"')"}; do
    for dir in $root/sessions/${num}-*(N/); do
      print -r -- "$email"$'\t'"$dir"
    done
  done
}

# Resume conversation $1 as $2 (an account email, or empty for the default
# login).
_claude_resume_as() {
  local id=$1 owner=$2
  shift 2
  print -u2 -- "Resuming $id as ${owner:-the default ~/.claude login}"
  _run_claude_cswap "$owner" --resume "$id" "$@"
}

# `claude --last`: resume the newest conversation in this directory, as the
# account that had it: whichever account wrote the newest transcript here.
_claude_resume_last() {
  local dirs
  dirs=$(_claude_config_dirs) || return 1

  # Claude names a project's transcript dir after its cwd with every
  # non-alphanumeric character turned into '-'.
  local slug=${${PWD:A}//[^a-zA-Z0-9]/-}
  local line newest owner
  local -a f
  for line in ${(f)dirs}; do
    f=(${line#*$'\t'}/projects/$slug/*.jsonl(N.om[1]))
    (( $#f )) || continue
    if [[ -z $newest || $f[1] -nt $newest ]]; then newest=$f[1]; owner=${line%%$'\t'*}; fi
  done

  if [[ -z $newest ]]; then
    echo "No Claude conversation found for $PWD" >&2
    return 1
  fi

  _claude_resume_as ${newest:t:r} "$owner" "$@"
}

# `claude --resume <id>`: a conversation belongs to exactly one account, so
# resume it as that account instead of asking. Falls back to `claude --last`
# when no account has the transcript.
_claude_resume_id() {
  local id=$1
  shift
  local dirs
  dirs=$(_claude_config_dirs) || return 1

  local line
  local -a f
  for line in ${(f)dirs}; do
    f=(${line#*$'\t'}/projects/*/$id.jsonl(N.))
    (( $#f )) && { _claude_resume_as "$id" "${line%%$'\t'*}" "$@"; return }
  done

  print -u2 -- "No account has conversation $id; resuming the newest one here instead"
  _claude_resume_last "$@"
}

# Pull a resume id out of claude's argv: sets REPLY to the id (empty if none)
# and reply to the remaining args. Takes --resume <id>, --resume=<id> and
# -r <id>; a bare --resume (claude's own picker) is left in place.
_claude_split_resume() {
  REPLY=
  reply=("$@")
  local -i i
  for (( i = 1; i <= $#reply; i++ )); do
    case $reply[i] in
      --resume=?*) REPLY=${reply[i]#*=}; reply[i]=(); return ;;
      --resume|-r)
        [[ -n $reply[i+1] && $reply[i+1] != -* ]] || continue
        REPLY=$reply[i+1]; reply[i,i+1]=(); return ;;
    esac
  done
}

# What tmux-resurrect relaunches a saved Claude pane with (the
# "~claude->claude-restore *" entry of @resurrect-processes in ~/.tmux.conf):
# the saved argv minus the binary. It never shows the account menu, since
# nobody is at the screen to answer it: a pane saved with --resume <id> comes
# back as the account that owns <id>, and one saved without (a fresh `claude`,
# whose id never made it into argv) resumes the newest conversation in its
# directory, like `cla`.
claude-restore() {
  _claude_split_resume "$@"
  if [[ -n $REPLY ]]; then
    _claude_resume_id "$REPLY" "${reply[@]}"
  else
    _claude_resume_last "${reply[@]}"
  fi
}

claude() {
  # --auto is ours: drop it wherever it is, and only the menu acts on it.
  local -a auto=()
  if (( ${@[(I)--auto]} )); then
    auto=(--auto)
    set -- "${@:#--auto}"
  fi
  if (( ${@[(I)--last]} )); then
    _claude_resume_last "${@:#--last}"
    return
  fi
  _claude_split_resume "$@"
  if [[ -n $REPLY ]]; then
    _claude_resume_id "$REPLY" "${reply[@]}"
  else
    _claude_menu "${auto[@]}" "$@"
  fi
}
alias cla='claude --last'
alias clauto='claude --auto'

# cmux's shell integration redefines claude() from its first precmd hook
# (_cmux_fix_path), after ~/.zshrc has run, which drops --last and the menu.
# This hook is added later, so it runs right after that one: take claude back,
# then remove itself. `command claude` still goes through cmux's PATH shim.
if [[ -n $CMUX_SHELL_INTEGRATION ]]; then
  typeset -g _CLAUDE_MENU_FN=$functions[claude]
  _claude_menu_reclaim() {
    functions[claude]=$_CLAUDE_MENU_FN
    precmd_functions=(${precmd_functions:#_claude_menu_reclaim})
  }
  precmd_functions+=(_claude_menu_reclaim)
fi
