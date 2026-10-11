# Tool Limits

## Overview

One model for every limit a tool can hit, so a limit **advises** the model rather
than **failing** its call. Only an absolute ceiling blocks; only hard errors and
truncations are persisted.

The bug it fixes: today a limit warning effectively *fails* the tool call, so the
model is forced into a follow-up call just to learn it hit a limit.

## Decision

Three tiers, by what happens to the call and what is persisted:

| Tier | The call | Persisted? | Where the model sees it |
| --- | --- | --- | --- |
| **Advisory** (soft limit) | **succeeds** | **no** | a loop-only nudge alongside the result |
| **Truncation** | succeeds (capped) | **yes** | a marker in the result |
| **Hard error** (absolute ceiling) | **fails** | **yes** | the error result |

1. **Soft limits never fail the call.** A limit warning is a **nudge**, not an
   error. The tool returns its result and the model continues; it is not forced
   to re-call.
2. **Advisories live in the loop and are not persisted.** A nudge is ephemeral —
   it belongs to the turn in which it happened. The stored record is the result,
   not the nudge.
3. **Only the absolute limit blocks.** A hard ceiling is the one limit that fails
   the call, and it is persisted as a hard error.
4. **Truncation is persisted.** Both the agent and the operator must know output
   was cut, so the `[output truncated …]` marker stays in the result.
5. **Only hard errors persist.** No other limit leaves a durable record.

## `run_command` timeout

- **The default is 5 minutes** (`ProfileDefaultTimeoutMs = 300000`) — raised from
  30 s, which was too short for real builds and installs.
- **The model may override it** when it knows the command is long, by passing a
  larger `timeout_ms`.
- **There is an absolute ceiling** (`AbsoluteTimeoutMs`). A request above it is
  **clamped** and the attempt to exceed it produces an **advisory** (a nudge, per
  the tiers above) — not a failure.
- **The operator may still cap** via `MaxTimeoutMs` (config; 0 = none).
- **Enforcement is to be verified.** The timeout is checked in the runner's read
  loop (`process.pas:196`); confirm it fires for a command that produces *no*
  output (a hung command) and not only between readable chunks.

## Goals

- A limit nudge is delivered without failing the call or persisting a record.
- The model sees the nudge and the result together, in the same turn.
- The absolute ceiling is the only blocking limit, and it is a hard error.
- The timeout default is 5 minutes; the model can raise it; the absolute clamps
  and nudges.

## Acceptance Criteria

- [ ] A soft limit yields the result **plus** a nudge; the call succeeds.
- [ ] The nudge is not persisted (no message row); the result is.
- [ ] The absolute limit fails the call with a persisted hard error.
- [ ] A truncation stays in the result as a marker (persisted).
- [ ] `run_command`'s default timeout is 5 minutes.
- [ ] A `timeout_ms` above the absolute is clamped, with a nudge.
- [ ] A command that hangs with no output still times out (enforcement verified).

## Open Questions

- **The nudge channel — decided: the tool response's `<context>`.** Advisories
  reach the model as a loop-only `<context>` block prepended to the tool response
  on the way out (never persisted) — the same invariant as the user wrapper. The
  soft tool-call limit now **runs** its calls and nudges, instead of intercepting
  them; only the hard limit (the absolute ceiling) intercepts.
- **The absolute ceiling value.** Not yet chosen; a named constant so it is one
  edit.
- **Which limits are advisory.** Enumerate them (output cap, result count,
  recursion depth, …) so each is classified once.

## Notes

- **Related:** `User_Message_Wrapping` (dynamic context in the loop, not
  persisted); `Context_Budget` (its `[output truncated … recall_tool_result]`
  marker is the truncation tier, and its cap is a soft limit that today forces a
  follow-up).
- **The principle:** a limit the model cannot act on in the same turn should not
  fail the turn.
