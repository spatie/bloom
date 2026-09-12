#!/usr/bin/env python3
"""Validate production maintenance DTO vectors and reject malformed update intents."""
import argparse
import copy
import json
import pathlib


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('vectors', type=pathlib.Path)
    args = parser.parse_args()
    try:
        from jsonschema import Draft202012Validator, FormatChecker
    except ImportError:
        parser.error('Install jsonschema in a disposable Python environment first.')
    schema = json.loads(pathlib.Path(__file__).with_name('maintenance-v1.schema.json').read_text())
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    vectors = json.loads(args.vectors.read_text())
    if not isinstance(vectors, list) or not vectors:
        raise SystemExit('No production vectors supplied.')
    for vector in vectors:
        validator.validate(vector['value'])
    malformed = [
        {'action': 'erase'}, {'action': 'prepare'}, {'action': 'prepare', 'component': 'os'},
        {'action': 'start'}, {'action': 'start', 'planID': None},
        {'action': 'start', 'planID': 'p1', 'mode': 'force'}, {'action': 'cancel'},
        {'action': 'status', 'afterSequence': -1},
    ]
    response = next(value['value'] for value in vectors if value['name'] == 'response-queued')
    unknown_phase = copy.deepcopy(response)
    unknown_phase['jobs'][0]['phase'] = 'reconnected'
    malformed.append(unknown_phase)
    missing_auth = copy.deepcopy(response)
    del missing_auth['authorized']
    malformed.append(missing_auth)
    for value in malformed:
        if validator.is_valid(value):
            raise SystemExit('Maintenance schema accepted an invalid intent or outcome.')
    print(f'Validated {len(vectors)} production maintenance DTOs and {len(malformed)} invalid payloads.')


if __name__ == '__main__':
    main()
