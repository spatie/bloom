#!/usr/bin/env python3
"""The scroll lab's data half: the synthetic corpus, the scenario plans, and the reading of traces.

Driven by Tools/scroll-lab.sh, whose head has the workflow. Four commands:

    scroll-lab.py seed <dir>                      a corpus: repositories, worktrees, bloom.sqlite
    scroll-lab.py plan <corpus.json> <out> WxH    the steps one run performs, in order
    scroll-lab.py analyse <trace.ndjson>          one run, judged: metrics and broken invariants
    scroll-lab.py report <runs dir>               every run, as a table, compared across builds

Every string in the corpus is generated here. Nothing is read from a real session, and nothing a
run writes leaves the lab's own temporary directory.

The database is written at schema version zero, which is the first migration's tables and nothing
else. Every revision under comparison has those tables unchanged and migrates forward from there
on open, exactly as an old install would, so one corpus serves a revision from before the
transcript was a table and one from this morning.
"""
import json
import os
import random
import re
import sqlite3
import statistics
import struct
import subprocess
import sys
import uuid
import zlib
from pathlib import Path

COMPACT = dict(separators=(",", ":"))
WORDS = (
    "anchor buffer column cursor delta frame glyph height index layout margin offset "
    "pane query render row scroll table token viewport window wrap budget cache entry "
    "history marker origin reader session spacing thread trace value width"
).split()
SCHEMA_V0 = """
CREATE TABLE repos (id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL UNIQUE,
  default_branch TEXT NOT NULL DEFAULT 'main', accent TEXT NOT NULL DEFAULT '4C8DF6',
  sort_order INTEGER NOT NULL DEFAULT 0, collapsed INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL);
CREATE TABLE workspaces (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
  name TEXT NOT NULL, branch TEXT NOT NULL, path TEXT NOT NULL, base_branch TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'active', setup_state TEXT NOT NULL DEFAULT 'pending',
  setup_log TEXT NOT NULL DEFAULT '', sort_order INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL,
  last_activity_at REAL NOT NULL, archived_at REAL, additions INTEGER NOT NULL DEFAULT 0,
  deletions INTEGER NOT NULL DEFAULT 0, changed_files INTEGER NOT NULL DEFAULT 0,
  unread INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0);
CREATE INDEX workspaces_repo ON workspaces(repo_id, state);
CREATE TABLE sessions (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  title TEXT NOT NULL, agent_session_id TEXT, model TEXT NOT NULL DEFAULT 'opus',
  effort TEXT NOT NULL DEFAULT 'high', permission_mode TEXT NOT NULL DEFAULT 'acceptEdits',
  state TEXT NOT NULL DEFAULT 'idle', sort_order INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL,
  updated_at REAL NOT NULL, archived_at REAL, last_read_seq INTEGER NOT NULL DEFAULT 0,
  input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
  cost_usd REAL NOT NULL DEFAULT 0, context_tokens INTEGER NOT NULL DEFAULT 0);
CREATE INDEX sessions_workspace ON sessions(workspace_id);
CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, seq INTEGER NOT NULL,
  kind TEXT NOT NULL, payload BLOB NOT NULL, created_at REAL NOT NULL, duration_ms INTEGER, ref_id TEXT);
CREATE INDEX messages_session ON messages(session_id, seq);
CREATE INDEX messages_ref ON messages(session_id, ref_id);
"""
FIRST_MARK, LAST_MARK = "LABFIRST", "LABLAST"


# MARK: - Corpus

class Conversation:
    """One session's rows, in order, as the stream-json payloads Claude Code writes."""

    def __init__(self, name, seed):
        self.name = name
        self.rows = []
        self.random = random.Random(seed)
        self.tool_count = 0
        self.unread_from = None
        self.edited = []
        # (start seq, result seq, paths edited) for every turn that gets a checkpoint.
        self.turns = []

    def words(self, count):
        return " ".join(self.random.choice(WORDS) for _ in range(count))

    def sentence(self, count=14):
        text = self.words(count)
        return text[0].upper() + text[1:] + "."

    def paragraph(self, sentences=5):
        return " ".join(self.sentence(self.random.randint(9, 20)) for _ in range(sentences))

    def add(self, kind, payload, ref=None):
        self.rows.append((kind, payload, ref))

    def user(self, text):
        self.add("user", {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": text}]}})

    def assistant(self, text, parent=None):
        self.add("assistantText", {"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "text", "text": text}]}, **self.nesting(parent)})

    def thinking(self, parent=None):
        self.add("thinking", {"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "thinking", "thinking": self.paragraph(2), "signature": "lab"}]}, **self.nesting(parent)})

    def tool(self, name="Bash", parent=None, output_lines=6, finished=True):
        self.tool_count += 1
        ref = f"toolu_lab{self.name}{self.tool_count:06d}"
        inputs = {
            "Bash": {"command": f"swift build --target {self.random.choice(WORDS)}", "description": self.sentence(5)},
            "Read": {"file_path": f"/tmp/lab/{self.random.choice(WORDS)}.swift"},
            "Grep": {"pattern": self.random.choice(WORDS), "path": "Sources"},
            "Edit": {"file_path": f"/tmp/lab/{self.random.choice(WORDS)}.swift",
                     "old_string": self.words(8), "new_string": self.words(9)},
        }.get(name, {"query": self.words(4)})
        if name == "Edit":
            self.edited.append(inputs["file_path"])
        self.add("toolUse", {"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": ref, "name": name, "input": inputs}]}, **self.nesting(parent)}, ref)
        if finished:
            self.tool_result(ref, parent, output_lines)
        return ref

    def tool_result(self, ref, parent=None, output_lines=3):
        output = "\n".join(self.words(10) for _ in range(output_lines))
        self.add("toolResult", {"type": "user", "message": {"role": "user", "content": [
            {"tool_use_id": ref, "type": "tool_result", "content": output, "is_error": False}]},
            **self.nesting(parent)}, ref)

    def result(self):
        self.add("result", {"type": "result", "subtype": "success", "is_error": False, "duration_ms": 42000,
                            "duration_api_ms": 1, "num_turns": 1, "result": "Done.", "session_id": "lab",
                            "total_cost_usd": 0.0, "usage": {"input_tokens": 1, "output_tokens": 1}})

    @staticmethod
    def nesting(parent):
        if not parent:
            return {"parent_tool_use_id": None}
        return {"parent_tool_use_id": parent, "agent_id": f"a{parent[-8:]}",
                "subagent_type": "general-purpose", "task_description": "Lab task"}

    def open(self):
        self.add("system", {"type": "system", "subtype": "init", "cwd": "/tmp/lab", "session_id": "lab",
                            "tools": ["Bash"], "model": "claude-opus-5-5", "permissionMode": "acceptEdits"})
        self.user(f"{FIRST_MARK} {self.name}. " + self.sentence())

    def close(self):
        self.assistant(self.paragraph(2) + f"\n\n{LAST_MARK} {self.name}.")
        self.result()


def markdown_answer(conversation):
    c = conversation
    table = ["| " + " | ".join(c.words(1) for _ in range(5)) + " |", "|" + "---|" * 5]
    table += ["| " + " | ".join(c.words(2) for _ in range(5)) + " |" for _ in range(8)]
    wide = "\n".join("let " + "_".join(c.words(3).split()) + " = " + " + ".join(c.words(28).split())
                     for _ in range(10))
    return "\n\n".join([
        f"## {c.sentence(4)[:-1]}", c.paragraph(3),
        "\n".join(f"- **{c.words(2)}**: {c.sentence(10)}" for _ in range(5)),
        "\n".join(table), "```swift\n" + wide + "\n```",
        "> " + c.sentence(18), f"Use `{c.words(1)}()` and `{c.words(1)}` together. " + c.paragraph(2),
        "1. " + c.sentence(8) + "\n2. " + c.sentence(9) + "\n3. " + c.sentence(7),
    ])


def corpus_court(c):
    c.open()
    c.assistant(c.paragraph(2))
    c.result()
    c.user(c.sentence())
    c.close()


def corpus_texte(c, turns=40):
    c.open()
    for turn in range(turns):
        if turn:
            c.user(" ".join(c.sentence() for _ in range(c.random.randint(1, 3))))
        c.assistant("\n\n".join(c.paragraph(c.random.randint(3, 6)) for _ in range(c.random.randint(3, 7))))
        c.result()
    c.user(c.sentence())
    c.close()


def corpus_markdown(c, turns=25):
    c.open()
    for turn in range(turns):
        if turn:
            c.user(c.sentence())
        c.assistant(markdown_answer(c))
        c.result()
    c.user(c.sentence())
    c.close()


def corpus_sousagents(c, agents=6, nested=120, tail=450):
    """Top level turns that each hand their work to a subagent, whose rows the main transcript draws
    as almost nothing. The live end is one long subagent run, the shape that made the end shorter
    than a pane in yesterday's fix."""
    c.open()
    for _ in range(agents):
        c.assistant(c.paragraph(2))
        agent = c.tool("Agent", finished=False)
        for _ in range(nested):
            c.thinking(parent=agent)
            c.tool("Bash", parent=agent, output_lines=2)
        c.tool_result(agent)
        c.assistant(c.paragraph(3))
        c.result()
        c.user(c.sentence())
    agent = c.tool("Agent", finished=False)
    for step in range(tail):
        c.thinking(parent=agent)
        c.tool("Bash", parent=agent, output_lines=1)
        c.add("system", {"type": "system", "subtype": "task_progress", "task_id": "t", "tool_use_id": agent,
                         "description": "Lab progress", "usage": {"total_tokens": step, "tool_uses": step,
                                                                  "duration_ms": step}})
    c.tool_result(agent)
    c.close()


def corpus_geante(c):
    c.open()
    c.assistant(c.paragraph(3))
    c.result()
    c.user(c.sentence())
    c.assistant("\n\n".join(markdown_answer(c) for _ in range(30)))
    c.result()
    c.user(c.sentence())
    c.close()


def corpus_outils(c, turns=40):
    c.open()
    for turn in range(turns):
        if turn:
            c.user(c.sentence())
        for _ in range(c.random.randint(12, 24)):
            c.tool(c.random.choice(["Bash", "Read", "Grep", "Edit"]), output_lines=c.random.randint(2, 30))
        c.assistant(c.paragraph(2))
        c.result()
    c.user(c.sentence())
    c.close()


def corpus_longue(c, turns=155):
    """The size of a real working day with an agent, about four thousand rows of tool runs and
    answers, so the cost of a pass over every row shows while an agent writes."""
    c.open()
    for turn in range(turns):
        if turn:
            c.user(c.sentence())
        if turn % 3:
            for _ in range(c.random.randint(12, 24)):
                c.tool(c.random.choice(["Bash", "Read", "Grep", "Edit"]), output_lines=c.random.randint(2, 30))
            c.assistant(c.paragraph(2))
        else:
            c.assistant("\n\n".join(c.paragraph(c.random.randint(3, 6)) for _ in range(c.random.randint(2, 5))))
        c.result()
    c.user(c.sentence())
    c.close()


def corpus_pieces(c, worktree, turns=16):
    c.open()
    for turn in range(turns):
        names = []
        for index in range(1 + turn % 3):
            relative = f".bloom/attachments/LAB{turn:03d}/shot-{index}.png"
            write_png(Path(worktree, relative), 900 + 37 * index, 560 + 23 * turn, turn + index)
            names.append(relative)
        c.user(c.sentence() + "\n\nAttached files:\n" + "\n".join(f"- {name}" for name in names))
        c.assistant("\n\n".join(c.paragraph(4) for _ in range(3)))
        c.result()
    c.user(c.sentence())
    c.close()


def corpus_fleuve(c, turns=450):
    """Past the live end's window of 1,200 rows in rows that all draw, so history is windowed,
    trimmed and grown with real heights rather than with subagent rows that draw nothing."""
    c.open()
    for turn in range(turns):
        if turn:
            c.user(c.sentence(c.random.randint(6, 18)))
        c.assistant(c.paragraph(c.random.randint(1, 3)))
        c.result()
    c.user(c.sentence())
    c.close()


def corpus_fichiers(c, turns=30):
    """Short turns that each edit a few files, with the snapshots Bloom reads a footer's files
    from, so several footers on the first screen list them once git has answered."""
    c.open()
    for turn in range(turns):
        if turn:
            c.user(c.sentence())
        start, edited = len(c.rows), len(c.edited)
        for _ in range(c.random.randint(1, 4)):
            c.tool("Edit", output_lines=1)
        c.assistant(c.paragraph(1))
        c.result()
        c.turns.append((start, len(c.rows), c.edited[edited:]))
    c.user(c.sentence())
    c.close()


def corpus_nonlu(c):
    corpus_texte(c, turns=40)
    c.unread_from = len(c.rows) // 2


CORPORA = {
    "court": corpus_court,
    "texte": corpus_texte,
    "markdown": corpus_markdown,
    "sousagents": corpus_sousagents,
    "geante": corpus_geante,
    "outils": corpus_outils,
    "pieces": corpus_pieces,
    "nonlu": corpus_nonlu,
    "direct": lambda c: corpus_texte(c, turns=20),
    "fleuve": corpus_fleuve,
    "longue": corpus_longue,
    "enorme": lambda c: corpus_longue(c, turns=385),
    "fichiers": corpus_fichiers,
}


def write_png(path, width, height, seed):
    """A striped image, so a thumbnail has edges to draw, with no imaging library involved."""
    path.parent.mkdir(parents=True, exist_ok=True)
    colours = [(70 + seed * 13 % 150, 90, 160), (220, 180 - seed * 7 % 120, 90)]
    rows = b"".join(b"\x00" + bytes(colours[(y // 40) % 2]) * width for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows, 6))
                     + chunk(b"IEND", b""))


def git(*arguments, cwd, text=None):
    done = subprocess.run(["git", *arguments], cwd=cwd, check=True, capture_output=True, input=text, text=True)
    return done.stdout.strip()


def checkpoints(conversation, worktree, session_id):
    """Each turn's snapshots as Bloom keeps them, a commit under `refs/bloom/checkpoints/<id>/worktree`
    for before and after, and the records the footer matches to its result row by `endSeq`."""
    blobs, records = {}, []

    def snapshot():
        listing = "".join(f"100644 blob {blob}\t{name}\n" for name, blob in sorted(blobs.items()))
        tree = git("mktree", cwd=worktree, text=listing)
        commit = git("-c", "user.name=Scroll Lab", "-c", "user.email=lab@example.test",
                     "commit-tree", tree, "-m", "Lab snapshot", cwd=worktree)
        identifier = str(uuid.UUID(int=conversation.random.getrandbits(128), version=4))
        git("update-ref", f"refs/bloom/checkpoints/{identifier}/worktree", commit, cwd=worktree)
        return {"id": identifier, "sessionID": session_id, "createdAt": 814000000.0, "indexWasPresent": True}

    for start, end, paths in conversation.turns:
        before = snapshot()
        for path in paths:
            name = Path(path).name
            blobs[name] = git("hash-object", "-w", "--stdin", cwd=worktree, text=conversation.paragraph(2) + "\n")
        records.append({"id": before["id"], "sessionID": session_id, "startSeq": start, "endSeq": end,
                        "before": before, "after": snapshot()})
    return json.dumps(records, **COMPACT)


def seed(directory):
    root = Path(directory).resolve()
    root.mkdir(parents=True, exist_ok=False)
    repo = root / "repo"
    repo.mkdir()
    git("init", "-b", "main", cwd=repo)
    (repo / "README.md").write_text("Scroll lab fixture.\n")
    git("add", ".", cwd=repo)
    git("-c", "commit.gpgsign=false", "-c", "user.name=Scroll Lab", "-c", "user.email=lab@example.test",
        "commit", "-m", "Fixture", cwd=repo)
    database = sqlite3.connect(root / "bloom.sqlite")
    database.executescript(SCHEMA_V0)
    database.execute("PRAGMA user_version = 0")
    now = 1792600000.0
    repo_id = "LAB-REPO-0000"
    database.execute("insert into repos (id, name, path, created_at) values (?,?,?,?)",
                     (repo_id, "Scroll Lab", str(repo), now))
    manifest = {"root": str(root), "corpora": {}}
    for order, (name, build) in enumerate(CORPORA.items()):
        worktree = root / "worktrees" / name
        git("worktree", "add", "-b", f"lab-{name}", str(worktree), cwd=repo)
        workspace_id, session_id = f"LAB-WS-{name.upper()}", f"LAB-SESSION-{name.upper()}"
        conversation = Conversation(name, seed=order)
        if build is corpus_pieces:
            build(conversation, worktree)
        else:
            build(conversation)
        database.execute(
            "insert into workspaces (id, repo_id, name, branch, path, base_branch, state, setup_state, sort_order,"
            " created_at, last_activity_at) values (?,?,?,?,?,?,?,?,?,?,?)",
            (workspace_id, repo_id, name, f"lab-{name}", str(worktree), "main", "active", "done", order, now, now))
        for seq, (kind, payload, ref) in enumerate(conversation.rows, start=1):
            database.execute(
                "insert into messages (session_id, seq, kind, payload, created_at, ref_id) values (?,?,?,?,?,?)",
                (session_id, seq, kind, json.dumps(payload, **COMPACT).encode(), now + seq, ref))
        last_seq = len(conversation.rows)
        if conversation.turns:
            database.execute("create table if not exists settings (key text primary key, value text not null)")
            database.execute("insert into settings (key, value) values (?,?)",
                             (f"turn.checkpoints.{session_id}", checkpoints(conversation, worktree, session_id)))
        read_seq = conversation.unread_from or last_seq
        database.execute(
            "insert into sessions (id, workspace_id, title, agent_session_id, state, created_at, updated_at,"
            " last_read_seq) values (?,?,?,?,?,?,?,?)",
            (session_id, workspace_id, f"Lab {name}", f"lab-agent-{name}", "idle", now, now, read_seq))
        manifest["corpora"][name] = {"workspace": workspace_id, "session": session_id, "rows": last_seq,
                                     "lastReadSeq": read_seq}
    database.commit()
    database.close()
    (root / "corpus.json").write_text(json.dumps(manifest, indent=2))
    print(json.dumps({name: info["rows"] for name, info in manifest["corpora"].items()}))


# MARK: - Plans

LONG = ["texte", "markdown", "sousagents", "geante", "outils", "pieces"]
GESTURES = {
    "molette": {"kind": "wheel", "lines": 2, "burst": 1, "intervalMs": 60},
    "trackpad": {"kind": "trackpad", "flickPoints": 40, "flickFrames": 6, "momentumMs": 700, "pauseMs": 90},
    "frenetique": {"kind": "wheel", "lines": 9, "burst": 3, "intervalMs": 25},
}
CLIMBS = {"molette": ["texte", "sousagents"], "trackpad": LONG, "frenetique": ["markdown", "outils"]}
ALL_SCENARIOS = ["arrivee", "bascule", "molette", "trackpad", "frenetique", "saut", "redimension", "direct", "fleuve",
                 "direct-longue", "retour", "derive"]


def plan(manifest_path, output, size, scenarios):
    corpora = json.loads(Path(manifest_path).read_text())["corpora"]
    width, height = (float(part) for part in size.split("x"))
    steps = []

    def step(kind, label, **fields):
        steps.append({"kind": kind, "label": label, **fields})

    def visit(name, label):
        step("select", label, workspace=corpora[name]["workspace"], session=corpora[name]["session"])

    def place(label, fraction):
        step("wheel", label, direction="up", lines=12, burst=1, intervalMs=16, fraction=fraction,
             until="fraction", timeoutMs=30000)

    if "arrivee" in scenarios:
        for name in corpora:
            visit(name, f"arrivee/{name}/select")
            step("rest", f"arrivee/{name}/rest", ms=2000)
            step("capture", f"arrivee/{name}/capture", ocr=[LAST_MARK])
    if "bascule" in scenarios:
        names = list(corpora)
        for where, fraction in (("fin", None), ("milieu", 0.5), ("haut", 0.0)):
            for name in ["texte", "markdown", "outils", "sousagents"]:
                other = names[(names.index(name) + 1) % len(names)]
                prefix = f"bascule-{where}/{name}"
                visit(name, f"{prefix}/select")
                if fraction is not None:
                    place(f"{prefix}/place", fraction)
                step("rest", f"{prefix}/rest-before", ms=1200)
                step("capture", f"{prefix}/leave")
                visit(other, f"{prefix}/away")
                visit(name, f"{prefix}/back")
                step("rest", f"{prefix}/rest-back", ms=1200)
                step("capture", f"{prefix}/return", compareTo=f"{prefix}/leave")
    for how in ("molette", "trackpad", "frenetique"):
        if how not in scenarios:
            continue
        kind, gesture = GESTURES[how]["kind"], {key: value for key, value in GESTURES[how].items() if key != "kind"}
        for name in CLIMBS[how]:
            visit(name, f"{how}/{name}/select")
            step("wheel", f"{how}/{name}/to-end", direction="down", lines=40, burst=1, intervalMs=16,
                 timeoutMs=20000, holdMs=600)
            step(kind, f"{how}/{name}/up", direction="up", **gesture, timeoutMs=240000)
            step("rest", f"{how}/{name}/rest-top", ms=1500)
            step("capture", f"{how}/{name}/top", ocr=[FIRST_MARK])
            step(kind, f"{how}/{name}/down", direction="down", **gesture, timeoutMs=240000)
            step("rest", f"{how}/{name}/rest-end", ms=1500)
            step("capture", f"{how}/{name}/end", ocr=[LAST_MARK])
    if "saut" in scenarios:
        for name in ["texte", "outils", "sousagents"]:
            visit(name, f"saut/{name}/select")
            step("wheel", f"saut/{name}/read-above", direction="up", lines=6, burst=1, intervalMs=30, until="count",
                 count=40, timeoutMs=10000)
            step("rest", f"saut/{name}/rest-above", ms=1000)
            step("jump", f"saut/{name}/jump")
            step("rest", f"saut/{name}/rest-end", ms=1500)
            step("capture", f"saut/{name}/end", ocr=[LAST_MARK])
    if "redimension" in scenarios:
        for name in ["texte", "markdown"]:
            visit(name, f"redimension/{name}/select")
            place(f"redimension/{name}/place", 0.5)
            step("rest", f"redimension/{name}/rest-before", ms=1000)
            step("resize", f"redimension/{name}/narrow", width=width - 260, height=height)
            step("rest", f"redimension/{name}/rest-narrow", ms=1500)
            step("resize", f"redimension/{name}/wide", width=width, height=height)
            step("rest", f"redimension/{name}/rest-wide", ms=1500)
    if "fleuve" in scenarios:
        prefix = "fleuve/fleuve"
        visit("fleuve", f"{prefix}/select")
        step("rest", f"{prefix}/rest", ms=2000)
        step("capture", f"{prefix}/arrive", ocr=[LAST_MARK])
        for how in ("trackpad", "frenetique"):
            kind, gesture = GESTURES[how]["kind"], {key: value for key, value in GESTURES[how].items() if key != "kind"}
            step(kind, f"{how}/fleuve/up", direction="up", **gesture, timeoutMs=180000)
            step("rest", f"{how}/fleuve/rest-top", ms=1500)
            step("capture", f"{how}/fleuve/top", ocr=[FIRST_MARK])
            step(kind, f"{how}/fleuve/down", direction="down", **gesture, timeoutMs=180000)
            step("rest", f"{how}/fleuve/rest-end", ms=1500)
            step("capture", f"{how}/fleuve/end", ocr=[LAST_MARK])
        place("bascule-milieu/fleuve/place", 0.5)
        step("rest", "bascule-milieu/fleuve/rest-before", ms=1200)
        step("capture", "bascule-milieu/fleuve/leave")
        visit("texte", "bascule-milieu/fleuve/away")
        visit("fleuve", "bascule-milieu/fleuve/back")
        step("rest", "bascule-milieu/fleuve/rest-back", ms=1200)
        step("capture", "bascule-milieu/fleuve/return", compareTo="bascule-milieu/fleuve/leave")
    if "direct" in scenarios:
        live = corpora["direct"]
        visit("direct", "direct/direct/select")
        step("append", "direct/direct/start", session=live["session"], startSeq=live["rows"], intervalMs=350)
        step("rest", "direct/direct/follow", ms=4000)
        step("wheel", "direct/direct/read-above", direction="up", lines=6, burst=1, intervalMs=40, until="count",
             count=12, timeoutMs=10000)
        step("rest", "direct/direct/reading", ms=4000)
        step("appendStop", "direct/direct/stop")
        step("rest", "direct/direct/after", ms=1500)
    if "derive" in scenarios:
        for name in ["texte", "markdown", "outils", "fleuve", "sousagents"]:
            visit(name, f"derive/{name}/select")
            step("rest", f"derive/{name}/rest-before", ms=1500)
            step("drift", f"derive/{name}/drift", points=8, frames=240)
            step("rest", f"derive/{name}/rest-after", ms=1500)
            if name == "markdown":
                for points in (1, 16):
                    step("drift", f"derive/{name}/drift-{points}", points=points, frames=240)
                    step("rest", f"derive/{name}/rest-{points}", ms=1000)
    if "retour" in scenarios:
        # From the end, and from the middle, which is a place only the remembered row can restore.
        for name, fraction in [("longue", None), ("enorme", None), ("geante", None),
                               ("longue", 0.5), ("markdown", 0.5), ("geante", 0.5)]:
            prefix = f"retour/{name}" if fraction is None else f"retour-milieu/{name}"
            visit(name, f"{prefix}/select")
            if fraction is not None:
                place(f"{prefix}/place", fraction)
            step("rest", f"{prefix}/rest-before", ms=6000)
            step("capture", f"{prefix}/leave")
            # Two other workspaces, so this one's column is no longer kept and is built again.
            away, again = [other for other in ("texte", "markdown", "outils") if other != name][:2]
            visit(away, f"{prefix}/away")
            visit(again, f"{prefix}/away-again")
            visit(name, f"{prefix}/back")
            step("rest", f"{prefix}/rest-back", ms=1500)
            step("capture", f"{prefix}/return", compareTo=f"{prefix}/leave")
    if "direct-longue" in scenarios:
        gesture = {key: value for key, value in GESTURES["trackpad"].items() if key != "kind"}
        for name in ["longue", "enorme"]:
            live = corpora[name]
            visit(name, f"direct-longue/{name}/select")
            step("rest", f"direct-longue/{name}/prepare", ms=8000)
            step("append", f"direct-longue/{name}/start", session=live["session"], startSeq=live["rows"], intervalMs=350)
            step("rest", f"direct-longue/{name}/follow", ms=8000)
            step("appendStop", f"direct-longue/{name}/stop")
            step("rest", f"direct-longue/{name}/after", ms=1500)
            step("trackpad", f"trackpad/{name}/up", direction="up", **gesture, timeoutMs=240000)
            step("rest", f"trackpad/{name}/rest-top", ms=1500)
            step("capture", f"trackpad/{name}/top", ocr=[FIRST_MARK])
    Path(output).write_text(json.dumps({"width": width, "height": height, "steps": steps}, indent=1))
    print(f"{len(steps)} steps")


# MARK: - Analysis

STILL = 0.01          # mean brightness difference per band under which two captures are the same page
RASTER = 0.1          # residue, at the same place and with no slide, left by text drawn a device pixel apart
CLEAN_SLIDE = 0.03    # residue under which a non zero shift is the same page, slid
EDGE = 2.0            # points from an edge where rubber banding makes a gesture's distance meaningless
MISSING = -1e8


def percentile(values, share):
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(share * (len(ordered) - 1) + 0.5))]


def frame_stats(frames, zone=None):
    """Frame gaps in milliseconds. With a zone, every gap of the whole sequence whose closing frame
    is in that zone, so leaving a zone and coming back is never read as one long frame."""
    gaps = [(b[0] - a[0]) * 1000 for a, b in zip(frames, frames[1:]) if zone is None or zone_of(b) == zone]
    return {"frames": len(gaps), "p50": percentile(gaps, 0.5), "p95": percentile(gaps, 0.95),
            "p99": percentile(gaps, 0.99), "over16": sum(gap > 16.7 for gap in gaps),
            "over33": sum(gap > 33.4 for gap in gaps), "longest": max(gaps, default=0.0)}


def zone_of(frame):
    _, origin, document, viewport, _ = frame
    reach = document - viewport
    if origin < 0 or reach <= 1:
        return None
    share = origin / reach
    return "debut" if share < 1 / 3 else ("milieu" if share < 2 / 3 else "fin")


def document_moves(frames):
    """How often and how far the document's height changed: what the scroll bar's knob shows."""
    present = [frame for frame in frames if frame[2] >= 0]
    moved = [abs(b[2] - a[2]) for a, b in zip(present, present[1:]) if a[4] == b[4] and abs(b[2] - a[2]) > 0.5]
    return {"count": len(moved), "largest": max(moved, default=0.0), "total": sum(moved)}


def origin_drift(frames):
    present = [frame for frame in frames if frame[2] > 0]
    return max((abs(frame[1] - present[0][1]) for frame in present), default=0.0)


def visible_change(pixels):
    """What two captures of the same place say a reader saw: nothing, a slide, or a change."""
    if not pixels or pixels.get("stillResidue", -1) < 0:
        return None
    if pixels["stillResidue"] <= STILL:
        return None
    if pixels["shift"] and 0 <= pixels["residue"] <= CLEAN_SLIDE:
        return f"glisse de {pixels['shift']} pt"
    return f"change (résidu {pixels['stillResidue']:.2f})"


def slides(shifts, tolerance=2):
    """Clean slides between consecutive captures while a view settled: the content moving on screen
    by more than the two points the protocol allows an anchor once a conversation is shown."""
    return [shift for _, shift, residue, still in shifts
            if still > STILL and abs(shift) > tolerance and 0 <= residue <= CLEAN_SLIDE]


def gesture_checks(events, viewport, catch_up=4):
    """For precise deltas: the row under the middle of the viewport has to move on screen by what the
    events asked for. AppKit sometimes applies one event together with the next, 0 then 80 points
    for two asks of 40, which is a late frame rather than a jump; so an error only counts when the
    next few events do not take it back."""
    errors, reflows = [], 0
    for current, following in zip(events, events[1:]):
        _, requested, precise, before, _, _, document, _, _ = current[:9]
        drift = following[5]
        reach = document - viewport
        near_edge = min(before, following[3]) <= EDGE or reach - max(before, following[3]) <= EDGE
        if drift <= MISSING or not precise or near_edge:
            errors.append(None)
            continue
        if abs(drift) > 2:
            reflows += 1
        errors.append(drift - (following[3] - before) - requested)
    misses, worst, owed, late = 0, 0.0, 0.0, 0
    for error in errors:
        if error is None:
            continue
        owed += error
        late = late + 1 if abs(owed) > 2 else 0
        if late > catch_up:
            misses += 1
            worst = max(worst, abs(owed))
            owed, late = 0.0, 0
    return {"events": len(events), "screenMisses": misses, "worstMiss": worst, "reflowsAbove": reflows,
            "lateEvents": sum(1 for error in errors if error is not None and abs(error) > 2)}


def analyse(path):
    records = [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
    boot = next((record for record in records if record.get("kind") == "boot"), {})
    finished = any(record.get("kind") == "end" for record in records)
    places, left = {}, {}
    workspace = None
    results = []
    for record in (record for record in records if record.get("kind") == "step"):
        step = record["step"]
        if step["kind"] == "select":
            workspace = step.get("workspace")
            reopened = left.get(workspace)
        entry = judge(record, places)
        if step["kind"] == "select" and reopened:
            entry["failures"].extend(reopening_failures(reopened, entry["place"]))
        if step["kind"] == "resize":
            left.clear()
        places[entry["label"]] = entry["place"]
        if workspace and entry["place"].get("found"):
            left[workspace] = entry["place"]
        results.append(entry)
    return {"trace": str(path), "boot": boot, "finished": finished, "steps": results}


def judge(record, places):
    step, result, frames = record["step"], record.get("result", {}), record.get("frames", [])
    label = step.get("label", "")
    scenario, corpus, phase = (label.split("/") + ["", ""])[:3]
    place = record.get("place", {})
    entry = {"label": label, "scenario": scenario, "corpus": corpus, "phase": phase, "kind": step["kind"],
             "seconds": record["t1"] - record["t0"], "frames": frame_stats(frames),
             "document": document_moves(frames), "place": place, "failures": []}
    failures = entry["failures"]
    if result.get("error"):
        failures.append(f"étape impossible : {result['error']}")
    kind = step["kind"]
    if kind in ("wheel", "trackpad"):
        judge_gesture(entry, step, result, frames)
    elif kind in ("select", "jump"):
        entry["arrival"] = {
            "seconds": (result.get("settledAt") or 0) - (result.get("requestedAt") or record["t0"]),
            "slides": slides(result.get("shifts", [])), "documentMoves": entry["document"]["count"]}
        if not result.get("stable", True):
            failures.append("jamais au repos")
        if entry["arrival"]["slides"]:
            failures.append(f"recalage visible x{len(entry['arrival']['slides'])}")
        if kind == "jump" and not result.get("atEnd"):
            failures.append("saut : pas arrivé en bas")
    elif kind in ("rest", "resize"):
        judge_rest(entry, scenario, phase, result, frames, place)
    elif kind == "capture":
        judge_capture(entry, scenario, phase, result, place, places)
    failures.extend(blank_failures(place, entry.get("blank")))
    return entry


def judge_gesture(entry, step, result, frames):
    viewport = entry["place"].get("viewport", 0)
    entry["gesture"] = gesture_checks(result.get("events", []), viewport)
    entry["zones"] = {zone: frame_stats(frames, zone) for zone in ("fin", "milieu", "debut")}
    if step.get("until", "edge") == "edge" and result.get("reachedAt") is None:
        up = step.get("direction") == "up"
        left = entry["place"].get("origin" if up else "fromEnd", 0)
        seconds = step.get("timeoutMs", 0) / 1000
        entry["failures"].append(f"{'haut' if up else 'bas'} non atteint en {seconds:.0f} s (reste {left:.0f} pt)")
    if entry["gesture"]["screenMisses"]:
        entry["failures"].append(f"déplacement à l'écran faux x{entry['gesture']['screenMisses']}"
                                 f" (pire {entry['gesture']['worstMiss']:.0f} pt)")


def judge_rest(entry, scenario, phase, result, frames, place):
    pixels = result.get("pixels")
    entry["rest"] = {"pixels": pixels, "anchorDrift": result.get("anchorDrift"), "blank": result.get("blank"),
                     "originDrift": origin_drift(frames)}
    entry["blank"] = result.get("blank")
    if entry["kind"] == "resize":
        moved = slides(result.get("shifts", []))
        if moved:
            entry["failures"].append(f"recalage visible au redimensionnement x{len(moved)}")
        return
    live = scenario.startswith("direct")
    if live and phase == "follow":
        if place.get("fromEnd", 0) > 4:
            entry["failures"].append(f"décroche du direct ({place['fromEnd']:.0f} pt du bas)")
        return
    # Rows an agent wrote can still land just after it stops, and a reader at the end follows them.
    if live and phase == "after" and place.get("fromEnd", 0) <= 4:
        return
    seen = visible_change(pixels)
    if seen:
        entry["failures"].append(f"bouge au repos : {seen}")


def same_place(left, right):
    keys = ("origin", "document")
    table_keys = ("firstVisible", "visibleCount", "rows")
    return bool(left) and all(left.get(k) == right.get(k) for k in keys) and all(
        (left.get("table") or {}).get(k) == (right.get("table") or {}).get(k) for k in table_keys)


def judge_capture(entry, scenario, phase, result, place, places):
    entry["blank"] = result.get("blank")
    entry["ocr"] = result.get("ocr") or {}
    if phase in ("top", "end"):
        for token, seen in entry["ocr"].items():
            if not seen:
                entry["failures"].append("première ligne invisible en haut" if token == FIRST_MARK
                                         else "dernière ligne invisible en bas")
    pixels = result.get("pixels")
    if pixels and phase == "return":
        entry["return"] = pixels
        left = places.get(entry["label"].replace("/return", "/leave"), {})
        seen = visible_change(pixels)
        if seen and same_place(left, place) and pixels["shift"] == 0 and pixels["stillResidue"] <= RASTER:
            # A cell laid out at another scroll offset can round a text view to the next device
            # pixel: the page is where it was, drawn half a point apart.
            entry["return_raster"] = pixels["stillResidue"]
        elif seen:
            entry["failures"].append(f"retour ailleurs : {seen}")
        if scenario == "bascule-fin" and left.get("fromEnd", 99) <= 4 and place.get("fromEnd", 0) > 4:
            entry["failures"].append(f"retour pas en bas ({place['fromEnd']:.0f} pt du bas)")


def reopening_failures(before, after):
    """A conversation left at its end has to open at its end. Anywhere else, the distance from the
    end is no measure: a table reopened on a window of history holds the same row with fewer rows
    under it, measured, so the pixel comparison of the A to B to A return is what judges those."""
    was, now = before.get("fromEnd"), after.get("fromEnd")
    if was is None or now is None or was > 4 or now <= 4:
        return []
    return [f"rouverte ailleurs ({now:.0f} pt du bas au lieu du bas)"]


def blank_failures(place, blank):
    """A visible stretch with no row in it, or a document that runs on past its last row."""
    failures = []
    document, viewport = place.get("document", 0), place.get("viewport", 0)
    if blank and document > viewport + 1 and blank.get("content") and blank["longest"] > max(220, 0.3 * viewport):
        failures.append(f"zone vide {blank['longest']} pt")
    table = place.get("table")
    if table and document > viewport + 1:
        tail = document - table["lastRowMaxY"]
        if abs(tail) > 1:
            failures.append(f"document ≠ dernière ligne ({tail:+.0f} pt)")
        if table["uncovered"] > 2:
            failures.append(f"{table['uncovered']:.0f} pt sans cellule")
    return failures


# MARK: - Report

def report(directory):
    runs = []
    for trace in sorted(Path(directory).glob("*/run.ndjson")):
        meta_path = trace.with_suffix(".meta.json")
        analysed = analyse(trace)
        analysed["meta"] = json.loads(meta_path.read_text()) if meta_path.exists() else {}
        trace.with_suffix(".analysis.json").write_text(json.dumps(analysed, indent=1))
        runs.append(analysed)
    if not runs:
        raise SystemExit(f"no traces under {directory}")
    builds = list(dict.fromkeys(run["meta"].get("build", "?") for run in runs))
    sizes = sorted({run["meta"].get("size", "?") for run in runs})
    unfinished = [run["trace"] for run in runs if not run["finished"]]
    lines = ["# Labo de scroll", "",
             f"Builds : {', '.join(builds)}. Tailles : {', '.join(sizes)}. Runs : {len(runs)}"
             f" ({len(unfinished)} interrompus). Charge avant chaque run : "
             + ", ".join(f"{run['meta'].get('loadBefore', 0):.1f}" for run in runs) + ".", ""]
    broken = invariant_table(runs, builds, lines)
    fluidity_table(runs, builds, lines)
    arrival_table(runs, builds, lines)
    document_table(runs, builds, lines)
    text = "\n".join(lines)
    Path(directory, "report.md").write_text(text)
    print(text)
    return 1 if broken or unfinished else 0


def by_build(runs, build):
    return [run for run in runs if run["meta"].get("build") == build]


def invariant_table(runs, builds, lines):
    """Scenario by corpus, one cell per build: every distinct failure and how many runs had it."""
    lines += ["## Invariants (scénario × corpus)", "", "Nombre entre parenthèses : runs touchés sur le total.", "",
              "| scénario | corpus | " + " | ".join(builds) + " |", "|---|---|" + "---|" * len(builds)]
    keys = sorted({(entry["scenario"], entry["corpus"]) for run in runs for entry in run["steps"]})
    broken = 0
    for scenario, corpus in keys:
        cells = []
        for build in builds:
            mine = by_build(runs, build)
            seen = {}
            for run in mine:
                names = {re.sub(r" x\d+$", "", failure.split(" (")[0].split(" :")[0])
                         for entry in run["steps"] if (entry["scenario"], entry["corpus"]) == (scenario, corpus)
                         for failure in entry["failures"]}
                for name in names:
                    seen[name] = seen.get(name, 0) + 1
            if seen:
                broken += 1
                cells.append("✗ " + "; ".join(f"{name} ({count}/{len(mine)})" for name, count in sorted(seen.items())))
            else:
                cells.append("✓")
        lines.append(f"| {scenario} | {corpus} | " + " | ".join(cells) + " |")
    lines.append("")
    return broken


def median(values):
    values = [value for value in values if value is not None]
    return statistics.median(values) if values else None


def gesture_runs(runs, build, scenario, zone):
    """Per run, the frames of every up and down leg of one gesture, merged."""
    per_run = []
    for run in by_build(runs, build):
        stats = [entry["frames"] if zone == "tout" else (entry.get("zones") or {}).get(zone)
                 for entry in run["steps"] if entry["scenario"] == scenario and entry["phase"] in ("up", "down")]
        stats = [stat for stat in stats if stat and stat["frames"]]
        if stats:
            per_run.append({key: (sum if key in ("frames", "over16", "over33") else max)(stat[key] for stat in stats)
                            for key in stats[0]})
    return per_run


def fluidity_table(runs, builds, lines):
    lines += ["## Fluidité pendant les gestes (médiane des runs)", "",
              "p50 / p95 / p99 ms, part des frames > 16,7 ms et > 33 ms, plus long blocage du thread principal ms.", "",
              "| geste | zone | " + " | ".join(builds) + " |", "|---|---|" + "---|" * len(builds)]
    for scenario in ("molette", "trackpad", "frenetique"):
        for zone in ("fin", "milieu", "debut", "tout"):
            cells = []
            for build in builds:
                per_run = gesture_runs(runs, build, scenario, zone)
                if not per_run:
                    cells.append("n/a")
                    continue
                pick = lambda key: median([run[key] for run in per_run])
                share = lambda key: 100 * median([run[key] / max(1, run["frames"]) for run in per_run])
                cells.append(f"{pick('p50'):.1f} / {pick('p95'):.1f} / {pick('p99'):.1f}, "
                             f"{share('over16'):.0f} % / {share('over33'):.0f} %, {pick('longest'):.0f}")
            if any(cell != "n/a" for cell in cells):
                lines.append(f"| {scenario} | {zone} | " + " | ".join(cells) + " |")
    lines.append("")


def arrival_table(runs, builds, lines):
    lines += ["## Arrivées à froid (médiane des runs)", "",
              "secondes jusqu'au repos, recalages visibles, changements de hauteur du document", "",
              "| corpus | " + " | ".join(builds) + " |", "|---|" + "---|" * len(builds)]
    corpora = list(dict.fromkeys(entry["corpus"] for run in runs for entry in run["steps"]
                                 if entry["scenario"] == "arrivee"))
    for corpus in corpora:
        cells = []
        for build in builds:
            arrivals = [entry["arrival"] for run in by_build(runs, build) for entry in run["steps"]
                        if entry["label"] == f"arrivee/{corpus}/select"]
            if not arrivals:
                cells.append("n/a")
                continue
            cells.append(f"{median([a['seconds'] for a in arrivals]):.2f} s, "
                         f"{median([len(a['slides']) for a in arrivals]):.0f}, "
                         f"{median([a['documentMoves'] for a in arrivals]):.0f}")
        lines.append(f"| {corpus} | " + " | ".join(cells) + " |")
    lines.append("")


def document_table(runs, builds, lines):
    """The scroll bar resizing: how often the document's height changed during a gesture and in the
    rest after it, and the largest single change."""
    lines += ["## Hauteur du document (la barre de défilement)", "",
              "pendant le geste : changements, plus grand ; au repos qui suit : changements, dérive de l'origine",
              "", "| geste | corpus | " + " | ".join(builds) + " |", "|---|---|" + "---|" * len(builds)]
    keys = list(dict.fromkeys((entry["scenario"], entry["corpus"]) for run in runs for entry in run["steps"]
                              if entry["scenario"] in GESTURES))
    for scenario, corpus in keys:
        cells = []
        for build in builds:
            moving, resting = [], []
            for run in by_build(runs, build):
                steps = [entry for entry in run["steps"] if (entry["scenario"], entry["corpus"]) == (scenario, corpus)]
                moving.append(sum(entry["document"]["count"] for entry in steps if entry["phase"] in ("up", "down")))
                resting.append(sum(entry["document"]["count"] for entry in steps if entry["phase"].startswith("rest")))
                largest = max((entry["document"]["largest"] for entry in steps if entry["phase"] in ("up", "down")),
                              default=0)
                drift = max((entry["rest"]["originDrift"] for entry in steps if "rest" in entry), default=0)
                moving[-1] = (moving[-1], largest)
                resting[-1] = (resting[-1], drift)
            if not moving:
                cells.append("n/a")
                continue
            cells.append(f"{median([m[0] for m in moving]):.0f}, {median([m[1] for m in moving]):.0f} pt ; "
                         f"{median([r[0] for r in resting]):.0f}, {median([r[1] for r in resting]):.0f} pt")
        lines.append(f"| {scenario} | {corpus} | " + " | ".join(cells) + " |")
    lines.append("")


def main():
    command, *arguments = sys.argv[1:] or ["help"]
    if command == "seed":
        seed(arguments[0])
    elif command == "plan":
        manifest, output, size, *scenarios = arguments
        plan(manifest, output, size, scenarios or ALL_SCENARIOS)
    elif command == "analyse":
        print(json.dumps(analyse(arguments[0]), indent=1))
    elif command == "report":
        sys.exit(report(arguments[0]))
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
