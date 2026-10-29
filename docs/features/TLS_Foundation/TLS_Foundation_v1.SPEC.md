# Component Specification: TLS Foundation v1

**Related Feature:** [FEATURE.md](FEATURE.md)

**Extends:** the transport seam in `hildi.llm`
(`TLLMTransport` / `TFPHTTPTransport`).

## Purpose

Replace the runtime-`dlopen`'d OpenSSL that `opensslsockets` pulls in with a
**vendored, statically linked mbedTLS**, behind FPC's existing socket-handler
seam. When this ships, the release binary completes HTTPS on a host with no
OpenSSL, and every future network feature inherits a deployable transport.

Nothing above the seam changes: the HTTP client, SSE streaming, timeouts,
cancellation, the typed error set, and the transport fakes are untouched. The
swap is one `uses` line plus a new backend that `TFPHTTPClient` picks up
automatically.

## Requirements

### Functional

**Native backend (vendored mbedTLS + shim + CA)**

- [ ] `scripts/fetch-mbedtls.sh` pins mbedTLS **3.6.x LTS** (exact version),
      downloads the release tarball, verifies its SHA-256, and extracts it into
      `deps/mbedtls/` (source fetched, never committed — the
      `fetch-sqlite.sh` pattern).
- [ ] The Makefile compiles the vendored source into static archives under
      `build/libstatic/` (`libmbedtls.a`, `libmbedx509.a`, `libmbedcrypto.a`)
      and links them with `-k<abs path>`, so a system mbedTLS is never used.
- [ ] A small C shim (`src/hildi_tls_shim.c`) wraps the mbedTLS **client**
      API behind one opaque handle, so no mbedTLS struct layout is mirrored in
      Pascal. It is the only C the project writes for TLS.
- [ ] `scripts/fetch-cacert.sh` pins a Mozilla CA bundle (version + SHA-256)
      into `deps/cacert/cacert.pem`; the Makefile generates a C source
      (`build/gen/cacert_embedded.c`) embedding it; the shim parses it as the
      default trust chain.
- [ ] Every mbedTLS context is allocated and freed in one place in the shim; no
      context survives an error path. A live-context counter lets a test assert
      it returns to zero.

**Transport (`hildi.tls`)**

- [ ] `TMbedTLSSocketHandler` extends FPC's `TSSLSocketHandler` (from
      `sslsockets`), implements the socket methods, and binds the shim through
      `external` declarations.
- [ ] The unit registers itself in its `initialization` with
      `TSSLSocketHandler.SetDefaultHandlerClass`, so `TFPHTTPClient` obtains it
      from `TSSLSocketHandler.GetDefaultHandler` with no `OnGetSocketHandler`
      hook and no HTTP-client fork.
- [ ] `Connect` runs the TLS handshake on the already-connected socket handle,
      sends SNI, and verifies the peer chain and hostname. It reuses FPC's
      `CertificateData` (`CertCA.FileName`, `TrustedCertsDir`) rather than
      inventing a parallel config shape.
- [ ] CA source, in order: a readable `HILDI_CA_BUNDLE` PEM path when set,
      otherwise the embedded bundle. A set-but-unreadable override is a
      distinct, actionable `leConfig` error.
- [ ] `GetLastSSLErrorString`/`GetLastSSLErrorCode` return the mbedTLS error, so
      FPC's `ESocketError`/`GetLastErrorDescription` path carries TLS detail into
      the transport's error string.
- [ ] `hildi.llm` replaces `opensslsockets` with
      `hildi.tls` in its `uses`. Nothing else in that unit changes.
- [ ] No shipping target links `opensslsockets`, so `libssl`/`libcrypto` are
      never `dlopen`ed.

### Non-Functional

- [ ] Portability: builds clean on macOS aarch64 and Linux x86-64/aarch64; no
      `TSemaphore`-class platform traps.
- [ ] `make check` passes (functional suite + heaptrc leak gate) with the C
      library in the process.
- [ ] Behaviour preservation: the existing transport fakes and LLM client tests
      pass unchanged; streaming, timeouts, and cancellation are unregressed.
- [ ] Performance: first-token latency and streaming throughput are unregressed
      against the existing budgets.
- [ ] Deployment: the release binary completes a streamed HTTPS turn on a host
      with no OpenSSL present.
- [ ] Binary size: the static TLS stack's delta is bounded and recorded in the
      DONE notes.
- [ ] Upgrade: a version bump is one pin line plus a rebuild, with the fetch
      script verifying the checksum.

## Contracts & Interfaces

> Contracts are declarations, not bodies. The Pascal surface is what the harness
> depends on; the C prototypes are the shim's boundary (it is a C API, so it is
> declared in C).

### Public API (Pascal)

```pascal
unit hildi.tls;

type
  { A TSSLSocketHandler backed by the vendored mbedTLS shim. Registered as the
    process default handler in this unit's initialization. }
  TMbedTLSSocketHandler = class(TSSLSocketHandler)
  protected
    function GetLastSSLErrorString: String; override;
    function GetLastSSLErrorCode: Integer; override;
  public
    function Connect: Boolean; override;
    function Close: Boolean; override;
    function Shutdown(BiDirectional: Boolean): Boolean; override;
    function Send(const Buffer; Count: Integer): Integer; override;
    function Recv(const Buffer; Count: Integer): Integer; override;
    function BytesAvailable: Integer; override;
  end;

{ The CA bundle override from HILDI_CA_BUNDLE, or '' when unset. }
function TLSBundleOverride: string;

{ True when the resolved CA source is usable. AError is a distinct, actionable
  message when an override is set but unreadable; '' on success. }
function ValidateTLSConfig(out AError: string): Boolean;
```

### Native Contract (C shim)

```c
typedef struct hildi_tls hildi_tls;   /* opaque */

hildi_tls *hildi_tls_new(void);       /* NULL on allocation failure   */
void           hildi_tls_free(hildi_tls *h);

/* Trust chain: a PEM buffer, or a file path. 0 ok, <0 error. */
int hildi_tls_set_ca_mem(hildi_tls *h, const void *pem, unsigned len);
int hildi_tls_set_ca_file(hildi_tls *h, const char *path);

/* Handshake on an already-connected fd. host drives SNI and verification. */
int hildi_tls_connect(hildi_tls *h, int fd, const char *host);

/* >0 bytes, 0 orderly EOF, <0 error. */
int hildi_tls_read(hildi_tls *h, void *buf, int len);
/* >=0 bytes, <0 error. */
int hildi_tls_write(hildi_tls *h, const void *buf, int len);
int hildi_tls_pending(hildi_tls *h);
int hildi_tls_close(hildi_tls *h);

/* mbedTLS error code; copies a human, non-secret string into buf. */
int hildi_tls_last_error(hildi_tls *h, char *buf, unsigned buflen);

/* Live shim contexts; the test asserts it returns to zero. */
int hildi_tls_live_count(void);

/* The embedded CA bundle, generated from deps/cacert/cacert.pem. */
const unsigned char *hildi_ca_pem(void);
unsigned             hildi_ca_pem_len(void);
```

### Data Contracts

- **Return convention.** `connect`/`set_ca_*` return `0` on success and a
  negative mbedTLS code on failure; `read` returns `>0`, `0` (orderly EOF), or a
  negative code; `write` returns `>=0` or a negative code. The shim records the
  last error for `hildi_tls_last_error`.
- **Handle lifetime.** One `hildi_tls` per TLS connection. The handler owns
  it: created lazily on first `Connect`, freed in `Close`/`Destroy`.
- **CA bundle.** The embedded bytes are the default; `set_ca_file` overrides.
  Both feed an mbedTLS X.509 chain used for `MBEDTLS_SSL_VERIFY_REQUIRED`.

### Event Contracts

- None. The handler is synchronous, like the rest of the transport.

## Architecture

### Prior Art & Reuse

- **Reuse the entire seam above TLS.** `TFPHTTPClient` already asks
  `TSSLSocketHandler.GetDefaultHandler` for a handler
  (`packages/fcl-web/src/base/fphttpclient.pp`), and `TInetSocket.Connect` calls
  `Handler.Connect` after the TCP connect, reporting `GetLastErrorDescription`
  on failure (`packages/fcl-net/src/ssockets.pp`). `opensslsockets` is just one
  implementation of that base class; ours is another. No HTTP-client fork.
- **Reuse `TCertificateData`** (`sslbase.pp`) for the CA path and the optional
  client certificate slots, so a future mTLS feature needs no new config shape.
- **Reuse the SQLite vendoring pattern**: pinned source under `deps/`,
  checksum-verified fetch script, static archive under `build/libstatic/`, and
  `-k<abs path>` linking with no system fallback.
- **Reuse the existing tests and fakes.** The transport is injected, so the LLM
  client tests never touch TLS; they stay byte-for-byte.
- **Gap (Ponytail):** the vendored source, the C shim, the handler, the CA
  embedding, and the build wiring. There is no Pascal mbedTLS binding to reuse,
  and mirroring mbedTLS struct layouts in Pascal is version-fragile — hence the
  shim.

### Component Boundaries

- **Responsibilities:** the shim owns mbedTLS contexts and I/O on an fd; the
  handler owns the FPC socket-handler lifecycle and CA policy; the Makefile owns
  vendoring and linking.
- **Dependencies:** the handler depends on `sslsockets`/`sslbase` and the shim;
  the shim depends on mbedTLS and the generated CA source; `llm` depends on the
  handler only through the registered default class.
- **Side effects:** none beyond the socket and the store-free TLS state. No
  global mutable state beyond the class registration.

### Data Flow

1. `TLLMClient.Complete` calls `TFPHTTPTransport.PostStream` (unchanged).
2. `TFPHTTPClient.Post` resolves `https`, calls `GetSocketHandler(True)`, which
   returns a new `TMbedTLSSocketHandler` from `GetDefaultHandler`.
3. `TInetSocket.Connect` performs the TCP connect, then calls
   `Handler.Connect`; the handler creates the shim, loads the CA (override or
   embedded), and handshakes with SNI + verification.
4. Body reads/writes flow `TSocketStream` → `Handler.Recv`/`Send` → shim →
   mbedTLS → fd. The SSE body still lands in the existing `TChunkProxyStream`;
   parsing is unchanged.
5. On failure, the mbedTLS error reaches `GetLastErrorDescription`, the
   `ESocketError` message, `PostStream`'s `AError`, and finally
   `TLLMError.Detail` under `leNetwork` (or `leConfig` for a CA problem).

### Integration Patterns

- Synchronous and single-threaded, like the current transport.
- **Ownership:** the handler owns the shim handle and frees it exactly once; FPC
  owns the socket. The handler is created and destroyed by `TFPHTTPClient` per
  request (as `TOpenSSLSocketHandler` is today).
- **Timeouts:** the TCP connect honours `ConnectTimeout` (FPC); the handshake
  honours it through a receive timeout; `Recv` honours the socket's `IOTimeout`
  — a stalled read with a timeout yields `0`/EOF rather than blocking forever,
  matching the OpenSSL handler's behaviour.
- **Cancellation:** unchanged — `CancelCheck` is consulted between stream writes
  by `TChunkProxyStream`.

## Validation Rules

### Input

- The host is `TInetSocket.Host`; it drives SNI and hostname verification. An
  empty host is a verification failure, not a silent skip.
- `HILDI_CA_BUNDLE`, when set, must name a readable PEM file.
- The embedded bundle is always present (generated at build time).

### Output Guarantees

- Verification is **on by default**; the handler never selects `VERIFY_NONE`.
- Errors carry the mbedTLS code and a human string, never key material, tokens,
  or session data.
- The LLM client's existing contract is unchanged: same streaming callbacks,
  same `TLLMErrorCode` mapping, same cancellation semantics.

## Error Handling

### Error Types

- **Config errors:** a set-but-unreadable CA override → `leConfig` with a
  distinct message (before any network I/O).
- **Handshake/verify errors:** certificate or hostname verification failure, an
  unsupported protocol, a truncated handshake → `leNetwork` with the mbedTLS
  detail.
- **I/O errors / timeout:** a stalled or reset connection → `leNetwork`; the
  existing `IOTimeout`/`ConnectTimeout` semantics are preserved.
- **Cancellation:** unchanged → `leCancelled`.

### Error Contracts

The handler does not introduce a new error type: it reports through FPC's
`GetLastErrorDescription` and the existing `TLLMError` (`leConfig`,
`leNetwork`, `leCancelled`). Process-level codes are unchanged (`0` success,
`124` timeout, `128+signal` killed, `130` cancelled).

## Testing Requirements

### Unit Tests (`tests/test_tls.pas`)

- [ ] `TestHandlerIsRegisteredDefault` — `TSSLSocketHandler.GetDefaultHandler`
      returns a `TMbedTLSSocketHandler`.
- [ ] `TestEmbeddedBundleIsPresent` — `hildi_ca_pem_len > 0` and the bytes
      parse as PEM.
- [ ] `TestBundleOverrideResolves` — `TLSBundleOverride` reads the environment;
      `ValidateTLSConfig` accepts an unset override and a readable file.
- [ ] `TestUnreadableOverrideIsConfigError` — a set-but-missing path yields a
      distinct error, and `TLLMClient` maps it to `leConfig`.
- [ ] `TestShimHandleRoundTrip` — `new`/`free` balances
      (`hildi_tls_live_count = 0`), including after a failed `connect`.
- [ ] `TestBadCaFileFails` — a garbage CA file fails `set_ca_file` with a
      reported error and no leak.

### Integration Tests (`tests/test_tls.pas`)

- [ ] `TestLoopbackHandshake` — a test-only mbedTLS server
      (`tests/tls_test_server.c`) with a self-signed `localhost` fixture; the
      production handler connects, completes a real handshake, and round-trips
      bytes both ways.
- [ ] `TestLoopbackRejectsUnknownCa` — the client, trusting a different CA,
      fails verification with a reported TLS error.
- [ ] `TestLoopbackRejectsWrongHost` — a certificate for another name fails
      hostname verification.
- [ ] `TestHandlerDrivesTFPHTTPClient` — a `TFPHTTPClient` GET through the
      registered handler over loopback returns the expected body, proving the
      seam (not just the shim).

### Regression

- [ ] The existing LLM transport/client tests are unchanged and pass.
- [ ] `make check` passes (functional + leak gate).

### Field verification (manual / documented)

- [ ] The release binary completes a streamed HTTPS turn with OpenSSL absent
      (a clean container, or `DYLD_*`/`LD_LIBRARY_PATH` isolation).
- [ ] `strings`/`nm` on the release binary show no `libssl`, `libcrypto`, or
      `opensslsockets` reference. (**Not** `otool -L`, which is already clean
      because FPC `dlopen`s OpenSSL — see FEATURE Notes.)

## Performance Targets

- No regression in first-token latency or streaming throughput against the
  existing `make perf` budgets.
- Handshake is a one-time cost per request (as today); `Recv`/`Send` add only a
  shim call and the mbedTLS record layer.
- Release binary size delta recorded; the vendored default mbedTLS config is
  accepted for v1 (trimming is a future consideration).

## Security Considerations

- **Verify by default.** The handler uses `MBEDTLS_SSL_VERIFY_REQUIRED` and
  never falls back to `VERIFY_NONE`; a bad chain or hostname fails the turn.
- **No secrets in diagnostics.** Errors and logs carry mbedTLS codes and
  messages only — never key material, the API key, or session data.
- **The CA bundle is public data.** The embedded bundle and any override are
  public roots; no private material is embedded.
- **Test fixtures are test-only.** The loopback certificate and key under
  `tests/fixtures/tls/` are throwaway and clearly labelled; they are never
  linked into a shipping binary.
- **Bounded surface.** The shim exposes an opaque handle and no mbedTLS structs,
  so a version bump cannot silently corrupt Pascal-side memory.

## Success Criteria

### Functional

- [ ] All contracts implemented; all validation and error scenarios handled.
- [ ] A streamed HTTPS LLM turn succeeds over the vendored stack with behaviour
      identical to today.
- [ ] The release binary works with no OpenSSL on the host.
- [ ] `make check` passes.

### Quality

- [ ] No leaks (shim contexts balanced; leak gate green).
- [ ] Performance targets met.
- [ ] The swap is one `uses` line; the transport fakes are untouched.
- [ ] Binary-size delta and the verification method are recorded in the DONE
      notes.

## Future Considerations

- **Client certificates / mTLS** for Remote Agent Link (the `CertificateData`
  slots and the shim already leave room).
- **TLS session resumption** for long-lived links.
- **Certificate pinning** (belongs to the Remote Agent Link threat model).
- **Trimming the mbedTLS config** to shrink the binary.
- **A second backend** (for example FPC's `gnutls` package) behind the same
  seam, should mbedTLS prove unsuitable.
- **Automating the version bump** (pin + checksum + rebuild) in the fetch
  script.
