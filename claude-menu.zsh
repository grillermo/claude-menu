# Wrap `claude` to pick a cswap account via a menu before launching. The menu
# itself is a small Go program (main.go, built next to this file into
# ./claude-menu); it reads the accounts from `cswap list --json`, annotates
# them with live usage, and prints the chosen email, which _run_claude_cswap
# then launches. The claude-personal* functions below stay as direct launchers
# for a specific account, bypassing the menu.
#
# The menu shows up every time, with the account that has the most headroom
# floated to the top. `claude --auto` (alias `clauto`) skips the menu and
# launches straight as that most-headroom account (`clauton` adds
# --new-session), e.g. `clauto "fix the
# failing tests"`. `claude --last` (alias `cla`) does the same with claude's own
# --continue, resuming the newest conversation in this directory. cswap shares
# one chat history across accounts, so which account resumes it doesn't matter.
#
# This file is sourced from ~/c/zsh/programs.zsh (register_fn) and depends on
# nothing else there.

# Run Claude Code under a cswap profile, inside a tmux session named after the
# directory + branch. cswap has no session-naming flag, so we own the tmux
# session ourselves and let cswap just be the command it runs.
#
# A launch reuses the session already there for this directory + branch: it
# attaches to it (any args are dropped, since that Claude is already running).
# --new-session instead gives the launch its own session, suffixing -1, -2, ...
# when the name is taken, so two Claudes can run in the same directory.
#
# --no-tmux skips the session and runs claude right here. Already being inside
# tmux ($TMUX is set) still gets its own session, created detached on the same
# server and switched to, rather than nesting one tmux in another; the pane you
# typed in stays behind at its prompt.
#
# Which of the two can reach the Keychain depends on where you are, and the
# answer flips. cswap reads each account's credential backup out of the login
# Keychain, and those items need an Aqua (GUI) security session: a process in a
# Background session gets "backup is in the macOS Keychain but it is unreadable
# right now". `tmux new-session -d` reparents the command onto the tmux *server*,
# so what matters is the session the server was started in, not this terminal's.
#
#   Sitting at the machine   terminal is Aqua. --no-tmux is the safe one; a tmux
#                            server left over from an SSH login is not.
#   Over SSH                 this terminal is Background -- verify with
#                            `launchctl managername`. --no-tmux FAILS here. Plain
#                            claude-personal works, provided the server was started
#                            from the GUI session.
#
# On the 2015 box that last condition is arranged by a LaunchAgent,
# ~/Library/LaunchAgents/com.grillermo.tmux-server.plist, which sets
# LimitLoadToSessionType=Aqua and starts a `keychain` session at login. One tmux
# server per user means every later mbpssh lands on it and inherits the access.
# Auto-login re-establishes it after a reboot with nothing typed at the machine.
#
# Cheapest check, no API call: `cswap switch <n>` from both sides and compare.
# Pre-answer Claude Code's per-folder consent dialogs for the current
# directory. Trust ("Do you trust the files in this folder?") is answered
# yes everywhere; "Allow external CLAUDE.md file imports?" is answered yes
# only under ~/c (forks there included), so repos elsewhere still ask.
# The flags live in projects["<realpath>"] inside each .claude.json
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

  # --no-tmux and --new-session are ours, not claude's — strip them before
  # anything is forwarded.
  # So is --dangerously-skip-permissions, which we add ourselves; a pane
  # tmux-resurrect relaunches still carries it from the saved argv.
  local -a rest=()
  local use_tmux=1 new_session=0 arg
  for arg in "$@"; do
    case $arg in
      --no-tmux) use_tmux=0 ;;
      --new-session) new_session=1 ;;
      --dangerously-skip-permissions) ;;
      *) rest+=("$arg") ;;
    esac
  done
  set -- "${rest[@]}"

  # An empty profile means the default ~/.claude login, no cswap at all.
  local -a cmd
  if [[ -n $profile ]]; then
    cmd=(cswap run "$profile" -- --dangerously-skip-permissions)
  else
    cmd=(command claude --dangerously-skip-permissions)
  fi

  if (( ! use_tmux )); then
    "${cmd[@]}" "$@"
    return $?
  fi

  # A cold server restores the last tmux-resurrect save first; see
  # _claude_tmux_settle. REPLY=0 means the placeholder session is ours to drop.
  # Inside tmux the server is ours already and has long finished restoring.
  local placeholder=
  if [[ -z $TMUX ]]; then
    _claude_tmux_settle || return $?
    placeholder=$REPLY
  fi

  local base_dir=$(basename "$PWD")
  local branch_name=$(git branch --show-current 2>/dev/null)
  local base

  if [[ -n "$branch_name" ]]; then
    base="claude-${base_dir}-${branch_name}"
  else
    base="claude-${base_dir}"
  fi

  base=${base//[.:\/]/-}

  local session_name=$base
  if (( new_session )); then
    # Dodge collisions with every session currently running.
    local -i n=1
    while tmux has-session -t "=$session_name" 2>/dev/null; do
      session_name="${base}-${n}"
      (( n++ ))
    done
  fi

  # Passing argv as separate words avoids re-quoting through a shell. The zsh
  # wrapper holds the pane open when claude fails immediately (bad --resume id,
  # missing credentials); otherwise the pane would die before we attach and all
  # we'd ever see is tmux's "[exited]".
  if ! tmux has-session -t "=$session_name" 2>/dev/null; then
    tmux new-session -d -s "$session_name" -c "$PWD" \
      zsh -c '"$@"; s=$?; if (( s )); then print -u2 -- "\n[claude exited with status $s - press any key to close]"; read -k1; fi; exit $s' \
      _claude_launch "${cmd[@]}" "$@" || return $?
  fi

  # Only now that our session exists: dropping the last one would stop the server.
  [[ -n $placeholder ]] && tmux kill-session -t "=$placeholder" 2>/dev/null

  # Inside tmux, move this client over; attaching would nest.
  if [[ -n $TMUX ]]; then
    tmux switch-client -t "=$session_name"
  else
    command tmux attach -t "=$session_name"
  fi
}

# When no tmux server is running, the first `tmux new-session` starts one, and
# tmux-continuum (@continuum-restore on) restores the last tmux-resurrect save
# in the background. The restore finishes by calling switch-client to whatever
# session was active at that save, so a session we had just created and attached
# to got yanked away a couple of seconds later: `cla` in ~/c landed in some other
# repo's Claude. Worse, a from-scratch restore overwrites the only pane on the
# server when a saved session has the same name.
#
# So start the server ourselves with a throwaway session named "0", the one
# session a from-scratch restore deletes when it's done, and wait for resurrect's
# post-restore-all hook before creating ours. Sets REPLY to "0" when no restore
# ran and the placeholder is still there for the caller to drop once its own
# session exists; empty otherwise.
_claude_tmux_settle() {
  REPLY=
  # A live server has restored already (or never will), so nothing can move us.
  tmux has-session 2>/dev/null && return 0

  tmux new-session -d -s 0 || return $?
  # Overwrites any hook of your own; ~/.tmux.conf sets none.
  tmux set -g @resurrect-hook-post-restore-all 'tmux set -g @claude-menu-restored 1'

  # Mirror continuum's own checks, so we only wait when a restore is coming.
  # resurrect's save dir: @resurrect-dir, else ~/.tmux/resurrect when present,
  # else the XDG data dir (see tmux-resurrect scripts/helpers.sh).
  local dir
  dir=$(tmux show -gqv @resurrect-dir)
  [[ -z $dir && -d ~/.tmux/resurrect ]] && dir=~/.tmux/resurrect
  : ${dir:=${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect}
  dir=${~dir}
  if [[ $(tmux show -gqv @continuum-restore) != on || -e ~/tmux_no_auto_restore || ! -e $dir/last ]]; then
    REPLY=0
    return 0
  fi

  print -u2 -- "Waiting for tmux-resurrect to restore the saved sessions..."
  # Continuum sleeps 1s before restoring; a dozen sessions take another 2s.
  local -i i
  for (( i = 0; i < 150; i++ )); do
    if [[ $(tmux show -gqv @claude-menu-restored) == 1 ]]; then
      # resurrect leaves "0" alone only when the save itself had a session 0.
      return 0
    fi
    sleep 0.2
  done
  print -u2 -- "tmux-resurrect didn't finish within 30s; starting anyway"
  REPLY=0
}

# Direct launchers for a specific account, bypassing the menu. The menu gets
# its own account list from `cswap list --json`, so these nicknames are only a
# convenience for launching one account by name (e.g. `claude-personal-2`).
# Which accounts the *menu* hides lives in the disabled state file instead
# (~/.config/claude-menu/disabled), toggled by the menu's disable/enable
# actions — see main.go.
typeset -ga CLAUDE_PROFILES=(claude-personal claude-personal-2 claude-personal-3)
typeset -gA CLAUDE_PROFILE_EMAILS=(
  claude-personal   guillermo.siliceo@gmail.com
  claude-personal-2 hola@grillermo.com
  claude-personal-3 claude@grillermo.com
)

claude-personal()   { _run_claude_cswap "$CLAUDE_PROFILE_EMAILS[claude-personal]" "$@" }
claude-personal-2() { _run_claude_cswap "$CLAUDE_PROFILE_EMAILS[claude-personal-2]" "$@" }
claude-personal-3() { _run_claude_cswap "$CLAUDE_PROFILE_EMAILS[claude-personal-3]" "$@" }

# The menu is a Go program built next to this file. Each machine builds its own
# (binaries aren't git-synced), so build lazily: when the ./claude-menu binary
# is missing or older than any source, rebuild it. Needs Go and the chicle
# checkout next door (../chicle, via the replace in go.mod).
typeset -g _CLAUDE_MENU_DIR=${${(%):-%x}:A:h}

_claude_menu_build() {
  local dir=$_CLAUDE_MENU_DIR
  local bin=$dir/claude-menu
  local -a src=($dir/*.go(N) $dir/go.mod(N))
  (( ${#src} )) || { print -u2 -- "claude-menu: no Go sources in $dir"; return 1; }

  # Up to date when the binary exists and nothing is newer than it.
  if [[ -x $bin ]]; then
    local f; local -i stale=0
    for f in $src; do [[ $f -nt $bin ]] && { stale=1; break }; done
    (( stale )) || return 0
  fi

  command -v go > /dev/null 2>&1 || {
    print -u2 -- "claude-menu: Go isn't installed; can't build the picker ($bin)"
    return 1
  }
  print -u2 -- "claude-menu: building the picker…"
  ( cd "$dir" && go build -o claude-menu . ) || {
    print -u2 -- "claude-menu: go build failed"
    return 1
  }
}

# Pick an account and launch it. The Go picker (built above) owns the account
# list, usage, the disabled state file and the disable/enable actions; here we
# just hand it our flags, take the chosen email off stdout, and run it. Quitting
# the picker (empty output / non-zero exit) aborts without launching.
#
#   --auto         let the picker choose the most-headroom account with no UI
#   --unattended   with --auto, when nobody qualifies, take the first account
#                  instead of showing the menu (for headless relaunches)
# Everything after those is claude's own argv: forwarded to the launch, and
# shown in the picker header.
_claude_menu() {
  local -i auto=0 unattended=0
  [[ $1 == --auto ]]       && { auto=1; shift }
  [[ $1 == --unattended ]] && { unattended=1; shift }

  _claude_menu_build || return 1

  local -a flags=()
  (( auto ))       && flags+=(--auto)
  (( unattended )) && flags+=(--unattended)
  [[ -n "$*" ]]    && flags+=(--args "$*")

  local email
  email=$("$_CLAUDE_MENU_DIR/claude-menu" "${flags[@]}") || return $?
  [[ -n $email ]] || return 1

  _run_claude_cswap "$email" "$@"
}

# Whether claude's argv already names what to resume: --resume/-r (with or
# without an id), --resume=<id>, or --continue/-c.
_claude_resumes() {
  local arg
  for arg in "$@"; do
    case $arg in
      --resume|--resume=*|-r|--continue|-c) return 0 ;;
    esac
  done
  return 1
}

# What tmux-resurrect relaunches a saved Claude pane with (the
# "~claude->claude-restore *" entry of @resurrect-processes in ~/.tmux.conf):
# the saved argv minus the binary. Nobody is at the screen, so it never shows
# the account menu: it launches as the account with the most headroom, or the
# first profile when no usage is known. A pane saved with --resume <id> comes
# back with that conversation; one saved without (a fresh `claude`, whose id
# never made it into argv) continues the newest conversation in its directory,
# like `cla`. cswap shares one chat history across accounts, so any account
# can resume any conversation.
claude-restore() {
  _claude_resumes "$@" || set -- "$@" --continue
  # resurrect already put this pane in the right session: run claude in it
  # rather than escaping to a new session and leaving the pane empty.
  _claude_menu --auto --unattended "$@" --no-tmux
}

claude() {
  # --auto and --last are ours: drop them wherever they are. --last is --auto
  # plus claude's own --continue (the newest conversation in this directory).
  local -a auto=()
  if (( ${@[(I)--auto]} )); then
    auto=(--auto)
    set -- "${@:#--auto}"
  fi
  if (( ${@[(I)--last]} )); then
    auto=(--auto)
    set -- "${@:#--last}"
    _claude_resumes "$@" || set -- "$@" --continue
  fi
  _claude_menu "${auto[@]}" "$@"
}
# Functions, not aliases: launchers like Herdr.app run `zsh -c clauton`, which
# doesn't expand aliases. unalias first so re-sourcing in an old shell works.
unalias cla clauto clauton 2>/dev/null
function cla { claude --last "$@"; }
function clauto { claude --auto "$@"; }
function clauton { clauto --new-session "$@"; }

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
