"""Tiny MCP stdio client used by the tests and the demo. Standard library only."""
import json
import os
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.environ.get("REMINDERS_MCP_BINARY", os.path.join(ROOT, ".build", "release", "eventkit-reminders-mcp"))


class Client:
    def __init__(self, env=None, args=()):
        e = {k: v for k, v in os.environ.items() if not k.startswith("REMINDERS_MCP_")}
        e.update(env or {})
        self.p = subprocess.Popen([BINARY, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, env=e)
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": "tests", "version": "0"}})
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")

    def rpc(self, method, params=None):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}) + "\n")
        self.p.stdin.flush()
        msg = json.loads(self.p.stdout.readline())
        assert msg["id"] == self.n, msg
        return msg

    def tool_names(self):
        return [t["name"] for t in self.rpc("tools/list")["result"]["tools"]]

    def call(self, name, **arguments):
        """Returns (data, is_error). data is the parsed JSON, or the error text."""
        res = self.rpc("tools/call", {"name": name, "arguments": arguments})
        if "error" in res:
            return res["error"]["message"], True
        text = res["result"]["content"][0]["text"]
        if res["result"].get("isError"):
            return text, True
        notice, _, body = text.partition("\n")
        assert notice.startswith("⚠️"), notice
        return json.loads(body), False

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=10)
        err = self.p.stderr.read()
        self.p.stdout.close()
        self.p.stderr.close()
        return err
