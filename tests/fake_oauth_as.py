#!/usr/bin/env python3
"""A minimal OAuth 2.1 authorization server for calibrating the MCP OAuth flow.

Serves: protected-resource metadata, authorization-server metadata, dynamic
client registration, and the token endpoint (authorization_code + refresh_token).
The /authorize endpoint just 302-redirects to the redirect_uri with a code.
Not a real AS — just enough to prove the flow end to end.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs, urlencode

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8940
BASE = f"http://127.0.0.1:{PORT}"


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
        p = urlparse(self.path)
        if p.path == "/.well-known/oauth-protected-resource":
            self._json({"resource": f"{BASE}/mcp",
                        "authorization_servers": [BASE]})
        elif p.path == "/.well-known/oauth-authorization-server":
            self._json({
                "issuer": BASE,
                "authorization_endpoint": f"{BASE}/authorize",
                "token_endpoint": f"{BASE}/token",
                "registration_endpoint": f"{BASE}/register",
                "code_challenge_methods_supported": ["S256"],
            })
        elif p.path == "/authorize":
            q = parse_qs(p.query)
            redirect = q.get("redirect_uri", [""])[0]
            state = q.get("state", [""])[0]
            loc = redirect + "?" + urlencode({"code": "AUTHCODE", "state": state})
            self.send_response(302)
            self.send_header("Location", loc)
            self.end_headers()
        else:
            self._json({"error": "not_found"}, 404)

    def do_POST(self):
        p = urlparse(self.path)
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n).decode()
        form = parse_qs(raw)
        if p.path == "/register":
            self._json({"client_id": "dyn-client", "client_secret": ""})
        elif p.path == "/token":
            grant = form.get("grant_type", [""])[0]
            if grant == "authorization_code":
                self._json({"access_token": "ACCESS1", "refresh_token": "REFRESH1",
                            "expires_in": 3600, "scope": "read"})
            elif grant == "refresh_token":
                self._json({"access_token": "ACCESS2", "refresh_token": "REFRESH1",
                            "expires_in": 3600, "scope": "read"})
            else:
                self._json({"error": "unsupported_grant_type"}, 400)
        else:
            self._json({"error": "not_found"}, 404)


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
