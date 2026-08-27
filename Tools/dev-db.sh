#!/bin/zsh
# Puts a copy of the owner's real database into Bloom Dev's own container, so
# the dev copy has his projects, his workspaces and his transcripts to look at.
#
#   ./Tools/dev-db.sh              copy, and detach the worktree paths
#   ./Tools/dev-db.sh --keep-paths copy, and leave the worktree paths pointing
#                                  at the real worktrees. Read the warning
#
# `make dev-db` is the first of those.
#
# IT COPIES OUT. IT NEVER WRITES BACK. There is no flag on this script that
# writes the real database, and adding one is not a small change: the real
# database is open, in WAL mode, in a process the owner is typing into, and a
# file swapped underneath a live connection is a corrupt database rather than an
# old one. If that direction is ever wanted it belongs in its own script, whose
# first act is to refuse while any process is running from ~/Applications/Bloom.app.
#
# THE REAL DATABASE IS NEVER OPENED, ONLY COPIED.
#
# Not even read-only, and this is the part that is easy to get wrong. A WAL
# database cannot be read without a wal-index: the first connection creates or
# attaches `bloom.sqlite-shm` and may run recovery, and SQLite is entitled to
# checkpoint the WAL back into the main file on the last connection closing. All
# of that is writing, inside the container of an app that is running. `sqlite3
# .backup`, `.dump` and `VACUUM INTO` all open the source. `cp` does not, so `cp`
# is what this uses, and everything afterwards happens to the copy.
#
# COPYING bloom.sqlite ALONE GIVES A STALE DATABASE.
#
# In WAL mode the main file is only brought up to date by a checkpoint. Between
# checkpoints, everything committed since the last one lives in `bloom.sqlite-wal`
# and nowhere else. This was measured the hard way earlier today: a copy of the
# main file alone showed two projects that had been deleted hours before, because
# the deletions were still in the WAL. So the WAL and the shared memory index are
# copied too, and then the COPY, which nothing else has open, is checkpointed so
# that what lands in the dev container is one settled file.
#
# A three file copy of a live database can also be torn: the writer can commit,
# or checkpoint, between one `cp` and the next. So the modification times of all
# three are read before and after, the copy is retried while they disagree, and
# the result has `PRAGMA integrity_check` run over it before it is accepted.

set -euo pipefail
cd "$(dirname "$0")/.."
source "$PWD/Tools/guard.sh"

KEEP_PATHS=0
for arg in "$@"; do
  case "$arg" in
    --keep-paths) KEEP_PATHS=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

SOURCE="$BLOOM_REAL_DB"
DEST="$BLOOM_DEV_DB"

# The destination goes through the guard even though it is a constant, so that a
# future edit which makes it an argument inherits the refusal instead of
# needing to remember it.
bloom_refuse_real_db "$DEST"

if [[ ! -f "$SOURCE" ]]; then
  print -ru2 -- "==> no database at $SOURCE"
  exit 1
fi

# The dev copy holds its database open in WAL mode exactly as the real one does,
# so replacing the file underneath it corrupts it. Quit it first. By pid, and
# only ever pids of the dev bundle.
running=($(bloom_app_pids "$BLOOM_DEV_APP"))
if (( ${#running} > 0 )); then
  print -ru2 -- "==> Bloom Dev is running as pid ${running[*]}."
  print -ru2 -- "    Quit it and run this again. Replacing a database under a live"
  print -ru2 -- "    connection corrupts it rather than updating it."
  exit 1
fi

mkdir -p "$BLOOM_DEV_DB_DIR"

# ------------------------------------------------------------------- the copy

# Size and modification time of the three files that make up the database, as one
# string. Missing files are named rather than skipped, so a WAL that appears or
# disappears mid copy is a change like any other.
fingerprint_of_source() {
  local suffix out=""
  for suffix in "" "-wal" "-shm"; do
    if [[ -f "$SOURCE$suffix" ]]; then
      out+="$(/usr/bin/stat -f '%m %z' "$SOURCE$suffix")|"
    else
      out+="absent|"
    fi
  done
  print -r -- "$out"
}

attempt=0
while true; do
  attempt=$((attempt + 1))
  before="$(fingerprint_of_source)"

  rm -f "$DEST" "$DEST-wal" "$DEST-shm"
  cp "$SOURCE" "$DEST"
  if [[ -f "$SOURCE-wal" ]]; then cp "$SOURCE-wal" "$DEST-wal"; fi
  if [[ -f "$SOURCE-shm" ]]; then cp "$SOURCE-shm" "$DEST-shm"; fi

  after="$(fingerprint_of_source)"
  if [[ "$before" == "$after" ]]; then
    # Folds the WAL into the copy and empties it, so the dev container holds one
    # settled database. Safe here and nowhere near the source: nothing else has
    # this file open. TRUNCATE rather than PASSIVE so it cannot half finish.
    #
    # The answer is read rather than sent to /dev/null, because a checkpoint that
    # could not run says so in its answer and not in its exit status. `PRAGMA
    # wal_checkpoint` prints three numbers, the first of which is 1 when it was
    # blocked, and sqlite3 exits 0 all the same; measured on a copy another
    # connection held a read transaction open on, which printed `1|1|0` and
    # exited 0. Sending that to /dev/null turned the only signal that the WAL had
    # actually been folded in into no signal at all, which is precisely the
    # promise the head of this file makes.
    checkpoint="$(/usr/bin/sqlite3 "$DEST" 'PRAGMA wal_checkpoint(TRUNCATE);')"
    if [[ "${checkpoint%%|*}" != "0" ]]; then
      print -ru2 -- "==> attempt $attempt: the copy could not be checkpointed ($checkpoint)"
    else
      check="$(/usr/bin/sqlite3 "$DEST" 'PRAGMA integrity_check;')"
      if [[ "$check" == "ok" ]]; then break; fi
      print -ru2 -- "==> attempt $attempt: the copy failed its integrity check ($check)"
    fi
  else
    print -ru2 -- "==> attempt $attempt: the database changed while it was being copied"
  fi

  if (( attempt >= 5 )); then
    print -ru2 -- "==> gave up after $attempt attempts. Quit Bloom and try again."
    exit 1
  fi
  sleep 1
done

# --------------------------------------------------------- the worktree paths

# Every `workspaces` row carries the absolute path of a real worktree, and the
# copy carries them too. That is the one genuinely dangerous thing about this
# copy, because those directories are not data, they are the owner's work: two
# apps that both believe they manage ~/bloom/workspaces/some-branch can both
# archive it, and archiving deletes the branch and removes the worktree.
#
# So by default the copied rows are pointed at a root that does not exist. The
# dev copy then shows every project, every workspace, every session and every
# transcript, because all of that is in the database, and every destructive
# action fails on a missing directory instead of removing somebody's work. That
# is the trade: a dev copy that is fully realistic to read and inert to act on.
#
# `repos.path` is deliberately NOT rewritten. Those are the real repositories,
# and pointing Bloom Dev at the real Bloom checkout is the entire reason this
# exists. A workspace the dev copy creates for itself is cut fresh, under its own
# name, and only the dev database knows about it, so only the dev copy can
# archive it. It does land under the same workspaces root as the real copy's,
# because `WorkspaceManager.workspacesRoot` has no override: it reads the same
# home directory as the real copy and answers with the same folder, whichever of
# the two names `WorkspacesRoot` picks on this machine. That is a shared parent
# directory, not a shared worktree, and it is the reason `--keep-paths` is not
# the default.
if (( KEEP_PATHS )); then
  cat <<EOF
==> --keep-paths: the copied rows point at the REAL worktrees.

    Bloom Dev and Bloom now both believe they manage the same directories.
    Archiving a workspace in either one deletes the other one's worktree and
    its branch. Read in the dev copy, do not act in it.

EOF
else
  /usr/bin/python3 - "$DEST" "$BLOOM_DEV_WORKSPACES_ROOT" <<'PY'
import os
import sqlite3
import sys

database, root = sys.argv[1], sys.argv[2]
connection = sqlite3.connect(database)
rows = connection.execute("SELECT id, path FROM workspaces").fetchall()
for identifier, path in rows:
    connection.execute(
        "UPDATE workspaces SET path = ? WHERE id = ?",
        (os.path.join(root, os.path.basename(path.rstrip("/"))), identifier),
    )
connection.commit()
connection.close()
print("==> detached %d worktree paths to %s" % (len(rows), root))
PY
  echo "    Nothing in the dev copy now points at a real worktree."
fi

# ------------------------------------------------------------------- the proof

counts="$(/usr/bin/sqlite3 "$DEST" "
  SELECT (SELECT count(*) FROM repos) || ' projects, ' ||
         (SELECT count(*) FROM workspaces) || ' workspaces, ' ||
         (SELECT count(*) FROM sessions) || ' sessions, ' ||
         (SELECT count(*) FROM messages) || ' messages';
")"

echo "==> $DEST"
echo "    $counts"
echo "    from $SOURCE, which was read by cp and opened by nothing"
