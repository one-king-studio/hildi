# Implementation Plan: TLS Foundation v1

**Related Specification:** `TLS_Foundation_v1.SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

Vendor mbedTLS, wrap it in a small C shim, expose it through FPC's
`TSSLSocketHandler` seam, embed a CA bundle, and swap `opensslsockets` out of
the LLM transport. TDD-first; update tasks in real time. Phase 1 and the
Phase 2 smoke are the de-risking spike: prove the build and a real handshake
before wiring the handler.

## Implementation Tasks

### Phase 1: Vendor mbedTLS (build plumbing)

- [x] **Write** `scripts/fetch-mbedtls.sh` (pinned 3.6.7, SHA-256 verify, extract
      into `deps/mbedtls/`; idempotent, like `fetch-sqlite.sh`)
- [x] **Add** Makefile targets to build `libmbedtls.a`/`libmbedx509.a`/
      `libmbedcrypto.a` under `build/libstatic/`
- [x] **Verify**: a trivial C program links against the archives and calls
      `mbedtls_version_get_string` (the Phase 2 spike links them for real)
- [x] **Update** `.gitignore` for the fetched source

### Phase 2: The C shim (spike: real handshake)

- [x] **Write** `src/hildegard_tls_shim.h` / `.c`: opaque handle, `new`/`free`,
      `set_ca_mem`/`set_ca_file`, `connect`, `read`, `write`, `pending`,
      `close`, `last_error`, `live_count`; all contexts allocated and freed in
      one place
- [ ] **Write** `tests/tls_test_server.c` / `.h` (test-only mbedTLS server) and
      a self-signed `localhost` fixture under `tests/fixtures/tls/`
- [x] **Spike**: a throwaway C program completes a client↔server handshake and
      round-trips bytes over loopback (proves the build + mbedTLS before Pascal
      is involved)

### Phase 3: The Pascal handler and the seam

- [x] **Test** (`tests/test_tls.pas`): `TestHandlerIsRegisteredDefault`,
      `TestLoopbackHandshake` (asserts the shim live count returns to zero,
      including after a failed connect), `TestBadCaFileFails`
- [x] **Implement** `src/hildegard.helper.tls.pas`: `TMbedTLSSocketHandler`
      (`Connect`/`Close`/`Shutdown`/`Send`/`Recv`/`BytesAvailable` + error
      getters), the `external` binds, and self-registration in `initialization`
- [x] **Test**: `TestLoopbackRejectsUnknownCa`, `TestLoopbackRejectsWrongHost`
- [x] **Implement** the handler's CA-file path (`CertificateData.CertCA`) and
      error mapping
- [x] **Test**: `TestHandlerDrivesTFPHTTPClient` — a real `TFPHTTPClient` GET
      over loopback returns the expected body
- [x] **Change** `src/hildegard.helper.llm.pas`: `uses ... hildegard.helper.tls`
      instead of `opensslsockets`
- [x] **Add** `test_tls` to `tests/hildegard_helper_tests.pas` and link the shim
      + test server + mbedTLS into the test targets

### Phase 4: CA trust (embed + override)

- [x] **Write** `scripts/fetch-cacert.sh` (pinned bundle + SHA-256 into
      `deps/cacert/cacert.pem`)
- [x] **Add** `scripts/gen-cacert-embed.sh` and a Makefile rule to generate and
      compile `build/gen/cacert_embedded.c` into the link
- [x] **Test**: `TestEmbeddedBundleIsPresent`, `TestBundleOverrideResolves`,
      `TestUnreadableOverrideIsConfigError`
- [x] **Implement** the shim's default embedded chain and
      `TLSBundleOverride`/`ValidateTLSConfig`

### Phase 5: Wire every shipping target

- [x] **Add** the mbedTLS link flags to `agent-cli`, `tui-agent`,
      `release-agent-cli`, `test`, and `test-leak` (the SQLite `-k` pattern)
- [x] **Confirm** no target links `opensslsockets`; the demo/store targets that
      do not use `llm` stay free of mbedTLS

### Phase 6: Field verification and docs

- [x] **Run** `make check` (functional + leak gate) — 706 tests, leak-clean
- [x] **Verify** the release binary completes a streamed HTTPS turn: a live
      Fireworks turn returned the expected reply, and `DYLD_PRINT_LIBRARIES`
      showed no `libssl`/`libcrypto` loaded during it
- [x] **Verify** `strings`/`nm` show no `libssl`/`libcrypto`/`opensslsockets`
      reference in the release binary (the mbedTLS stack is linked statically)
- [x] **Record** the release binary size delta: 2,347,632 -> 2,995,616 bytes
      (+648 KB: the mbedTLS archives plus the ~189 KB embedded CA bundle)
- [x] **Update** `HANDOFF.md` and `docs/features/FEATURES.md`; rename this TODO
      to `TLS_Foundation_v1.DONE.md`

## Dependencies & Ordering

- Vendoring (Phase 1) before the shim; the shim's real handshake (Phase 2)
  before the Pascal handler.
- The handler + `TFPHTTPClient` loopback test (Phase 3) before the LLM `uses`
  swap is trusted.
- CA embedding (Phase 4) after the handler works with an explicit CA file.
- Link wiring (Phase 5) last, once the unit is proven.

## Files to Create/Modify

### New Files

```
scripts/fetch-mbedtls.sh              pinned source fetch + checksum
scripts/fetch-cacert.sh               pinned CA bundle fetch + checksum
src/hildegard_tls_shim.h              shim contract
src/hildegard_tls_shim.c              mbedTLS client wrapper (opaque handle)
src/hildegard.helper.tls.pas          TSSLSocketHandler subclass + registration
tests/test_tls.pas                    unit + loopback integration tests
tests/tls_test_server.h               test-only server contract
tests/tls_test_server.c               test-only mbedTLS server
tests/fixtures/tls/localhost.crt      self-signed test certificate (test-only)
tests/fixtures/tls/localhost.key      throwaway test key (test-only)
```

### Modified Files

```
src/hildegard.helper.llm.pas          uses: opensslsockets -> hildegard.helper.tls
tests/hildegard_helper_tests.pas      add test_tls to the uses clause
Makefile                              vendoring, CA embed, link wiring
.gitignore                            fetched mbedTLS source, cacert, build/gen
HANDOFF.md                            current state + lessons
docs/features/FEATURES.md             status
```

## Success Criteria

- [ ] All tasks above checked
- [ ] A streamed HTTPS turn works over the vendored stack, behaviour unchanged
- [ ] The release binary works with no OpenSSL present; no `libssl`/`libcrypto`
      references remain
- [ ] `make check` passes (tests + leak gate)

## Notes & Considerations

- **`otool -L` proves nothing.** FPC `dlopen`s OpenSSL, so the current binary
  is already link-clean. Verify with a runtime HTTPS call and `strings`/`nm`.
- **The shim is the binding.** Do not mirror mbedTLS struct layouts in Pascal;
  the opaque handle is what keeps a version bump safe.
- **heaptrc does not see C `malloc`.** The leak gate will not catch an mbedTLS
  leak, so the shim exposes `hildegard_tls_live_count` and the test asserts it
  returns to zero.
- **Timeouts must not regress.** `Recv` keeps the "stalled read with
  `IOTimeout>0` yields 0/EOF" behaviour the OpenSSL handler had.
- **Test key is test-only.** `tests/fixtures/tls/` is throwaway and never linked
  into a shipping binary; say so in a README beside it.
- **mbedTLS default config** is accepted for v1; trimming it is a future
  consideration.
