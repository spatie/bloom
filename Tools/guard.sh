#!/bin/zsh
# Sourced by the other scripts, never run on its own. The checks that stop a
# script from destroying the app it is running inside, or the data that app is
# holding open.
#
#   source "$(dirname "$0")/guard.sh"
#
# Bloom is now developed inside Bloom. That makes `Tools/master.sh` genuinely
# dangerous: it removes `~/Applications/Bloom.app` and replaces the bundle, then
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
#
# THERE ARE THREE IDENTITIES NOW, WHICH IS WHY THE CONSTANTS ARE A TABLE.
#
# They were six constants in two blocks, one block per identity, and a third
# copy of that block is how the two guards below would have quietly kept
# covering two of the three: every one of them takes an app or a database as an
# argument, so an identity nobody remembered to pass is an identity nobody
# checks. The table is the only place an identity is written down, the guards
# sweep it rather than taking the caller's word for what exists, and adding a
# fourth is four strings.

# The identities, by key. The key is also the `make` target that builds it.
#
#   real  the owner's copy, holding his real projects. Nothing in this
#         repository may write it except `Tools/master.sh`, which is the script
#         whose whole job that is.
#   dev   the copy Bloom is developed in. See Tools/dev-build.sh.
#   ssh   the copy the work on driving agents over SSH runs in, so a build that
#         talks to real servers is never the working copy. Its database is its
#         own because it will hold servers and not just workspaces.
#
# The display name is load bearing twice over: the app bundle is named after it,
# and so is the Application Support directory, because `Store.databaseDirectoryName`
# maps the bundle id to exactly this string. The two have to agree or a copy
# opened by LaunchServices and the same copy started by hand land in different
# databases; `Tests/BloomCoreTests/DatabaseDirectoryTests.swift` is the half of
# that agreement the compiler can hold.
typeset -gA BLOOM_IDENTITY_NAME=(
  real "Bloom"
  dev  "Bloom Dev"
  ssh  "Bloom SSH"
)
typeset -gA BLOOM_IDENTITY_BUNDLE_ID=(
  real "be.spatie.bloom"
  dev  "be.spatie.bloom.dev"
  ssh  "be.spatie.bloom.ssh"
)
# One scheme each, so no copy can swallow a deep link meant for another. The app
# reads the schemes back off its own `CFBundleURLTypes` rather than knowing these,
# so this table and LaunchServices can only ever disagree if the plist does.
typeset -gA BLOOM_IDENTITY_SCHEME=(
  real "bloom"
  dev  "bloomdev"
  ssh  "bloomssh"
)
# How far round the colour wheel the icon is rotated. See Tools/icon/tint.py for
# why these three numbers and not any other three.
typeset -gA BLOOM_IDENTITY_ICON_TURN=(
  real "0"
  dev  "0.5"
  ssh  "0.25"
)
# What goes in front of every window title. The real copy has none, and that is
# the point of the other two having one.
typeset -gA BLOOM_IDENTITY_TITLE_MARK=(
  real ""
  dev  "[DEV] "
  ssh  "[SSH] "
)

# The identities a dev script may install. `real` is deliberately absent and is
# the reason this list exists rather than being read off the table above:
# `bloom_require_installable_app` refuses anything that is not one of these, so
# a DEST that arrived from a typo, a stale environment or an edit made in a
# hurry has to be one of the two copies whose loss costs nobody anything.
BLOOM_INSTALLABLE_IDENTITIES=(dev ssh)

# Where an identity's bundle, container and database are. Derived from the one
# name rather than written out again, because a bundle called one thing and a
# container called another is the failure the derivation exists to prevent.
bloom_identity_name() { print -r -- "${BLOOM_IDENTITY_NAME[$1]-}" }
bloom_identity_app() { print -r -- "$HOME/Applications/${BLOOM_IDENTITY_NAME[$1]-}.app" }
bloom_identity_db_dir() { print -r -- "$HOME/Library/Application Support/${BLOOM_IDENTITY_NAME[$1]-}" }
bloom_identity_db() { print -r -- "$(bloom_identity_db_dir "$1")/bloom.sqlite" }

# Where a detached copy's worktrees are said to be. See Tools/dev-db.sh for why
# the copied rows are pointed here rather than left on the real ones.
#
# Deliberately NOT named to end `.noindex`, which is what a new installation's
# real root is called and why. This path is a fiction: the whole point is that it
# does not exist, so that every destructive action in the copy fails on a
# missing directory. Nothing is ever written here, so there is nothing for
# Spotlight to walk and nothing the suffix would buy, and a name that matched the
# real root would read as somewhere worktrees actually go.
#
# One per identity, because two copies pointed at one fictional root would agree
# about a path again, which is the agreement being broken.
bloom_identity_workspaces_root() { print -r -- "$HOME/bloom-$1/workspaces" }

# Where the owner's real install and real data live. Nothing in this repository
# may write any of these three except the app itself.
BLOOM_REAL_APP="$(bloom_identity_app real)"
BLOOM_REAL_DB_DIR="$(bloom_identity_db_dir real)"
BLOOM_REAL_DB="$(bloom_identity_db real)"
BLOOM_REAL_BUNDLE_ID="${BLOOM_IDENTITY_BUNDLE_ID[real]}"

# The second identity, which the dev scripts are allowed to install to and write.
# Every one of these differs from the trio above, which is what gives the dev
# copy its own container, its own preferences domain, its own saved window state
# and its own tmux socket. Named constants as well as table entries because
# `Tools/dev-db.sh` and `Tools/dev-build.sh` read them by name and because
# `make dev` is the one somebody types without thinking.
BLOOM_DEV_APP="$(bloom_identity_app dev)"
BLOOM_DEV_DB_DIR="$(bloom_identity_db_dir dev)"
BLOOM_DEV_DB="$(bloom_identity_db dev)"
BLOOM_DEV_BUNDLE_ID="${BLOOM_IDENTITY_BUNDLE_ID[dev]}"
BLOOM_DEV_WORKSPACES_ROOT="$(bloom_identity_workspaces_root dev)"

# Selects one identity for the script sourcing this, and refuses anything that is
# not on the installable list.
#
# The refusal is the point rather than the convenience. Every path below is built
# from the key, so an unknown key would otherwise resolve to `$HOME/Applications/
# .app` and `~/Library/Application Support//bloom.sqlite`, and the second of those
# is a real directory: it is `~/Library/Application Support`, which is every
# application's container on this Mac. A misspelled `--identity` must stop the
# script, not name somewhere surprising.
bloom_use_identity() {
  local key="$1" known=0 candidate
  for candidate in "${BLOOM_INSTALLABLE_IDENTITIES[@]}"; do
    [[ "$candidate" == "$key" ]] && known=1
  done
  if (( ! known )); then
    print -ru2 -- "==> unknown identity: $key"
    print -ru2 -- "    The identities a build may install are: ${BLOOM_INSTALLABLE_IDENTITIES[*]}."
    print -ru2 -- "    The owner's own copy is not one of them. See Tools/guard.sh."
    exit 1
  fi

  BLOOM_ID="$key"
  BLOOM_NAME="$(bloom_identity_name "$key")"
  BLOOM_BUNDLE_ID="${BLOOM_IDENTITY_BUNDLE_ID[$key]}"
  BLOOM_SCHEME="${BLOOM_IDENTITY_SCHEME[$key]}"
  BLOOM_ICON_TURN="${BLOOM_IDENTITY_ICON_TURN[$key]}"
  BLOOM_TITLE_MARK="${BLOOM_IDENTITY_TITLE_MARK[$key]}"
  BLOOM_APP="$(bloom_identity_app "$key")"
  BLOOM_DB_DIR="$(bloom_identity_db_dir "$key")"
  BLOOM_DB="$(bloom_identity_db "$key")"
  BLOOM_WORKSPACES_ROOT="$(bloom_identity_workspaces_root "$key")"
}

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
# ~/Applications/Bloom.app is told apart from ~/Applications/Bloom Dev.app and
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

# Which identity, if any, is hosting this shell, as "key<tab>reason".
#
# The two tests above each answer about ONE app that a caller had to name, and
# the caller naming the wrong one is the whole failure mode: it is the run where
# DEST came out somewhere unintended that most needs to know what it is standing
# inside. So this asks the table instead, which is the only list of identities
# there is, and it asks in table order so the owner's real copy is reported
# first when a session is somehow inside more than one.
bloom_hosting_identity() {
  local key app pid
  for key in real dev ssh; do
    app="$(bloom_identity_app "$key")"
    if pid="$(bloom_hosting_pid "$app/Contents/MacOS/Bloom")"; then
      print -r -- "$key	pid $pid is running $app and is an ancestor of this shell (pid $$)"
      return 0
    fi
    if bloom_hosted_tmux "$(bloom_identity_db "$key")"; then
      print -r -- "$key	this shell is a terminal pane of $app, on tmux socket ${TMUX%%,*}"
      return 0
    fi
  done
  return 1
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
#
# Three tests, not two, and the third is not redundant with the first two: those
# are asked about the app and the database the caller passed, and they agree with
# each other only while those two belong to the same identity. A DEST and a
# database that had drifted apart, which is one edit away in any script that
# grows a second identity, would have the pane test asking about the wrong
# socket. The sweep asks the table which copy this shell is actually inside and
# compares that copy's bundle with the one about to be replaced, so it is right
# whatever was passed.
bloom_refuse_if_own_host() {
  local app="$1" db="$2" pid reason="" host hostKey hostReason hostApp

  if pid="$(bloom_hosting_pid "$app/Contents/MacOS/Bloom")"; then
    reason="pid $pid is running $app and is an ancestor of this shell (pid $$)"
  elif bloom_hosted_tmux "$db"; then
    reason="this shell is a terminal pane of $app, on tmux socket ${TMUX%%,*}"
  elif host="$(bloom_hosting_identity)"; then
    hostKey="${host%%	*}"
    hostReason="${host#*	}"
    hostApp="$(bloom_identity_app "$hostKey")"
    if [[ "${hostApp:A}" == "${app:A}" ]]; then
      reason="$hostReason"
    fi
  fi

  [[ -n "$reason" ]] || return 0

  # What is left to build: every installable identity except the one hosting
  # this shell. Printed rather than a fixed "make dev", because that sentence was
  # written when there was one alternative and it is exactly the wrong advice to
  # give somebody sitting inside the copy it names.
  local key keyApp alternatives=""
  for key in "${BLOOM_INSTALLABLE_IDENTITIES[@]}"; do
    keyApp="$(bloom_identity_app "$key")"
    [[ "${keyApp:A}" == "${app:A}" ]] && continue
    alternatives+="      make $key    installs $keyApp
"
  done

  cat >&2 <<EOF
==> refusing: this would replace and kill the app hosting this session.

    $reason

    Replacing that bundle removes files out from under a running process and
    killing it ends this session. Either run this from a terminal outside that
    copy, or build an identity it is not hosting, which cannot touch it:

$alternatives
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
    print -ru2 -- "    Only Tools/master.sh installs there. A dev build installs to one of"
    print -ru2 -- "    ${BLOOM_INSTALLABLE_IDENTITIES[*]} and nowhere else."
    exit 1
  fi
}

# Refuses anything that is not one of the identities a dev build may install.
#
# The check above answers "is this the real app", which is the question worth
# asking while there is one alternative to it. With more than one it is the wrong
# shape: it says what a destination must not be, and every path that is neither
# the real app nor an identity, `~/Applications/Bloom Dve.app` say, passes it and
# then gets an `rm -rf` and a fresh bundle. This says what a destination must BE,
# which is a list of two, and it is called next to the other rather than instead
# of it because the real app not being installable is worth failing on by name.
bloom_require_installable_app() {
  local candidate="$1" key keyApp
  for key in "${BLOOM_INSTALLABLE_IDENTITIES[@]}"; do
    keyApp="$(bloom_identity_app "$key")"
    [[ "${candidate:A}" == "${keyApp:A}" ]] && return 0
  done
  print -ru2 -- "==> refusing: $candidate is not an identity this repository installs."
  print -ru2 -- "    A dev build installs exactly one of:"
  for key in "${BLOOM_INSTALLABLE_IDENTITIES[@]}"; do
    print -ru2 -- "      $(bloom_identity_app "$key")"
  done
  print -ru2 -- "    Anything else is a typo or a stale environment, and it would be removed"
  print -ru2 -- "    and replaced. See the identity table at the head of Tools/guard.sh."
  exit 1
}
