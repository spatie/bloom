#!/usr/bin/env python3
"""Validate production Swift wire vectors with JSON Schema draft 2020-12."""
import argparse
import copy
import importlib.util
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vectors", type=pathlib.Path)
    args = parser.parse_args()
    try:
        from jsonschema import Draft202012Validator, FormatChecker
    except ImportError:
        parser.error("Install jsonschema in a disposable Python environment first.")
    subprocess.run([sys.executable, str(ROOT / "Protocol/generate-schema.py"), "--check"], check=True)
    spec = importlib.util.spec_from_file_location("bloom_schema", ROOT / "Protocol/generate-schema.py")
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    schema = generator.build()
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    vectors = json.loads(args.vectors.read_text())
    if not isinstance(vectors, list) or not vectors:
        raise SystemExit("No production vectors were supplied.")
    for vector in vectors:
        try:
            validator.validate(vector["value"])
        except Exception as error:
            raise SystemExit(f"{vector['name']}: {error}") from error
    # Incomplete safety reports must never validate as a clean archive confirmation.
    archive = next((vector["value"] for vector in vectors if vector["name"] == "reply-archivePreview"), None)
    if archive is None:
        raise SystemExit("Missing archive confirmation contract vector.")
    for section, key in [("report", "hasUncommittedChanges"), ("report", "detachedCommits"),
                         ("hazards", "isAgentRunning"), ("hazards", "isDeletingBranch")]:
        malformed = copy.deepcopy(archive)
        del malformed["result"]["archivePreview"]["_0"][section][key]
        if validator.is_valid(malformed):
            raise SystemExit(f"Schema accepted archive confirmation without {section}.{key}.")
    checked_in = ROOT / "Protocol" / f"vectors-v{generator.VERSION}.json"
    if json.loads(checked_in.read_text()) != vectors:
        raise SystemExit("Production vectors changed. Review and update the checked-in protocol vectors.")
    # Reject malformed framing as well as accepting valid server output.
    for invalid in [
        {"version": generator.VERSION, "id": "not-a-uuid", "operation": {"hello": {}}},
        {"version": generator.VERSION, "id": "00000000-0000-4000-8000-000000000001", "operation": {"hello": {}, "catalogue": {}}},
        {"version": generator.VERSION, "id": "00000000-0000-4000-8000-000000000001", "operation": {"workspace": {"workspaceID": "w", "action": {"deleteEverything": {}}}}},
        *({"version": generator.VERSION, "id": "00000000-0000-4000-8000-000000000001", "operation": {"cleanupStorage": {"targets": targets}}}
          for targets in [[], ["volumes"], ["buildCache", "buildCache"]]),
    ]:
        if validator.is_valid(invalid):
            raise SystemExit("Schema accepted malformed framing.")
    print(f"Validated {len(vectors)} production Swift vectors and 10 malformed-envelope/safety regressions.")


if __name__ == "__main__":
    main()
