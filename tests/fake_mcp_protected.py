#!/usr/bin/env python3
"""A fake OAuth-protected MCP server for calibrating end-to-end auth.

Serves MCP JSON-RPC over HTTP, but ONLY when the request carries
`Authorization: Bearer <the token the fake AS issues>`. Also serves the
protected-resource metadata so the client can discover the AS.

The fake AS is tests/fake_oauth_as.py (run on AS_PORT); this is the resource
server (RES_PORT). The token it accepts is ACCESS1 (what the fake AS issues).
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

RES_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8950
AS_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8951
BASE = f"http://127.0.0.1:{RES_PORT}"
AS = f"http://127.0.0.1:{AS_PORT}"

TOOLS = [{"name": "whoami", "description": "Who am I",
          "inputSchema": {"type": "object", "properties": {}}}]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/.well-known/oauth-protected-resource"):
            self._json({"resource": f"{BASE}/mcp", "authorization_servers": [AS]})
        else:
            self._json({"error": "not_found"}, 404)

    def do_POST(self):
        auth = self.headers.get("Authorization", "")
        if auth != "Bearer ACCESS1":
            self.send_response(401)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        n = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(n) or b"{}")
        method = req.get("method", "")
        rid = req.get("id")
        if method == "initialize":
            result = {"protocolVersion": "2024-11-05", "capabilities": {},
                      "serverInfo": {"name": "fake-protected", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": TOOLS}
        else:
            result = {}
        self._json({"jsonrpc": "2.0", "id": rid, "result": result})


HTTPServer(("127.0.0.1", RES_PORT), Handler).serve_forever()
