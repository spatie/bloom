#!/usr/bin/env python3
"""Turn a periphery JSON report into something readable in a run summary.

    Tools/periphery-summary.py periphery.json [seconds]

Periphery's own output is one line per finding, and there are several hundred of
them, which is a wall nobody reads twice. What is worth knowing at a glance is
how many there are, of which kind, and where they sit, so that is what this
prints. The full report is kept as an artifact for anyone who wants to work
through it.
"""

import collections
import json
import os
import sys

HINTS = {
    "unused": "Nothing reaches this declaration",
    "assignOnlyProperty": "Written, never read",
    "redundantPublicAccessibility": "Public, but only used inside its own module",
}


def main() -> int:
    path = sys.argv[1]
    seconds = sys.argv[2] if len(sys.argv) > 2 else None
    with open(path) as handle:
        findings = json.load(handle)

    root = os.getcwd() + "/"
    by_hint = collections.Counter()
    by_place = collections.Counter()
    unused = []

    for finding in findings:
        hint = (finding.get("hints") or ["unknown"])[0]
        by_hint[hint] += 1
        where = finding["location"].replace(root, "")
        by_place["/".join(where.split("/")[:2])] += 1
        if hint == "unused":
            unused.append((finding["kind"], finding["name"], where))

    print("### Unused code")
    print()
    print(f"{len(findings)} findings" + (f", scanned in {seconds}s." if seconds else "."))
    print()
    print("| Kind | Count | Means |")
    print("| --- | ---: | --- |")
    for hint, count in by_hint.most_common():
        print(f"| `{hint}` | {count} | {HINTS.get(hint, '')} |")
    print()
    print("| Where | Count |")
    print("| --- | ---: |")
    for place, count in by_place.most_common():
        print(f"| `{place}` | {count} |")
    print()
    print("Not all of these are real. Anything a framework reads and our own code")
    print("never does looks unused from here, `static var description` on every App")
    print("Intent being the obvious case. The full report is attached to this run.")
    print()
    print("<details><summary>The first 40 unreachable declarations</summary>")
    print()
    for kind, name, where in unused[:40]:
        print(f"- `{kind}` **{name}** in `{where}`")
    print()
    print("</details>")
    return 0


if __name__ == "__main__":
    sys.exit(main())
