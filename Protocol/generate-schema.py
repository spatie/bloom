#!/usr/bin/env python3
"""Generate the envelope schema. BloomWire.version and Swift case inventories are authoritative."""
import argparse
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION = int(re.search(r"static let version = (\d+)", (ROOT / "Packages/BloomClient/Sources/BloomClient/RemoteCommand.swift").read_text()).group(1))


def obj(properties=None, required=None, extra=False):
    properties = properties or {}
    return {"type": "object", "properties": properties, "required": list(properties) if required is None else required, "additionalProperties": extra}


def ref(name):
    return {"$ref": "#/$defs/" + name}


def array(value):
    return {"type": "array", "items": value}


def optional(value):
    return {"anyOf": [value, {"type": "null"}]}


def cases(values):
    return {"oneOf": [obj({name: payload}) for name, payload in values.items()]}


def payload(value):
    return obj({"_0": value})


S = {"type": "string"}
I = {"type": "integer"}
B = {"type": "boolean"}
U = {"type": "string", "format": "uuid"}
D = {"type": "string", "contentEncoding": "base64"}
R = ref("DomainRecord")
SCOPE = {"enum": ["branch", "uncommitted"]}
workspace_actions = {
    "rename": payload(S), "setPinned": payload(B), "setUnread": payload(B), "setColour": obj({"_0": optional(S)}, []),
    **{name: obj() for name in ["runSetup", "archivePreview", "restore", "files", "pullRequest", "runScripts", "browserAddress", "push", "notes"]},
    "archive": obj({"confirmation": U}), "runScript": obj({"id": S}), "download": obj({"path": S}),
    "writeFile": obj({"path": S, "text": S, "revision": S}), "uploadFile": obj({"name": S, "data": D}),
    "commit": obj({"message": S}), "createPullRequest": obj({"title": S, "body": S, "draft": B}),
    "terminal": obj({"name": S}), "closeTerminal": obj({"name": S}), "saveNotes": payload(S),
    "newSession": obj({"agent": S, "model": S, "effort": S, "permissionMode": S}),
}
project_actions = {
    "rename": payload(S), "setHidden": payload(B), "setAccent": payload(S), "settings": obj(),
    "saveSettings": obj({"edits": array(R), "expected": R}), "filesToCopy": obj({"patterns": array(S)}),
}
creation_actions = {
    "githubRepositories": obj({"query": S, "page": I}), "importGitHub": payload(S), "projectContext": obj(),
    "inspectProject": payload(S), "startProject": obj({"typed": S, "expected": R}),
    "workspaceContext": payload(S), "checkouts": payload(S), "resolveReference": obj({"repoID": S, "reference": S}),
}
answers = {name: obj() for name in ["allowOnce", "allowSession", "allowProject", "deny"]}
answers.update({"denyWithReason": obj({"message": S, "endsTurn": B}), "approvePlan": obj({"mode": S}), "question": obj({"input": {}})})
ui_operations = {
    "attach": obj({"workspaceID": S, "clientID": U, "actions": array(S)}),
    "poll": obj({"leaseID": U, "token": S, "wait": B}),
    "claim": obj({"leaseID": U, "token": S, "requestID": U}),
    "respond": obj({"leaseID": U, "token": S, "requestID": U, "result": ref("UIActionResult")}),
    "detach": obj({"leaseID": U, "token": S}),
}
ui_results = {"attached": payload(ref("UILease")), "requests": payload(ref("UIBatch")), "accepted": obj(), "claimed": payload(B)}
operations = {
    **{name: obj() for name in ["hello", "diagnostics", "storage", "catalogue"]},
    "cleanupStorage": obj({"targets": {"type": "array", "items": {"enum": ["buildCache", "unusedImages"]}, "minItems": 1, "maxItems": 2, "uniqueItems": True}}),
    "reviewSnapshot": obj({"workspaceID": S, "scope": SCOPE, "knownRevision": optional(S), "wait": B}, ["workspaceID", "scope", "wait"]),
    "reviewPatch": obj({"workspaceID": S, "path": S, "scope": SCOPE, "knownRevision": optional(S)}, ["workspaceID", "path", "scope"]),
    "creation": payload(ref("CreationAction")), "previewAddress": payload(S),
    "uiBridge": payload(ref("UIBridgeOperation")),
    "terminalStream": obj({"workspaceID": S, "name": S}), "project": obj({"repoID": S, "action": ref("ProjectAction")}),
    **{name: obj({"sessionID": S}) for name in ["composer", "closeSession", "stop"]},
    "setComposer": obj({"sessionID": S, "controls": ref("ComposerControls")}), "markRead": obj({"sessionID": S, "seq": I}),
    "renameSession": obj({"sessionID": S, "title": S}), "create": payload(ref("WorkspaceRequest")),
    "transcript": obj({"sessionID": S, "afterSeq": I}), "changes": obj({"workspaceID": S, "scope": SCOPE}),
    "patch": obj({"workspaceID": S, "path": S, "scope": SCOPE}), "file": obj({"workspaceID": S, "path": S}),
    "workspace": obj({"workspaceID": S, "action": ref("WorkspaceAction")}),
    "configure": obj({"sessionID": S, "model": S, "effort": S, "permissionMode": S}),
    "send": obj({"sessionID": S, "text": S, "retryDeliveryID": optional(S)}, ["sessionID", "text"]), "cancelQueued": obj({"sessionID": S, "deliveryID": S}),
    "answer": obj({"sessionID": S, "requestID": S, "answer": ref("Answer")}),
}
changed = obj({"path": S, "oldPath": optional(S), "change": {"enum": ["A", "M", "D", "R", "C", "?"]},
               "additions": I, "deletions": I, "isBinary": B, "contentRevision": optional(S), "hasIncompleteStats": B},
              ["path", "change", "additions", "deletions", "isBinary", "hasIncompleteStats"], True)
message = obj({"id": I, "sessionID": S, "seq": I, "kind": S, "payload": D, "createdAt": {"type": "number"},
               "durationMS": optional(I), "refID": optional(S)}, ["id", "sessionID", "seq", "kind", "payload", "createdAt"], True)
results = {
    "hello": obj({"name": S}), "accepted": obj(), "failure": payload(S),
    "uiBridge": payload(ref("UIBridgeResult")),
    **{name: payload(S) for name in ["patch", "text"]}, "changes": payload(array(ref("ChangedFile"))),
    "files": payload(array(S)), "file": payload(ref("TextFile")), "download": payload(obj({"path": S, "data": D})),
    "reviewSnapshot": payload(obj({"revision": S, "files": optional(array(ref("ChangedFile")))}, ["revision"])),
    "reviewPatch": payload(obj({"revision": S, "patch": optional(S)}, ["revision"])),
    "catalogue": payload(obj({"repositories": array(ref("Repository")), "workspaces": array(ref("Workspace")), "sessions": array(ref("Session")), "archivedWorkspaces": array(ref("Workspace"))})),
    "transcript": payload(obj({"session": ref("Session"), "messages": array(ref("Message")), "pendingQuestions": array(D), "isBusy": B,
                               "streamingText": S, "permissionDecisions": {"type": "object", "additionalProperties": S},
                               "queuedPrompts": array(ref("QueuedPrompt")), "queueError": optional(S)},
                              ["session", "messages", "pendingQuestions", "isBusy", "streamingText", "permissionDecisions", "queuedPrompts"])),
    "created": obj({"session": ref("Session"), "workspace": ref("Workspace"), "setupSucceeded": optional(B)}, ["session", "workspace"]),
    "composer": payload(ref("ComposerState")),
    "creation": payload(ref("CreationResult")), "terminal": payload(obj({"executable": S, "socket": S, "session": S})),
    "terminalPane": payload(obj({"id": S, "title": S})), "runScripts": payload(array(R)),
    "archivePreview": payload(ref("ArchivePreview")),
    "diagnostics": payload(ref("ServerDiagnostics")),
    "storage": payload(ref("ServerStorageReport")), "storageCleanup": payload(ref("ServerStorageCleanupResult")),
    **{name: payload(R) for name in ["projectSettings", "filesToCopy"]},
}
creation_results = {name: payload(R) for name in ["project", "projectContext", "inspection", "workspaceContext", "checkouts", "reference"]}
creation_results["repositories"] = payload(array(R))
creation_results["workspaceStarted"] = obj({"workspace": R, "session": optional(R), "setupSucceeded": optional(B), "draft": optional(S)}, ["workspace"])


def swift_cases(path, enum):
    source = (ROOT / path).read_text().split("public enum " + enum + ":", 1)[1].split("\n}", 1)[0]
    result = {}
    for name, arguments in re.findall(r"^    case (\w+)(?:\((.*)\))?$", source, re.M):
        fields = []
        for index, argument in enumerate(arguments.split(",") if arguments else []):
            fields.append(argument.split(":", 1)[0].strip() if ":" in argument else f"_{index}")
        result[name] = set(fields)
    return result


def build():
    example = ROOT / "Protocol/examples/bloom_client.py"
    if example.exists():
        example_version = int(re.search(r"^VERSION = (\d+)$", example.read_text(), re.M).group(1))
        if example_version != VERSION:
            raise SystemExit("Update the standalone Python example to BloomWire.version")
    inventories = [("Packages/BloomClient/Sources/BloomClient/Bridge/RemoteUIBridge.swift", "RemoteUIBridgeOperation", ui_operations),
                   ("Packages/BloomClient/Sources/BloomClient/Bridge/RemoteUIBridge.swift", "RemoteUIBridgeResult", ui_results), ("Sources/BloomCore/Server/ServerProtocol.swift", "ServerOperation", operations),
                   ("Sources/BloomCore/Server/ServerProtocol.swift", "ServerResult", results),
                   ("Sources/BloomCore/Server/ServerProtocol.swift", "ServerAnswer", answers),
                   ("Sources/BloomCore/Server/ServerWorkspaceAction.swift", "ServerWorkspaceAction", workspace_actions),
                   ("Sources/BloomCore/Server/ServerSidebar.swift", "ServerProjectAction", project_actions),
                   ("Sources/BloomCore/Server/ServerCreation.swift", "ServerCreationOperation", creation_actions),
                   ("Sources/BloomCore/Server/ServerCreation.swift", "ServerCreationResult", creation_results)]
    for path, enum, values in inventories:
        actual = swift_cases(path, enum)
        if set(actual) != set(values):
            raise SystemExit(f"Update schema for {enum}: missing {set(actual) - set(values)}, removed {set(values) - set(actual)}")
        for name, fields in actual.items():
            documented = set(values[name].get("properties", {}))
            if fields != documented:
                raise SystemExit(f"Update schema arguments for {enum}.{name}: Swift {fields}, schema {documented}")
    workspace = obj({"repositoryPath": S, "name": S, "agent": S, "model": S, "effort": S, "permissionMode": S,
                     "prompt": optional(S), "baseBranch": optional(S), "checkout": optional(R), "controls": optional(ref("ComposerControls")),
                     "mode": optional(S), "runSetupScript": optional(B),
                     "attachments": optional(array(obj({"sourcePath": S, "name": S, "data": D})))},
                    ["repositoryPath", "name", "agent", "model", "effort", "permissionMode"])
    return {"$schema": "https://json-schema.org/draft/2020-12/schema", "$id": f"https://runbloom.app/protocol/bloom-v{VERSION}.schema.json",
            "title": f"Bloom server protocol {VERSION}",
            "description": "Envelope and method schema, with full review/transcript framing. DomainRecord deliberately permits evolving application records; see SERVER-PROTOCOL.md and Swift source references.",
            "oneOf": [ref("Request"), ref("Reply")],
            "$defs": {
                "Request": obj({"version": {"const": VERSION}, "id": U, "operation": ref("Operation")}),
                "Reply": obj({"version": {"const": VERSION}, "id": U, "result": ref("Result")}),
                "Operation": cases(operations), "Result": cases(results), "WorkspaceAction": cases(workspace_actions),
                "ProjectAction": cases(project_actions), "CreationAction": cases(creation_actions), "CreationResult": cases(creation_results),
                "Answer": cases(answers), "WorkspaceRequest": workspace, "ChangedFile": changed, "Message": message,
                "QueuedPrompt": obj({"id": S, "text": S}),
                "ArchivePreview": obj({"id": U, "workspace": ref("Workspace"), "report": ref("WorkspaceSafetyReport"),
                                       "hazards": ref("ArchiveHazards"), "createdAt": {"type": "number"}}),
                "ArchiveHazards": obj({"isAgentRunning": B, "isPullRequestMerged": B, "isDeletingBranch": B}),
                "WorkspaceSafetyReport": obj({"hasUncommittedChanges": B, "untrackedFiles": array(S), "unpushedCommits": I,
                                              "isBranchMerged": B, "modifiedIgnoredFiles": array(S), "detachedCommits": I,
                                              "preservedFolderPath": optional(S)},
                                             ["hasUncommittedChanges", "untrackedFiles", "unpushedCommits", "isBranchMerged",
                                              "modifiedIgnoredFiles", "detachedCommits"]),
                "TextFile": obj({"path": S, "text": S, "revision": S}),
                "Repository": obj({"id": S, "name": S, "path": S, "defaultBranch": S, "hidden": B, "accent": S}, extra=True),
                "Workspace": obj({"id": S, "repoID": S, "name": S, "path": S, "branch": S, "baseBranch": S,
                                  "state": S, "setupState": S, "setupLog": S, "port": I}, extra=True),
                "Session": obj({"id": S, "workspaceID": optional(S), "title": S, "model": S, "effort": S, "agentKind": S,
                                "permissionMode": S, "state": S, "createdAt": {"type": "number"}, "updatedAt": {"type": "number"}},
                               ["id", "title", "model", "effort", "agentKind", "permissionMode", "state", "createdAt", "updatedAt"], True),
                "ComposerControls": obj({"model": S, "effort": S, "agentKind": S, "permissionMode": S, "isFastMode": B,
                                         "outputStyle": S, "codexContextWindow": I, "hasWorktree": B}, extra=True),
                "ComposerState": obj({"controls": ref("ComposerControls"), "models": array(R), "commands": array(R), "styles": array(R),
                                      "availableAgents": optional(array(S)), "authentication": optional(array(ref("AgentAuthentication")))}, ["controls", "models", "commands", "styles"], True),
                "AgentAuthentication": obj({"agent": S, "state": {"enum": ["ready", "signInRequired", "unavailable", "unknown"]}}),
                "ServerStorageReport": obj({"checkedAt": {"type": "number"}, "totalBytes": optional(I), "freeBytes": optional(I),
                                            "dockerState": {"enum": ["ready", "unavailable", "failed"]}, "dockerMessage": optional(S),
                                            "usage": array(ref("ServerStorageUsage")), "notes": array(S)}, ["checkedAt", "dockerState", "usage", "notes"], True),
                "ServerStorageUsage": obj({"kind": S, "totalCount": optional(I), "activeCount": optional(I), "sizeLabel": S,
                                           "reclaimableLabel": optional(S)}, ["kind", "sizeLabel"], True),
                "ServerStorageCleanupOutcome": obj({"target": {"enum": ["buildCache", "unusedImages"]},
                                                    "status": {"enum": ["completed", "uncertain", "failed"]}, "message": S,
                                                    "reclaimedLabel": optional(S)}, ["target", "status", "message"], True),
                "ServerStorageCleanupResult": obj({"outcomes": array(ref("ServerStorageCleanupOutcome")),
                                                   "report": optional(ref("ServerStorageReport")), "interrupted": B}, ["outcomes", "interrupted"], True),
                "ServerDiagnostics": obj({"checkedAt": {"type": "number"}, "hostname": S, "operatingSystem": S,
                                          "account": S, "checks": array(R), "browser": optional(R),
                                          "authentication": optional(array(ref("AgentAuthentication"))), "storageManagement": optional(B)},
                                         ["checkedAt", "hostname", "operatingSystem", "account", "checks"], True),
                "UIBridgeOperation": cases(ui_operations), "UIBridgeResult": cases(ui_results),
                "UILease": obj({"id": U, "token": S, "workspaceID": S, "expiresAtMilliseconds": I}),
                "UIAction": obj({"name": S, "arguments": {"type": "object"}}),
                "UIRequest": obj({"id": U, "workspaceID": S, "action": ref("UIAction"), "expiresAtMilliseconds": I}),
                "UIBatch": obj({"lease": ref("UILease"), "requests": array(ref("UIRequest"))}),
                "UIActionResult": obj({"text": S, "isError": B, "value": {}, "png": optional(D)}, ["text", "isError"]),
                "DomainRecord": {"type": "object", "description": "Application record or tagged application enum, preserved without reinterpretation. See source map in docs/SERVER-PROTOCOL.md.", "additionalProperties": True},
            }}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    path = ROOT / "Protocol" / f"bloom-v{VERSION}.schema.json"
    text = json.dumps(build(), indent=2, ensure_ascii=False) + "\n"
    if args.check:
        if not path.exists() or path.read_text() != text:
            raise SystemExit("Schema is stale. Run python3 Protocol/generate-schema.py")
        print(f"Protocol {VERSION} schema and all Swift method inventories agree.")
    else:
        path.write_text(text)
