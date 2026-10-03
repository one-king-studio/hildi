# TLS Foundation

## Overview

The helper's only network path today is `TFPHTTPClient` with FPC's
`opensslsockets` unit: **dynamically linked OpenSSL**. That choice was fine
while the helper ran on development machines, where OpenSSL is always
installed. It is wrong for the product this project is becoming: a self-
contained binary installed on pristine remote devices.

This feature replaces dynamic OpenSSL with a **vendored, statically linked TLS
library — mbedTLS — a decision the operator has committed to** — following the
exact pattern the project already uses for SQLite (`deps/` + fetch script +
static archive in the Makefile). When it ships, the release binary's "static, no runtime libs"
claim in the Makefile becomes fully true, and every future network feature —
Remote Agent Link above all — inherits a TLS story that survives a clean
install.

This is recorded as a **critical feature** because it is a prerequisite for
the deployment story, not an optimization: today a `release-agent-cli` binary
copied to a machine without OpenSSL fails at runtime, silently and far from
the cause.

## Problem Statement

The Makefile says the agent CLI release target is an "optimized, self-
contained production binary (static SQLite, no runtime libs)". That is only
half true: static SQLite, dynamic TLS. `hildegard.helper.llm` pulls in
`opensslsockets`, so the binary resolves libssl/libcrypto from the host at
launch. On a dev machine this is invisible. On the device the helper is meant
for — clean macOS or Linux box, no Homebrew, no openssl package — the binary
either fails to load or fails its first HTTPS call, and the error surfaces as
an inscrutable runtime failure far from the cause.

Every planned feature that talks to a network leans on the same latent gap:
Remote Agent Link holds an *authenticated, long-lived* TLS connection, where
the blast radius is larger still. Fixing the foundation once — behind the
existing transport seam — is cheaper than discovering the hole per feature.

- Apply the first Ponytail ladder rung honestly: the transport seam already
  exists (`TLLMTransport`; the unit header itself says it is "the only unit
  that knows about HTTP, TLS, SSE"), and the dependency pattern exists (SQLite).
  The genuine gap is narrow: a vendored TLS library, a transport that uses it,
  and build wiring. No HTTP framework, no certificate authority, no new
  protocol.

## Decision

**Committed: import a static TLS library — mbedTLS — vendored like SQLite.**
This is not an open option to relitigate in the SPEC; the operator has decided.
Dynamic OpenSSL is the rejected alternative, revisitable only if mbedTLS proves
unworkable with `TFPHTTPClient` (see Non-Goals and Constraints). What remains
for the SPEC is *composition*, not *choice*: how the vendored stack wires into
the transport, and how CA trust is provided.

## Goals

- Make the release binary genuinely self-contained: no runtime TLS dylibs,
  no host package prerequisites for HTTPS.
- Vendor mbedTLS under `deps/` with the SQLite pattern (pinned version, fetch
  script, static archive target), keeping the tree buildable from clean.
- Route all TLS through a single internal seam so the choice of library
  stays replaceable.
- Preserve every existing behaviour: SSE streaming, timeouts, cancellation,
  and the typed `TLLMErrorCode` set — tests stay green unchanged.
- Leave a documented, reversible decision trail, including the option not
  taken (dynamic OpenSSL) and the conditions that would reverse this.

## User Stories

- As an **operator**, I want to copy one release binary to a clean device and
  have HTTPS work, so installation needs no package manager and no OpenSSL.
- As a **developer**, I want TLS behind the same seam as SQLite vendoring —
  pinned version, fetch script, static archive — so the build is reproducible
  from a fresh clone.
- As a **developer**, I want existing transport tests and fakes to keep
  passing unchanged, so the swap is provably behaviour-preserving.
- As the **Remote Agent Link designer**, I want a TLS foundation that
  supports client certificates and long-lived connections, so the link spec
  consumes the foundation instead of reopening it.
- As a **debugger**, when a TLS handshake fails on a device, I want a typed,
  specific error (`leNetwork` with TLS detail, never a secret), so the
  failure is diagnosable in the field.

## Acceptance Criteria

### Functional Requirements

- [ ] All HTTPS traffic (currently: the LLM client's chat-completions stream)
      succeeds over the vendored TLS stack with behaviour identical to today:
      same streaming, same timeouts, same cancellation, same error mapping.
- [ ] The release agent CLI binary runs HTTPS on a host with **no** OpenSSL
      installed (verified by isolating the binary from system libssl/libcrypto
      — e.g. `DYLD_*`/`LD_LIBRARY_PATH` isolation or a clean container).
- [ ] The vendored library is pinned to an exact version under `deps/`, fetched
      by a script in `scripts/` (the `fetch-sqlite.sh` pattern), and compiled
      into a static archive by the Makefile.
- [ ] `leConfig` validation reports a missing or unreadable CA bundle as a
      distinct, actionable error; the bundle path is configurable (env/setting)
      with a sane built-in default.
- [ ] TLS detail on failure reaches `leNetwork`/`leHttpStatus` errors as safe,
      non-secret diagnostics; no key material, tokens, or session data in
      errors or logs.
- [ ] Transport fakes in the test suite are untouched; no test changes were
      needed beyond build wiring (behaviour-preserving swap).

### Non-Functional Requirements

- [ ] Portability: builds clean on macOS (aarch64) and Linux x86-64/aarch64;
      no `TSemaphore`-class platform traps introduced.
- [ ] Binary size: the static TLS stack adds a bounded, documented amount to
      the release binary (record the before/after size in the DONE notes).
- [ ] Performance: streaming throughput and time-to-first-token are
      unregressed (existing bench/`make perf` budgets still pass).
- [ ] `make check` passes (functional tests plus the leak gate); the leak gate
      passes with the C library in the process.
- [ ] Upgrades: bumping the vendored TLS version is a one-line pin change plus
      a rebuild, with the fetch script verifying a checksum.

## Success Metrics

### Quantitative

- Release binary starts and completes a streamed HTTPS LLM turn on a host
  with no OpenSSL present — the deployment smoke that fails today.
- Zero `dlopen`/link-time references to host libssl/libcrypto in the release
  binary (`otool -L` / `ldd` shows none).
- No measurable regression in first-token latency or streaming throughput.

### Qualitative

- "Self-contained binary" in the Makefile and HANDOFF is true without
  asterisks.
- The next network feature starts from a TLS foundation rather than a TLS
  decision.

## Constraints

### Technical

- Must build with Free Pascal 3.3.1, `{$mode delphi}`, and keep `make check`
  green.
- Must reuse the existing `TLLMTransport` seam in `hildegard.helper.llm`;
  the swap must not fork a second HTTP client or fork behaviour per-feature.
- Must follow the vendored-dependency pattern established by SQLite: pinned
  source under `deps/`, checksum-verified fetch script, static archive target
  in the Makefile, no system library fallback.
- CA bundle handling must work with the platform's standard trust store or a
  bundled CA file; the SPEC decides which and records why.

### Business / Time

- No external deadline. The work is gated by Remote Agent Link's need for a
  deployable transport, not by a date.

## Dependencies

### Internal

- `hildegard.helper.llm` - the `TLLMTransport` seam and `TFPHTTPTransport`;
  `opensslsockets` is referenced in this one unit, so the blast radius is one
  file.
- The SQLite vendoring pattern - `scripts/fetch-sqlite.sh` (pinned version,
  SHA3-256 check) and the `libsqlite` / static-archive targets in the Makefile.
- FPC's HTTP composition hook - `OnGetSocketHandler` / `GetSocketHandler`
  (`fphttpclient.pp`) and `TSSLSocketHandler` (`sslbase.pp`); a vendored
  backend plugs in as a socket handler rather than replacing the HTTP client.

### External

- The mbedTLS source (pinned version, vendored under `deps/`).
- A Pascal binding to the mbedTLS C API. FPC ships `packages/gnutls` but no
  mbedTLS binding, so a thin binding - or a small C shim compiled by the
  Makefile, as SQLite is - is part of this work.
- A CA bundle or the platform trust store for certificate verification.

## Risks

- **No Pascal binding for mbedTLS exists.** Mitigation: keep the binding behind
  the socket-handler seam and compile a small C shim in the Makefile if a
  direct binding proves fragile.
- **`TFPHTTPClient` composition is not plug-and-play.** Mitigation: use the
  existing `OnGetSocketHandler` hook with a custom `TSSLSocketHandler`; if that
  proves impractical, fall back to a minimal HTTP client behind the same
  `TLLMTransport` seam.
- **CA trust differs by platform.** Mitigation: the SPEC decides platform store
  vs bundled CA; `leConfig` reports a missing or unreadable bundle as a
  distinct, actionable error.
- **License and notice obligations differ from SQLite.** SQLite is public
  domain; mbedTLS is Apache-2.0. Mitigation: record the license and any NOTICE
  alongside the vendored source under `deps/`.
- **Binary size and build time grow.** Mitigation: record the before/after
  release size in the DONE notes; the Makefile already compiles C for SQLite.
- **The leak gate runs with a C library in the process.** Mitigation: free all
  mbedTLS contexts in one place and keep them off every error path.

## Out of Scope

- Remote Agent Link protocol work — this feature only makes the transport
  foundation deployable; the link consumes it later.
- Server-side TLS, certificate issuance, and certificate pinning in v1
  (pinning belongs to the Remote Agent Link spec if the threat model wants it).
- Windows targets.
- Replacing `TFPHTTPClient` itself unless the vendored stack makes it
  impossible; the SPEC decides transport composition and records why.
- Reopening the library choice: mbedTLS is committed (see Decision).

## Future Considerations

- Client certificates / mTLS for Remote Agent Link.
- Certificate pinning.
- TLS session resumption for long-lived links.
- A second backend (for example the FPC `gnutls` package) behind the same seam,
  should mbedTLS prove unsuitable.
- Automating the version bump (pin + checksum + rebuild) in the fetch script.

## Notes

- **ICE score: Impact 9, Confidence 6, Ease 4.** Impact is high: it is the
  difference between a binary that works on a clean device and one that does
  not, and every network feature inherits it. Confidence is moderate because
  the mbedTLS/Pascal binding and `TFPHTTPClient` composition are unproven.
  Ease is low: vendoring, a C-API binding, a socket handler, and CA handling
  are all new.
- **Decision recorded above (Committed):** dynamic OpenSSL via `opensslsockets`
  is the rejected alternative, revisitable only if mbedTLS proves unworkable
  with `TFPHTTPClient`.
- **Reuse note (Ponytail):** the `TLLMTransport` seam and the SQLite vendoring
  pattern exist; the new pieces are the vendored source, the binding, the
  socket handler, and the CA configuration.
