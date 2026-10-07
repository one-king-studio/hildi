# Component Specification: OAuth Discovery & PKCE v1

**Related Feature:** [MCP_OAuth_FEATURE.md](MCP_OAuth_FEATURE.md)

**Depends on:** `hildegard.helper.tls` / `fphttpclient`, `fpjson`.
**Depended on by:** `Mcp_OAuth_Flow_v1.SPEC.md`.

## Purpose

The pure, testable core of OAuth: **discovery** (find the authorization server
and its endpoints) and the **PKCE** primitives. No browser, no token store, no
transport — just parsing and crypto-free string transforms, so it is fully unit-
testable.

## Requirements

### Functional

- [ ] `DiscoverProtectedResource(const AResourceURL; out AMeta; out AError)`:
      fetch `/.well-known/oauth-protected-resource` (path-aware per RFC 9728)
      and parse `authorization_servers` (at least one) and `resource`.
- [ ] `DiscoverAuthServer(const AIssuerURL; out AMeta; out AError)`: fetch
      `/.well-known/oauth-authorization-server` (and the OpenID form as a
      fallback) and parse `authorization_endpoint`, `token_endpoint`,
      `registration_endpoint` (optional), `code_challenge_methods_supported`.
- [ ] `ResolveAuthServer(const AMcpURL; ...)`: PRM → authorization server; if PRM
      is absent, fall back to the resource origin's AS metadata.
- [ ] `GenerateCodeVerifier`: 43–128 chars, unreserved set, from a CSPRNG.
- [ ] `CodeChallengeS256(const AVerifier)`: `BASE64URL(SHA256(verifier))`, no
      padding.
- [ ] `BuildAuthorizeURL(const AParams)`: compose the authorize URL with
      `response_type=code`, `client_id`, `redirect_uri`, `scope`, `state`,
      `code_challenge`, `code_challenge_method=S256`, and `resource`.
- [ ] `GenerateState`: a CSPRNG random state.

### Non-Functional

- [ ] Pure functions where possible; the discovery fetch is a thin HTTP call
      separated from the parsing (`ParseProtectedResource`,
      `ParseAuthServerMetadata`).
- [ ] SHA-256 via a dependency already present (mbedTLS through the TLS shim) or
      a small, well-tested local implementation; no new library.
- [ ] `make check` green.

## Contracts & Interfaces

```pascal
unit hildegard.helper.mcp.oauth;
{ OAuth 2.1 discovery and PKCE for MCP. Discovery parsing and PKCE are pure;
  the discovery fetch is a thin HTTP wrapper. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TProtectedResourceMeta = record
    Resource: string;
    AuthorizationServers: array of string;
    ScopesSupported: array of string;
  end;

  TAuthServerMeta = record
    Issuer: string;
    AuthorizationEndpoint: string;
    TokenEndpoint: string;
    RegistrationEndpoint: string;      // '' when the server has no DCR
    CodeChallengeMethods: array of string;   // e.g. ['S256']
  end;

{ --- pure parsing (unit-tested) --- }
function ParseProtectedResource(const AJson: string;
  out AMeta: TProtectedResourceMeta; out AError: string): Boolean;
function ParseAuthServerMetadata(const AJson: string;
  out AMeta: TAuthServerMeta; out AError: string): Boolean;

{ --- pure PKCE --- }
function GenerateCodeVerifier: string;            // 43-128 unreserved chars
function GenerateState: string;                   // CSPRNG random
function CodeChallengeS256(const AVerifier: string): string;  // base64url

{ --- authorize URL --- }
type
  TAuthorizeParams = record
    AuthorizationEndpoint: string;
    ClientId: string;
    RedirectUri: string;
    Scope: string;
    State: string;
    CodeChallenge: string;
    Resource: string;
  end;
function BuildAuthorizeURL(const AParams: TAuthorizeParams): string;

{ --- discovery fetch (thin HTTP wrapper) --- }
function DiscoverProtectedResource(const AResourceURL: string;
  out AMeta: TProtectedResourceMeta; out AError: string): Boolean;
function DiscoverAuthServer(const AIssuerURL: string;
  out AMeta: TAuthServerMeta; out AError: string): Boolean;
```

### Data Contracts

- **Well-known URLs.** PRM: `<origin>/.well-known/oauth-protected-resource` and
  the path-aware `<origin>/.well-known/oauth-protected-resource<path>`. AS:
  `<issuer>/.well-known/oauth-authorization-server`.
- **PKCE.** `code_verifier`: 43–128 chars from
  `A-Z a-z 0-9 - . _ ~`. `code_challenge`: `BASE64URL(SHA256(ASCII(verifier)))`
  without padding.
- **`resource` (RFC 8707).** The MCP server's canonical URL, sent on both the
  authorize and token requests.

### Event Contracts

- None.

## Architecture

### Prior Art & Reuse

- **`fphttpclient` + `hildegard.helper.tls`** for the discovery GETs.
- **`fpjson`** for parsing.
- **mbedTLS** (already vendored) supplies SHA-256; the TLS shim may expose a
  `sha256` helper, or a small local implementation is used (SPEC pins: prefer
  the vendored crypto, no new dependency).
- **Genuine gap:** all of OAuth discovery and PKCE.

### Component Boundaries

- **Responsibilities:** discovery parsing/fetching, PKCE, authorize URL.
- **Dependencies:** HTTP + TLS + JSON.
- **Side effects:** the discovery fetch (network).

## Validation Rules

- PRM must list at least one `authorization_servers` entry.
- AS metadata must have `authorization_endpoint` and `token_endpoint`.
- The code challenge is S256 (reject `plain`).

## Error Handling

- A fetch failure or missing field ⇒ False + a named error.

## Testing Requirements

### Unit Tests (`tests/test_mcp_oauth.pas`)

- [ ] `ParseProtectedResource`/`ParseAuthServerMetadata` on representative JSON
      (and missing-field failures).
- [ ] `GenerateCodeVerifier` length/charset; two calls differ.
- [ ] `CodeChallengeS256` against a known RFC 7636 vector.
- [ ] `BuildAuthorizeURL` includes every required parameter, URL-encoded.

### Integration Tests

- [ ] Discovery against a fake AS (in-process) yields the metadata.

## Performance Targets

- Discovery is a couple of GETs; PKCE is instant.

## Security Considerations

- `code_verifier`/`state` from a CSPRNG; S256 only (never `plain`).
- Discovery responses are untrusted input: validate fields, no injection.

## Success Criteria

- [ ] All contracts implemented; `make check` green.

## Future Considerations

- Device-code flow; JWKS/ID-token validation.
