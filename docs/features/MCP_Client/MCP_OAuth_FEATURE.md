# MCP OAuth 2.0

## Overview

Authenticate the helper to remote MCP servers that require **OAuth 2.1** — the
model the MCP specification mandates for its HTTP transport. Today the HTTP
transport sends *static* headers (an operator-pasted bearer token). That works
for a pre-issued key but not for a server that demands a real OAuth flow: client
registration, a browser consent step, PKCE, and token refresh.

This feature implements the MCP OAuth profile: **Protected Resource Metadata
discovery (RFC 9728)**, **Authorization Server metadata (RFC 8414)**, **Dynamic
Client Registration (RFC 7591)**, the **PKCE authorization-code flow
(RFC 7636)** with an **RFC 8707 `resource` parameter**, and a **token store**
with refresh. It is the "shared outbound auth pipeline" the MCP FEATURE calls
for.

## Problem Statement

Remote MCP servers increasingly require OAuth. The MCP spec says a client MUST
use OAuth 2.1 and MUST discover the authorization server from the resource. A
static bearer header (what we have) cannot:
- register a client dynamically (no pre-shared `client_id`),
- obtain a token via user consent,
- refresh an expired token.

So without this, the helper cannot use a whole class of remote MCP servers —
only those that accept a fixed token.

**Cross-feature note (the reconciliation the FEATURE demands):** Remote Agent
Link specifies device pairing + a bearer token, with OAuth explicitly out of
scope. "One auth pipeline, three consumers" is a goal, not a fact. This feature
**owns** the OAuth pipeline (MCP carries it); the link may later consume it.
The link doc is not changed here; that reconciliation is recorded, not assumed.

## Goals

- Discover the authorization server from the MCP resource (PRM), with a
  `.well-known` fallback.
- Register a client dynamically (DCR), or use an operator-supplied `client_id`.
- Run the PKCE authorization-code flow: build the authorize URL, receive the
  code on a localhost redirect, exchange it (with the `resource` parameter) for
  tokens.
- Persist tokens (access + refresh + expiry + the client registration) in the
  store, per server.
- Refresh an expired access token automatically; the HTTP transport uses a
  fresh bearer token.
- Be testable: discovery, PKCE primitives, and token refresh are pure or
  fake-server tested; the browser step is injectable.

## User Stories

- As an **operator**, I want to authorize the helper to a remote MCP server by
  clicking a link and consenting, so I can use a server that has no static key.
- As an **operator**, I want the token refreshed automatically, so a long-lived
  session does not fail when the access token expires.
- As a **developer**, I want discovery and PKCE primitives unit-tested, so the
  flow is correct without a live authorization server.
- As a **reviewer**, I want the pipeline to live in one place (this feature), so
  the link can later reuse it rather than duplicate it.

## Acceptance Criteria

### Functional Requirements

- [ ] **Discovery**: given an MCP URL, fetch Protected Resource Metadata
      (`/.well-known/oauth-protected-resource`, plus the RFC 9728 path-aware
      form) to find the authorization server; fall back to the resource origin's
      `/.well-known/oauth-authorization-server`. Parse into typed records.
- [ ] **AS metadata**: fetch the authorization server metadata (authorize,
      token, registration endpoints; supported PKCE methods).
- [ ] **DCR**: register a client (RFC 7591) when no `client_id` is configured;
      persist the returned `client_id` (and secret, if any) per server.
- [ ] **PKCE**: generate a `code_verifier` and `code_challenge` (S256); include
      `code_challenge_method=S256`.
- [ ] **Authorize**: build the authorization URL (client_id, redirect_uri,
      scope, state, code_challenge, `resource`); receive the code at a
      **localhost redirect**; verify `state`; exchange the code (with
      `code_verifier` and `resource`) for tokens.
- [ ] **Token store**: persist access/refresh/expiry/scopes per server (store
      migration); load, and refresh when expired.
- [ ] **Transport integration**: the HTTP transport requests a valid access
      token from the token store (refreshing if needed) and sends it as
      `Authorization: Bearer …`.
- [ ] **Failure modes**: discovery/registration/exchange failures are clean and
      named; an expired token with no refresh path is a clear "re-authorize"
      error.

### Non-Functional Requirements

- [ ] Reuse `hildegard.helper.tls` / `fphttpclient` and `fpjson`; no new
      dependency.
- [ ] The browser/redirect step is injectable (a callback) so tests need no
      browser.
- [ ] `make check` green; secrets never logged.

## Constraints

### Technical

- FPC 3.3.1, `{$mode delphi}`; POSIX (macOS/Linux).
- A localhost redirect listener for the callback (a small in-process HTTP server).

### Business / Time

- This is the largest single feature here; it lands in phases (below).

## Dependencies

### Internal

- `hildegard.helper.mcp.http` (the transport that will use the token),
  `hildegard.helper.store` (token persistence), `hildegard.helper.tls`.

### External

- The authorization server (a live one for calibration only).

## Risks

- **Flow complexity** (redirect listener, browser, state) — Mitigation: inject
  the browser + redirect; test the primitives directly.
- **Server variation** (not all servers do DCR or PRM) — Mitigation: fallbacks
  and operator-supplied `client_id`.
- **Secret handling** — Mitigation: tokens in the store (0600), never logged.

## Out of Scope

- **The Remote Agent Link consuming this pipeline** — recorded as the intended
  reconciliation, not done here.
- **Non-OAuth auth** (mTLS, SAML).
- **Device-code flow** (a headless-friendly alternative) — a future variant.

## Future Considerations

- Device-code flow for headless devices.
- Token revocation on `mcp remove`.
- The link reusing this pipeline (the reconciliation).

## Notes

- **ICE score: Impact 8, Confidence 5, Ease 3.** High impact and explicitly
  required by the MCP spec, but the flow (discovery → DCR → PKCE → callback →
  refresh) is the most intricate thing in the project. It is phased so each part
  is testable.
