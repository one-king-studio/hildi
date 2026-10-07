# Component Specification: OAuth Flow & Token Store v1

**Related Feature:** [MCP_OAuth_FEATURE.md](MCP_OAuth_FEATURE.md)

**Depends on:** `MCP_OAuth_Discovery_v1.SPEC.md`, `hildegard.helper.store`,
`hildegard.helper.mcp.http`.

## Purpose

The stateful half: run the authorization-code flow (register a client, open the
browser, catch the redirect, exchange the code), persist the tokens, and feed a
valid bearer token to the HTTP transport (refreshing when needed).

## Requirements

### Functional

- [ ] `TOAuthFlow.Run(AServer; ABrowser; out ATokens)`: discovery → (DCR or
      configured `client_id`) → PKCE → authorize URL → browser → localhost
      redirect (verify `state`) → token exchange (with `resource`).
- [ ] **Browser seam**: a `TOAuthBrowser = procedure(const AUrl: string)` the
      flow calls; the real one opens the system browser, tests inject a fake.
- [ ] **Redirect listener**: a one-shot localhost HTTP server on an ephemeral
      port that captures `code`/`state` and returns a small "you can close this"
      page.
- [ ] **Token store**: persist per server — `client_id`, `client_secret`
      (optional), `access_token`, `refresh_token`, `expires_at`, `scope`. A
      store migration adds the table.
- [ ] `EnsureAccessToken(AServer; out AToken; out AError)`: return a valid
      access token, refreshing first if `now >= expires_at - skew`; a refresh
      failure ⇒ a clear "re-authorize" error.
- [ ] **Transport integration**: `THttpTransport` with `auth = oauth` asks the
      token store for a token each request and sets `Authorization: Bearer …`.
- [ ] DCR result and tokens survive across processes (store-backed).

### Non-Functional

- [ ] Secrets never logged; the token table is only in the `0600` store file.
- [ ] The flow is bounded by timeouts; a hung browser step does not hang forever.
- [ ] `make check` green; leak-clean (the listener is closed on every path).

## Contracts & Interfaces

```pascal
unit hildegard.helper.mcp.oauth.flow;

type
  TOAuthBrowser = procedure(const AUrl: string) of object;

  TOAuthTokens = record
    AccessToken: string;
    RefreshToken: string;
    ExpiresAt: Int64;      // ms epoch; 0 = unknown
    Scope: string;
    ClientId: string;
    ClientSecret: string;  // '' when public (PKCE) client
  end;

  TOAuthFlow = class
  public
    constructor Create(const AMeta: TAuthServerMeta;
      const AResource: string; ARedirectPort: Integer = 0);
    { Run the full flow; ABrowser opens the authorize URL; the redirect is
      caught on localhost. False + AError on any step. }
    function Run(const AClientId, AClientSecret, AScope: string;
      ABrowser: TOAuthBrowser; out ATokens: TOAuthTokens): Boolean;
  end;
```

Store additions (`hildegard.helper.store`, migration **v5**):

```pascal
type
  TOAuthTokenRow = record
    ServerName: string;      // the mcp_servers name (scoped key, see below)
    Scope: TMcpScope;
    WorkspaceId: Integer;
    ClientId: string;
    ClientSecret: string;
    AccessToken: string;
    RefreshToken: string;
    ExpiresAt: Int64;
    TokenScope: string;
  end;

  TSqliteStore = class
    function SaveOAuthToken(const ARow: TOAuthTokenRow;
      out AError: TStoreError): Boolean;
    function LoadOAuthToken(AScope: TMcpScope; AWorkspaceId: Integer;
      const AServerName: string; out ARow: TOAuthTokenRow;
      out AError: TStoreError): Boolean;
    function ClearOAuthToken(AScope: TMcpScope; AWorkspaceId: Integer;
      const AServerName: string; out AError: TStoreError): Boolean;
  end;
```

### Data Contracts

- **Token key.** A token belongs to `(scope, workspace_id, server_name)` — the
  same identity as the config row.
- **Expiry skew.** Refresh when `NowMs >= ExpiresAt - RefreshSkewMs`
  (default 60s).
- **Refresh request.** `grant_type=refresh_token`, `refresh_token`, `client_id`,
  (+ `client_secret` if any), `resource`.
- **Transport auth mode.** `TMcpServerConfig` gains an auth kind
  (`akNone`, `akHeader`, `akOAuth`); `akOAuth` uses the token store, `akHeader`
  the static headers (existing).

### Event Contracts

- The flow emits progress via a `TMcpEvent`-style sink (opening browser,
  awaiting redirect, token acquired) so a UI can narrate it.

## Architecture

### Prior Art & Reuse

- **`MCP_OAuth_Discovery_v1`** supplies discovery + PKCE + the authorize URL.
- **The store** already has the migration + typed-method pattern (approvals,
  mcp_servers); the token table follows it.
- **`THttpTransport`** already sends headers; `akOAuth` inserts a fresh token.
- **Genuine gap:** DCR, the redirect listener, the exchange, the token store,
  and refresh.

### Component Boundaries

- **Responsibilities:** DCR, browser+redirect, exchange, persistence, refresh,
  transport integration.
- **Side effects:** network (AS), a localhost listener, store writes.

## Validation Rules

- `state` must match; a mismatch aborts the flow.
- A token response without `access_token` is an error.

## Error Handling

- Each step names its failure (`discovery_failed`, `registration_failed`,
  `redirect_timeout`, `exchange_failed`, `refresh_failed`).
- `refresh_failed` ⇒ callers surface "re-authorize this server".

## Testing Requirements

### Unit/Integration Tests (`tests/test_mcp_oauth_flow.pas`)

- [ ] Against a **fake authorization server** (in-process): DCR, authorize
      (the fake "browser" hits the authorize URL, which redirects to the
      listener), token exchange, and the store round-trip.
- [ ] Refresh: an expired token triggers a refresh; a `refresh_failed` surfaces.
- [ ] `state` mismatch aborts.
- [ ] The transport sends `Authorization: Bearer <token>` with `akOAuth`.
- [ ] Leak-clean (the listener closes on success and failure).

### Integration Tests

- [ ] Manual (calibration): a real OAuth MCP server end to end.

## Performance Targets

- The flow is interactive (browser); refresh is one POST.

## Security Considerations

- PKCE S256 only; `state` verified; tokens stored in the `0600` store.
- No secret in logs or events.

## Success Criteria

- [ ] A server requiring OAuth authenticates and lists tools; `make check`
      green.

## Future Considerations

- Device-code flow; revocation on `mcp remove`; the link consuming the pipeline.
