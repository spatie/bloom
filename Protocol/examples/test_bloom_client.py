import json
import sys
import unittest
import urllib.request
from bloom_client import BloomError, Client, HTTPS, INCOMPATIBLE, NoRedirects, SSH


class ScriptedTransport:
    def __init__(self, replies):
        self.replies = iter(replies)
        self.commands = []

    def exchange(self, body):
        command = json.loads(body)
        self.commands.append(command)
        version, result, wrong_id = next(self.replies)
        return json.dumps({"version": version, "id": "00000000-0000-4000-8000-000000000000" if wrong_id else command["id"], "result": result}).encode()


class ClientTests(unittest.TestCase):
    def test_negotiates_only_known_older_hello(self):
        transport = ScriptedTransport([(12, INCOMPATIBLE, False), (12, {"hello": {"name": "server"}}, False), (12, {"catalogue": {"_0": {}}}, False)])
        client = Client(transport)
        client.connect()
        command = client.command("catalogue", {})
        client.perform(command)
        self.assertEqual([13, 12, 12], [c["version"] for c in transport.commands])
        self.assertEqual(transport.commands[0]["id"], transport.commands[1]["id"])
        self.assertEqual(command, transport.commands[2])

    def test_rejects_mismatched_hello_id_before_downgrade(self):
        transport = ScriptedTransport([(12, INCOMPATIBLE, True)])
        with self.assertRaises(BloomError):
            Client(transport).connect()
        self.assertEqual(1, len(transport.commands))

    def test_refuses_unknown_version(self):
        with self.assertRaises(BloomError):
            Client(ScriptedTransport([(14, {"hello": {"name": "server"}}, False)])).connect()

    def test_no_automatic_command_retry(self):
        transport = ScriptedTransport([(13, {"hello": {"name": "server"}}, False), (13, {"failure": {"_0": "File changed"}}, False)])
        client = Client(transport)
        client.connect()
        with self.assertRaisesRegex(BloomError, "File changed"):
            client.perform(client.command("file", {"workspaceID": "w", "path": "README.md"}))
        self.assertEqual(2, len(transport.commands))

    def test_example_refuses_mutations(self):
        client = Client(ScriptedTransport([]))
        with self.assertRaises(BloomError):
            client.command("send", {"text": "not sent"})

    def test_https_requires_clean_origin_and_token(self):
        for origin in ["http://example.com", "https://u:p@example.com", "https://example.com/path", "https://example.com/?token=x"]:
            with self.assertRaises(BloomError):
                HTTPS(origin, "secret")
        with self.assertRaises(BloomError):
            HTTPS("https://example.com", "secret\r\nHeader: x")

    def test_redirect_does_not_forward_credentials(self):
        request = urllib.request.Request("https://example.com", headers={"Authorization": "Bearer secret"})
        with self.assertRaises(BloomError):
            NoRedirects().redirect_request(request, None, 302, "", {}, "https://other.example.com")

    def test_ssh_keeps_stdin_open_until_response(self):
        link = SSH("example.com", "bloom", 22, "/server", "/data")
        link.arguments = [sys.executable, "-c", "import sys,select; line=sys.stdin.buffer.readline(); ready=select.select([sys.stdin],[],[],0.03)[0]; sys.exit(1) if ready else None; sys.stdout.buffer.write(line); sys.stdout.buffer.flush(); sys.stdin.read()"]
        self.assertEqual(b'{"hello":{}}\n', link.exchange(b'{"hello":{}}'))

    def test_ssh_quotes_remote_paths_and_requires_host_trust(self):
        link = SSH("example.com", "bloom", 22, "/opt/bloom's server", "/var/lib/bloom data")
        self.assertIn("StrictHostKeyChecking=yes", link.arguments)
        self.assertIn("'\"'\"'", link.arguments[-1])
        with self.assertRaises(BloomError):
            SSH("-oProxyCommand=bad", "bloom", 22, "/server", "/data")


if __name__ == "__main__":
    unittest.main()
