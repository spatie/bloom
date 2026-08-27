#!/usr/bin/env python3
"""bloomd: the half of Bloom that lives on your server.

Bloom is a Mac app that runs coding agents in git worktrees. When a workspace lives on a server
rather than on the laptop, Bloom needs answers about that worktree, and asking for them one `git`
at a time over SSH is a network round trip per question: the diff pass alone is over a hundred
processes, and six sequential questions at 20ms each is longer than the work itself. This file is
what makes it one question instead.

Three things it is, and each of them on purpose:

  * **One file, Python 3, no third-party imports.** Python 3 is on every mainstream server
    distribution, so installing this is copying a file. Nothing to build, nothing to `pip install`,
    nothing to keep up to date but the file itself.
  * **No network listener.** It has no port, no socket and no daemon mode, despite the name. Bloom
    speaks to it over the SSH connection it already has: stdin in, stdout out, one process per
    call. Handing an application SSH access to your server is a decision you already took; handing
    it permission to open a port is a different and larger one, and this asks for nothing extra.
  * **Readable.** Somebody who lets an app copy a file onto their server should be able to `cat`
    it and see the whole of what it does. That is why it is Python rather than a compiled binary,
    and it is why this docstring is here.

Usage:

    python3 bloomd version
    python3 bloomd status <worktree> [--base <branch>]

Every command writes one JSON object to stdout and exits 0, or writes one JSON object with
"ok": false and exits 1. `version` is the exception and prints a bare version string, because it
is what an installer compares and a bare string needs no parser.

**What is deliberately not here yet: `run` and `follow`.** Starting an agent on the server and
streaming its output back is the next thing this file grows, and the dispatch table at the foot is
shaped for it: a command is a function taking parsed arguments, and a streaming one will write
newline delimited JSON to stdout and flush after every line rather than returning a blob. Nothing
above needs to change for that to arrive.

This file writes nothing outside the worktree it is pointed at, and reads no credential of any
kind.
"""

import json
import os
import subprocess
import sys

# The one fact an installer compares. Bloom reads this literal out of its own copy of this file,
# runs `bloomd version` on the server, and copies when the two differ. It is a bare string rather
# than a tuple so that both sides compare exactly what is printed.
BLOOMD_VERSION = "1"

# Long enough for a cold index on a large repository, short enough that a wedged git does not hold
# an SSH channel open until Bloom's own timeout kills the connection underneath it.
GIT_TIMEOUT_SECONDS = 60


class Failure(Exception):
    """Something went wrong that the caller should be told about in words."""


def git(worktree, args):
    """Run one git command in a worktree and hand back its stdout as bytes.

    Bytes, not text, and this is not fastidiousness. Git's default output C-quotes any path that
    is not plain ASCII, so `cafe.txt` with an accent comes back as an escaped ASCII string that no
    longer names the file. Every caller below passes `-z`, which turns the quoting off and makes
    NUL the separator, and NUL is the one byte a path cannot contain. Decoding happens once, at
    the end, with surrogateescape, so a path that is not valid UTF-8 survives the trip instead of
    raising.
    """
    command = ["git", "-C", worktree] + list(args)
    environment = dict(os.environ)
    # The diff pass is a reader and must never wait on a writer. Without this, a `git status` run
    # while the user has an editor open takes the index lock and blocks.
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    # No pager, ever: a pager attached to a pipe is a hang.
    environment["GIT_PAGER"] = "cat"
    environment["LC_ALL"] = "C"

    try:
        finished = subprocess.run(
            command,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=GIT_TIMEOUT_SECONDS,
        )
    except FileNotFoundError:
        raise Failure("git is not installed on this server")
    except subprocess.TimeoutExpired:
        raise Failure("git took longer than %d seconds" % GIT_TIMEOUT_SECONDS)

    if finished.returncode != 0:
        message = decode(finished.stderr).strip() or "git exited %d" % finished.returncode
        raise Failure(message)
    return finished.stdout


def decode(raw):
    """Bytes to text without ever raising. See `git` for why the bytes were kept that long."""
    return raw.decode("utf-8", "surrogateescape")


def records(raw):
    """Split `-z` output into its NUL separated records, dropping the empty tail."""
    parts = raw.split(b"\0")
    if parts and parts[-1] == b"":
        parts.pop()
    return parts


# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

def branch_facts(worktree):
    """Head, upstream and how far apart they are, from one `git status`.

    `--porcelain=v2 --branch -z` is asked for rather than three `rev-parse` calls because it is
    one process for facts that must agree with each other: a head read separately from an upstream
    can describe two different moments if a fetch lands between them.
    """
    raw = git(worktree, ["status", "--porcelain=v2", "--branch", "-z"])
    facts = {"head": None, "branch": None, "upstream": None, "ahead": 0, "behind": 0}
    for record in records(raw):
        line = decode(record)
        if not line.startswith("# branch."):
            continue
        key, _, value = line[len("# branch."):].partition(" ")
        if key == "oid" and value != "(initial)":
            facts["head"] = value
        elif key == "head" and value != "(detached)":
            facts["branch"] = value
        elif key == "upstream":
            facts["upstream"] = value
        elif key == "ab":
            # "+3 -1", and either half can be absent on a malformed line.
            for token in value.split():
                if token.startswith("+"):
                    facts["ahead"] = int(token[1:] or 0)
                elif token.startswith("-"):
                    facts["behind"] = int(token[1:] or 0)
    return facts


def merge_base(worktree, base):
    """Where this branch left `base`, or None when there is no such branch here.

    None rather than an exception, because a workspace whose base branch has been deleted is a
    thing that happens and is not a reason for the whole status call to fail. The caller falls
    back to HEAD, which measures uncommitted work only, and says so in the answer.
    """
    for candidate in (base, "origin/" + base):
        try:
            return decode(git(worktree, ["merge-base", "HEAD", candidate])).strip()
        except Failure:
            continue
    return None


def name_status(worktree, since):
    """What happened to each path: added, modified, deleted, renamed, copied.

    `R` and `C` glue a similarity score to the letter and are followed by TWO paths, old then new,
    which is the whole reason this is parsed record by record rather than split on a separator.
    """
    raw = git(worktree, ["diff", "--name-status", "-M", "-z", since, "--"])
    changes = {}
    queue = records(raw)
    index = 0
    while index < len(queue):
        code = decode(queue[index])[:1]
        index += 1
        if code in ("R", "C") and index + 1 < len(queue):
            old = decode(queue[index])
            new = decode(queue[index + 1])
            index += 2
            changes[new] = {"change": "renamed" if code == "R" else "copied", "old_path": old}
        elif index < len(queue):
            path = decode(queue[index])
            index += 1
            changes[path] = {"change": CHANGE_LETTERS.get(code, "modified"), "old_path": None}
        else:
            break
    return changes


CHANGE_LETTERS = {
    "A": "added",
    "M": "modified",
    "D": "deleted",
    "T": "modified",
}


def numstat(worktree, since, changes):
    """Additions and deletions per path.

    A record is `additions TAB deletions TAB path`, except for a rename or a copy, where the path
    field is empty and the old and new paths follow as two records of their own. A binary file
    reports "-" for both counts, which is a fact worth keeping rather than a zero to be silently
    counted.

    Only the first two tabs are separators. A path is allowed to contain one, so the split is
    bounded.
    """
    raw = git(worktree, ["diff", "--numstat", "-M", "-z", since, "--"])
    files = {}
    queue = records(raw)
    index = 0
    while index < len(queue):
        fields = queue[index].split(b"\t", 2)
        index += 1
        if len(fields) != 3:
            continue
        additions = decode(fields[0])
        deletions = decode(fields[1])
        path = decode(fields[2])
        old_path = None
        if fields[2] == b"":
            if index + 1 >= len(queue):
                break
            old_path = decode(queue[index])
            path = decode(queue[index + 1])
            index += 2

        recorded = changes.get(path, {})
        files[path] = {
            "path": path,
            "old_path": recorded.get("old_path") or old_path,
            "change": recorded.get("change") or ("modified" if old_path is None else "renamed"),
            "additions": 0 if additions == "-" else int(additions or 0),
            "deletions": 0 if deletions == "-" else int(deletions or 0),
            "binary": additions == "-",
        }
    return files


def untracked(worktree):
    """Files git has never seen, counted the way git counts a line.

    They belong in the answer whatever it is measured from: a file git does not know about is
    uncommitted against every commit. Every line is a line, and a trailing newline terminates the
    last one rather than starting an empty one, which is the off-by-one that made every untracked
    file read one addition too many the first time Bloom counted them.
    """
    raw = git(worktree, ["ls-files", "--others", "--exclude-standard", "-z"])
    files = {}
    for record in records(raw):
        path = decode(record)
        if not path:
            continue
        full = os.path.join(worktree, path)
        lines = 0
        binary = False
        try:
            with open(full, "rb") as handle:
                content = handle.read()
            if b"\0" in content:
                binary = True
            else:
                lines = content.count(b"\n")
                if content and not content.endswith(b"\n"):
                    lines += 1
        except OSError:
            # A file that vanished between the listing and the read, or one this user cannot open.
            # It is still a changed file, and its line count is the only thing not known.
            binary = True
        files[path] = {
            "path": path,
            "old_path": None,
            "change": "untracked",
            "additions": lines,
            "deletions": 0,
            "binary": binary,
        }
    return files


def command_status(arguments):
    """Everything one diff pass needs about one worktree, in one JSON object.

    This is the whole reason bloomd exists. Bloom's local pass is a merge base, three diffs and a
    line count per untracked file, which is over a hundred processes across a window full of
    workspaces. Over SSH that is over a hundred round trips; here it is one, and the processes are
    started on the machine the repository is already on.
    """
    if not arguments:
        raise Failure("status needs a worktree path")

    worktree = arguments[0]
    base = "main"
    rest = arguments[1:]
    while rest:
        if rest[0] == "--base" and len(rest) > 1:
            base = rest[1]
            rest = rest[2:]
        else:
            raise Failure("unknown argument: %s" % rest[0])

    if not os.path.isdir(worktree):
        raise Failure("no such directory: %s" % worktree)

    facts = branch_facts(worktree)
    since = merge_base(worktree, base)
    changes = name_status(worktree, since or "HEAD")
    files = numstat(worktree, since or "HEAD", changes)
    files.update(untracked(worktree))

    listing = sorted(files.values(), key=lambda entry: entry["path"])
    return {
        "ok": True,
        "version": BLOOMD_VERSION,
        "path": worktree,
        "base": base,
        # Nil when the base branch is not on this server, which is the case the caller has to be
        # able to tell apart: the numbers below are then uncommitted work only.
        "merge_base": since,
        "branch": facts["branch"],
        "head": facts["head"],
        "upstream": facts["upstream"],
        "ahead": facts["ahead"],
        "behind": facts["behind"],
        "changed_files": len(listing),
        "additions": sum(entry["additions"] for entry in listing),
        "deletions": sum(entry["deletions"] for entry in listing),
        "dirty": bool(listing),
        "files": listing,
    }


def command_version(arguments):
    """The version, bare, because an installer compares a string and not a document."""
    del arguments
    sys.stdout.write(BLOOMD_VERSION + "\n")
    return None


# The dispatch table, and the shape the next commands take. A command is a function of the
# arguments after its own name. Returning a dictionary means "print this as JSON and exit 0";
# returning None means the command has already written whatever it had to write, which is what
# `version` does and what a streaming `run` or `follow` will do, one JSON object per line, flushed
# as it goes.
COMMANDS = {
    "version": command_version,
    "status": command_status,
}


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        usage = __doc__.split("Usage:")[1].split("Every command")[0]
        for line in usage.strip().splitlines():
            sys.stdout.write(line.strip() + "\n")
        return 0 if argv else 2

    handler = COMMANDS.get(argv[0])
    if handler is None:
        json.dump({"ok": False, "error": "unknown command: %s" % argv[0]}, sys.stdout)
        sys.stdout.write("\n")
        return 1

    try:
        answer = handler(argv[1:])
    except Failure as failure:
        json.dump({"ok": False, "error": str(failure)}, sys.stdout)
        sys.stdout.write("\n")
        return 1

    if answer is not None:
        # Compact, because this crosses a network on every diff pass, and sorted so that two runs
        # over an unchanged worktree produce identical bytes.
        json.dump(answer, sys.stdout, separators=(",", ":"), sort_keys=True)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
