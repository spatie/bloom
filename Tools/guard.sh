#!/bin/zsh
# Sourced by the other scripts, never run on its own. The checks that stop a
# script from destroying the app it is running inside, or the data that app is
# holding open.
#
#   source "$(dirname "$0")/guard.sh"
#
# Bloom is now developed inside Bloom. That makes `Tools/master.sh` genuinely
# dangerous: it removes `/Applications/Bloom.app` and replaces the bundle, then
# kills the process running from it. Run from a session that copy is hosting,
# it ends the agent mid sentence and takes the app the owner is using with it,
# and the `rm -rf` lands on a bundle whose executable is still mapped.
#
# Neither test below reads a flag a caller could set by hand, because a flag is
# exactly what is missing on the run that matters. Both are facts about this
# process:
#
#   bloom_hosting_pid   walks the real parent chain from $$ upwards and compares
#                       each ancestor's executable by absolute path. An agent
#                       session is a `Process` Bloom spawned, so the app is a
#                       genuine ancestor of the shell this runs in.
#   bloom_hosted_tmux   asks whether $TMUX names the private socket that a given
#                       database's instance uses. Terminal panes run under a tmux
#                       server that has already reparented to launchd, so the app
#                       is NOT an ancestor there and the walk above sees nothing.
#                       The socket name is the second, independent answer.
#
# The socket name is derived the same way `TmuxSessions.socketName` derives it,
# from the database path, so an instance pointed at its own `BLOOM_DB_PATH` is
# told apart from the one holding the owner's real workspaces.

# Where the owner's real install and real data live. Nothing in this repository
# may write any of these three except the app itself.
#
# `/Applications`, not `~/Applications`, and that is the owner's own arrangement
# rather than a default: every other app on his Mac is in the system folder and
# the per-user one held nothing but this. It was `$HOME/Applications` here, so
# `master.sh` installed to a path he does not use and this guard protected a
# bundle nobody was running, which is the worst of both: a second Bloom under
# the same bundle id, on the same database, with LaunchServices free to hand a
# `bloom://` link to whichever it liked. The three dev identities below stay in
# `~/Applications` on purpose: they are installed by agents rather than by him,
# and keeping them out of the folder he actually opens is the point of them.
BLOOM_REAL_APP="/Applications/Bloom.app"
BLOOM_REAL_DB_DIR="$HOME/Library/Application Support/Bloom"
BLOOM_REAL_DB="$BLOOM_REAL_DB_DIR/bloom.sqlite"
BLOOM_REAL_BUNDLE_ID="be.spatie.bloom"

# The second identity, which is the only thing the dev scripts are allowed to
# install to or write. Every one of these differs from the pair above, which is
# what gives the dev copy its own container, its own preferences domain, its own
# saved window state and its own tmux socket.
BLOOM_DEV_APP="$HOME/Applications/Bloom Dev.app"
BLOOM_DEV_DB_DIR="$HOME/Library/Application Support/Bloom Dev"
BLOOM_DEV_DB="$BLOOM_DEV_DB_DIR/bloom.sqlite"
BLOOM_DEV_BUNDLE_ID="be.spatie.bloom.dev"

# The third identity, for trying a feature out beside the other two. Same
# separation as the dev copy and for the same reasons: its own container, its own
# preferences domain, its own tmux socket, its own URL scheme. It exists because
# a feature that changes what a workspace IS wants a copy of its own to be wrong
# in, without taking the dev copy's data with it.
BLOOM_SUB_APP="$HOME/Applications/Bloom Subagents.app"
BLOOM_SUB_DB_DIR="$HOME/Library/Application Support/Bloom Subagents"
BLOOM_SUB_DB="$BLOOM_SUB_DB_DIR/bloom.sqlite"
BLOOM_SUB_BUNDLE_ID="be.spatie.bloom.subagents"

# Where a detached dev copy's worktrees are said to be. See Tools/dev-db.sh for
# why the copied rows are pointed here rather than left on the real ones.
#
# Deliberately NOT named to end `.noindex`, which is what a new installation's
# real root is called and why. This path is a fiction: the whole point is that it
# does not exist, so that every destructive action in the dev copy fails on a
# missing directory. Nothing is ever written here, so there is nothing for
# Spotlight to walk and nothing the suffix would buy, and a name that matched the
# real root would read as somewhere worktrees actually go.
BLOOM_DEV_WORKSPACES_ROOT="$HOME/bloom-dev/workspaces"

# The private tmux socket an instance holding this database uses.
#
# FNV-1a over the UTF-8 bytes of the path, which is `TmuxSessions.fingerprint`.
# Python rather than shell arithmetic because the input is a path and paths are
# not guaranteed to be ASCII, and because the Swift hashes bytes, not characters.
bloom_socket_name() {
  /usr/bin/python3 -c '
import sys
h = 2166136261
for b in sys.argv[1].encode("utf-8"):
    h ^= b
    h = (h * 16777619) & 0xFFFFFFFF
print("bloom-%08x" % h)
' "$1"
}

# The pid of the nearest ancestor running the given executable, or nothing.
#
# `ps -o comm=` answers with the absolute path of the executable, so a copy at
# /Applications/Bloom.app is told apart from ~/Applications/Bloom Dev.app and
# from a debug build in .build without any name matching.
bloom_hosting_pid() {
  local target="$1" pid=$$ exe parent
  while [[ -n "$pid" && "$pid" -gt 1 ]]; do
    exe="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    if [[ "$exe" == "$target" ]]; then
      print -r -- "$pid"
      return 0
    fi
    parent="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    [[ -n "$parent" && "$parent" != "$pid" ]] || return 1
    pid="$parent"
  done
  return 1
}

# Whether this shell is a tmux pane belonging to the instance using this database.
bloom_hosted_tmux() {
  [[ -n "${TMUX:-}" ]] || return 1
  local socket="${TMUX%%,*}"
  [[ "${socket:t}" == "$(bloom_socket_name "$1")" ]]
}

# Every pid running the executable inside the given app bundle. Used to report
# what is running, never to kill anything by pattern.
bloom_app_pids() {
  local target="$1/Contents/MacOS/Bloom" pid exe
  ps -axo pid=,comm= | while read -r pid exe; do
    [[ "$exe" == "$target" ]] && print -r -- "$pid"
  done
  return 0
}

# Refuses when replacing or killing this app would take down the process this
# script is a descendant of. `$2` is the database that app runs against, which
# is what names its tmux socket.
#
# It refuses rather than deferring. Deferring would still mean `rm -rf` over a
# bundle whose executable is mapped into a running process, and a half replaced
# bundle is a worse outcome than a script that did nothing.
bloom_refuse_if_own_host() {
  local app="$1" db="$2" pid reason=""

  if pid="$(bloom_hosting_pid "$app/Contents/MacOS/Bloom")"; then
    reason="pid $pid is running $app and is an ancestor of this shell (pid $$)"
  elif bloom_hosted_tmux "$db"; then
    reason="this shell is a terminal pane of $app, on tmux socket ${TMUX%%,*}"
  fi

  [[ -n "$reason" ]] || return 0

  cat >&2 <<EOF
==> refusing: this would replace and kill the app hosting this session.

    $reason

    Replacing that bundle removes files out from under a running process and
    killing it ends this session. Either run this from a terminal outside
    Bloom, or build the second identity instead, which cannot touch the copy
    the owner is using:

      make dev

EOF
  exit 1
}

# Refuses to write the owner's real database. Anything that copies, rewrites or
# restores a database routes its destination through here first.
bloom_refuse_real_db() {
  local candidate="$1"
  local resolved="${candidate:A}"
  if [[ "$resolved" == "${BLOOM_REAL_DB:A}" || "$resolved" == "${BLOOM_REAL_DB:A}"-* ]]; then
    print -ru2 -- "==> refusing: $candidate is the owner's real database."
    print -ru2 -- "    Nothing in Tools/ may write it. Copy out of it, never into it."
    exit 1
  fi
}

# Refuses to install over the owner's real app.
bloom_refuse_real_app() {
  local candidate="$1"
  if [[ "${candidate:A}" == "${BLOOM_REAL_APP:A}" ]]; then
    print -ru2 -- "==> refusing: $candidate is the owner's installed copy."
    print -ru2 -- "    The dev scripts install to $BLOOM_DEV_APP and nowhere else."
    exit 1
  fi
}
