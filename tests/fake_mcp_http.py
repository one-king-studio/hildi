#!/usr/bin/env python3
"""A minimal MCP-over-HTTP server for calibrating the HTTP transport.

Speaks the JSON-RPC subset the client needs: initialize, tools/list, tools/call.
One POST per request; the response body is the JSON-RPC response object.
Not a real MCP server — just enough to prove the transport end to end.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8931

TOOLS = [
    {"name": "ping", "description": "Ping", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "echo", "description": "Echo a message",
     "inputSchema": {"type": "object", "properties": {"message": {"type": "string"}}}},
]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(n) or b"{}")
        method = req.get("method", "")
        rid = req.get("id")
        if method == "initialize":
            result = {"protocolVersion": "2024-11-05", "capabilities": {},
                      "serverInfo": {"name": "fake-http", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call":
            result = {"content": [{"type": "text", "text": "pong"}]}
        else:
            result = {}
        body = json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
