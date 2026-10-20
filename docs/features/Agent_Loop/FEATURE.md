# Agent Loop

**Status:** In Progress — code complete; the `text` scenario of
[Live Smoke](../Live_Smoke/FEATURE.md) verifies it end to end. What remains is a
live model-provider check, which needs a key and so cannot be committed.

## Overview

This feature gives hildegard-helper its brain: a single-threaded agent loop that
talks to an OpenAI-compatible LLM provider (Fireworks.ai by default), injects
tools, executes the tools the model asks for, and keeps re-querying the model
until it reaches a proper stop reason. Conversations are kept in memory across
turns behind a small store interface, so a future SQLite-backed store can add
recall, restore, and detailed logs without changing the loop.

It ships as a testable library core plus a thin interactive CLI example: the user
types a prompt, the loop streams the model's answer token by token, and the
conversation continues over multiple turns. Streaming (SSE) is used from the
start, so tool-call arguments that arrive split across chunks must be
accumulated correctly before execution.

## Problem Statement

The execution core can run commands and the link/store features will let those
commands arrive from elsewhere, but nothing decides *what* to run. Without an
agent loop, there is no reasoning step, no tool use, and no conversation - the
helper is a remote shell, not an agent.

The existing codebase has no LLM client, no tool abstraction, no conversation
model, and no notion of a stop reason or a tool-call round trip. Every one of
those is required before tools (including the parked sandboxed script compute and
future system actions) can be usefully wired in.

Applying the first rung of the Ponytail ladder (`docs/guidelines/ponytail.md`):
the HTTP, TLS, and JSON plumbing already exist in FPC (`fphttpclient`, `fpjson`),
and command execution already exists in `hildegard.helper.process`/`pool`. The
gap is the reasoning loop, the tool contract, and the conversation store seam -
not an LLM SDK and not a general async framework.

## Goals

- Provide a single-threaded, deterministic agent loop with no background threads.
- Speak to any OpenAI-compatible provider over a configurable base URL, model,
  and API key, with Fireworks.ai as the default endpoint.
- Stream responses via SSE: surface text incrementally and accumulate fragmented
  tool calls.
- Support tool injection: declare tools with a name, description, and JSON-schema
  parameters, and dispatch invocations to Pascal handlers.
- Execute zero or more tool calls per assistant turn, feed results back, and
  re-query until a proper stop reason (`stop`) or a bounded iteration limit.
- Keep multi-turn conversation state in memory behind a store interface that a
  SQLite implementation can satisfy later.
- Demonstrate the whole thing with an interactive CLI that supports multi-turn
  chat, streaming output, and clean error handling.
- **Recover from a transient request failure** — a network/resolution error, a
  429, or a 5xx — by retrying the request with bounded backoff, and **surface an
  accurate, actionable error** to the operator when it cannot be recovered.
- Remain testable offline against an injectable transport and a fake SSE stream.

## User Stories

- As a **harness author**, I want a single-threaded agent loop I can call with a
  user message and get back a final answer, so I can add agentic behavior without
  managing threads.
- As a **harness author**, I want to inject tools with descriptions and
  parameter schemas, so the model can call them and I can act on the calls.
- As the **agent**, I want my tool calls executed and their results fed back, so
  I can reason further and produce a final answer.
- As a **user**, I want to chat with the agent over multiple turns with streamed
  output, so it feels responsive and remembers the conversation.
- As a **user**, I want clear errors when the provider fails or the API key is
  missing, so I know what went wrong instead of getting a silent hang.
- As an **operator**, I want my API key read from configuration and never logged,
  so it is not leaked.
- As a **developer**, I want a conversation store interface with an in-memory
  implementation, so a SQLite store can later add recall and restore without
  touching the loop.

## Acceptance Criteria

### Functional Requirements

Configuration and provider client

- [ ] The provider client is configured with a base URL, model, and API key, with
      Fireworks.ai as the default base URL.
- [ ] Configuration is read from environment variables and/or a config file, and
      a missing API key produces a clear, distinct error before any request is
      made.
- [ ] Requests are sent as OpenAI-compatible chat completions with the
      conversation messages and the declared tools, with `stream` enabled.
- [ ] The API key is sent only as the authorization header and never appears in
      logs or error messages.

SSE streaming

- [ ] The client parses a server-sent-event stream, handling `data:` frames and
      terminating on the `[DONE]` sentinel.
- [ ] SSE frames split across network reads are reassembled correctly (partial
      lines are buffered, not dropped or mis-parsed).
- [ ] Non-data lines (comments, blank lines, keep-alives) are ignored.
- [ ] Text deltas are surfaced incrementally as they arrive, not withheld until
      the stream ends.
- [ ] Tool-call deltas fragmented across chunks are accumulated by call index,
      including a name that arrives separately from its arguments.
- [ ] The final `finish_reason` is captured and exposed to the loop.
- [ ] Malformed or truncated streams, and HTTP error statuses (for example 401,
      429, 5xx), surface as distinct errors.

Agent loop

- [ ] Given a user message, the loop sends a request, accumulates the assistant
      response, and returns an answer when the stop reason is `stop`.
- [ ] When the assistant response contains tool calls, the loop executes each
      one, appends the tool results to the conversation, and re-queries the model.
- [ ] Multiple tool calls in a single assistant turn are all executed and
      reported back before the next query.
- [ ] A terminal stop reason other than `stop` (for example `length` or
      `content_filter`) is reported distinctly and never treated as a normal
      answer.
- [ ] The loop is bounded by a maximum number of tool iterations; exceeding it
      returns a distinct error rather than looping forever.
- [ ] The assistant message (including its tool calls) and each tool result are
      stored in the conversation in the order the provider requires.
- [ ] A call to an unknown tool returns an error result for that call without
      crashing the loop.
- [ ] A tool handler that fails returns an error result for that call without
      crashing the loop.

Tools

- [ ] A tool is declared with a name, a description, and a JSON-schema parameter
      description, and is advertised to the provider.
- [ ] Tools are injected into a loop instance at construction or registration
      time.
- [ ] A tool handler receives parsed arguments and returns a string result that
      is sent back to the provider.
- [ ] The declared parameter schema is validated enough to reject missing
      required arguments with an error result rather than a crash.
- [ ] A built-in `get_system_time` tool is provided as the reference tool and
      returns the current time in a documented format.

Conversation store

- [ ] The loop reads and writes conversation messages through a store interface,
      not directly.
- [ ] An in-memory store implementation persists messages for the lifetime of
      the process.
- [ ] A system prompt can be set and is included before user messages.
- [ ] Messages from earlier turns are included in subsequent requests, so the
      conversation is genuinely multi-turn.
- [ ] A second store implementation can be added without modifying the loop
      (demonstrated by the in-memory store satisfying the same interface a SQLite
      store would).

Interactive CLI

- [ ] The CLI reads a prompt from stdin, runs it through the loop, and streams
      the assistant's answer to stdout.
- [ ] Successive prompts continue the same conversation with retained context.
- [ ] The CLI supports an exit command and end-of-input to quit cleanly.
- [ ] Provider, configuration, and tool errors are displayed without terminating
      the session.
- [ ] The CLI exits with a non-zero status when the initial configuration is
      invalid (for example, a missing API key).

### Non-Functional Requirements

- [ ] Single-threaded: the loop performs no background work and starts no
      threads; behavior is deterministic given a transport.
- [ ] Reliability: leak-clean under the heaptrc gate; the HTTP client, streams,
      and store are freed on every path.
- [ ] Portability: builds and runs on macOS and Linux with Free Pascal 3.3.1;
      `cthreads` is first on Unix.
- [ ] Security: TLS certificate verification is enabled; the API key is never
      logged or committed; configuration is read from environment/file, not
      hard-coded.
- [ ] Testability: the provider transport is injectable, so the entire loop,
      SSE parsing, tool dispatch, and store behavior are tested offline against a
      fake stream, with no network access.
- [ ] Performance: streamed text is observable before the response completes;
      no full-response buffering before display.
- [ ] `make check` passes (functional tests plus the leak gate).

## Success Metrics

### Quantitative

- First streamed token is observable before the response finishes, in a test that
  asserts incremental delivery.
- A full tool round trip (call `get_system_time`, feed the result back, receive a
  final answer) completes against a fake provider in a test.
- The complete feature test suite runs offline, deterministically, in a time
  comparable to the existing suite.
- No leaks reported by `make test-leak`.

### Qualitative

- Adding a new tool is a local change: declare it and register a handler.
- Errors (bad key, HTTP failure, malformed stream, unknown tool) are distinct and
  actionable.
- The loop reads as a clear synchronous sequence, not a tangle of callbacks.

## Constraints

### Technical

- Must build with Free Pascal 3.3.1, `{$mode delphi}`, and keep `make check`
  green.
- Must use FPC `fphttpclient` (fcl-web) for HTTP and `fpjson`/`jsonparser` for
  JSON; do not add an LLM SDK or a new HTTP dependency without a SPEC decision.
- The core loop is single-threaded and must not depend on the existing agent
  pool; tools may use it later.
- The provider must be OpenAI-compatible; non-compatible APIs are out of scope.
- Conversations are in-memory only in v1; no on-disk persistence.

### Business / Time

- This is the core capability of the helper; the store, remote link, and
  sandboxed-script features build on the loop's tool and message model.

## Dependencies

### Internal

- New `hildegard.helper.*` units anticipated: an OpenAI-compatible provider
  client, an SSE parser, a tool registry/contract, the agent loop, and a
  conversation store interface with an in-memory implementation (exact
  boundaries decided in the SPEC).
- `hildegard.helper.process`/`pool` will back richer tools later, not in v1.

### External

- FPC `fcl-web` (`fphttpclient`) and `fpjson`/`jsonparser`.
- A reachable OpenAI-compatible endpoint (Fireworks.ai by default) and an API
  key, for manual/integration use only.

## Risks

- **Streaming support in `fphttpclient`** - incremental reads during an in-flight
  response may be limited, which would undermine token-by-token output.
  Mitigation: verify early in the SPEC; fall back to an event-based read or a
  minimal socket-level client if needed.
- **SSE and tool-call fragmentation edge cases** - chunk boundaries can split
  frames, JSON, or tool-argument strings. Mitigation: a dedicated, unit-tested
  SSE parser and per-index tool-call accumulation.
- **Provider drift despite "OpenAI-compatible"** - Fireworks and others differ at
  the edges. Mitigation: keep the provider seam thin and isolate
  compatibility assumptions in one unit.
- **Runaway tool loops** - a model may call tools indefinitely. Mitigation: a
  maximum-iteration bound with a distinct error.
- **Infinite/blocking requests** - a hung connection stalls a single-threaded
  loop. Mitigation: connect and read timeouts, surfaced as errors.
- **API key leakage** - Mitigation: read from environment/file, never log the
  authorization header, never commit credentials.
- **Streaming complexity vs. the local-first test ethos** - Mitigation: inject
  the transport and test the loop entirely against fake SSE streams.

## Out of Scope

- SQLite-backed sessions, recall, restore, and detailed conversation logs (a
  separate feature; this one only defines the store seam).
- Non-OpenAI provider APIs (Anthropic, Gemini, etc.).
- Parallel or multi-threaded tool execution and concurrent sessions.
- A rich terminal UI; the CLI is line-based.
- Token accounting, cost tracking, context-window trimming, and summarization.
- Request **idempotency**: a retried POST is a fresh request, not a deduplicated
  one (the provider's streaming API makes a partial response un-resumable).
- Tool permissioning and approval flows.
- Embeddings, retrieval, and long-term memory.

## Future Considerations

- A SQLite store implementation of the conversation store interface, adding
  session recall, restore, and durable logs (see Local SQLite Store).
- Streaming-aware tool-call display in the CLI.
- Context budgeting: trimming, summarization, and token accounting.
- Provider-specific backoff hints beyond `Retry-After`.
- A circuit breaker across turns, so a provider that is down is not hammered.
- Richer tools, including the parked sandboxed script compute and system actions.
- Provider adapters beyond the OpenAI-compatible surface.
- Letting the Remote Agent Link drive tool calls generated by this loop.

## Notes

- **ICE score: Impact 10, Confidence 7, Ease 5.** Impact is maximal: this is the
  reasoning core of the helper. Confidence is good for the protocol (SSE and
  OpenAI tool calling are well-understood) but moderate for FPC's streaming HTTP.
  Ease is moderate: parsing, tool schema handling, and offline testing all take
  care.
- Sequencing: independent of Local SQLite Store and Remote Agent Link, but its
  store interface is the seam the SQLite feature later fills, and its tool model
  is what sandboxed scripts and remote actions will plug into.
- Reuse note (Ponytail): HTTP, TLS, and JSON already exist in FPC; command
  execution already exists in the process/pool units. Only the loop, tool
  contract, and store seam are new. A hand-rolled HTTP stack or an LLM SDK would
  climb past the available rung.
