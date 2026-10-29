# Tool Approvals

## Overview

A generic, durable **approval whitelist** for tool calls. Every tool call is
identified by a **ref** (tool identity) plus a **params** token list, and an
approval records whether that ref/params may run freely, at one of three scopes:
**global**, **workspace**, or **session**. Approvals accumulate as the operator
allows them, so later interactions do not re-ask.

This is deliberately tool-agnostic, because future tools (MCP servers and other
suites) are only granular by tool name or tool name + parameters, whereas the
built-in shell tool is granular down to individual command arguments. The
built-in `run_command` is the first consumer; it will adopt `command_run:<bin>`
as its ref and its command arguments as params.

It supersedes the command-specific policy (the `command.policy.*` settings, the
`=` exact marker, and the interleaved `*`) and the command audit (the
`requests`-table rows). The session ledger feature owns history and audit; this
feature owns only the whitelist.

## Problem Statement

Today the shell tool's allow/deny rules live in store settings, are
command-specific, and are not generic; approvals are persisted as flat strings;
and there is no notion of scope (a rule is only global). There is no way to say
"read-only commands are allowed everywhere, but this directory's commands are
allowed only here", and no path to the MCP granularity (tool name / name +
params).

The existing audit also conflates two concerns: the whitelist (what may run
without asking) and the ledger (what did run, for history/restore). Splitting
them makes the whitelist small, queryable, and reusable by every tool.

## Goals

- Define one approval record: `(scope, workspace, session, ref, params,
  any_params)`.
- Define refs uniformly: `command_run:<bin>` for the shell tool, `suite:function`
  for external tools.
- Match a call against approvals: ref exact, and either params exact or
  `any_params` with the stored params as a prefix (a **terminal** wildcard).
- Resolve scopes: deny anywhere wins; otherwise an allow at session, workspace,
  or global scope suffices (session > workspace > global for reporting).
- Persist global/workspace/session approvals in the store; workspace and session
  identity come from the Workspaces and Sessions features.
- Provide the approval decision to tools: allow, ask, or deny, with the matching
  rule for the operator.
- Give the command tool a per-ref adapter so `run_command:<bin>` is classified
  from the parsed command, with no command-specific storage.
- Let **each tool define its own approval options** (its granularity); the
  harness only provides the prompt, the scope choice, and persistence. The
  command tool offers once / exact / any and prefix-subtree options.

## User Stories

- As an **operator**, I want read-only commands (`ls`, `cat`, `grep`) approved
  globally once, so the agent can explore without repeated prompts.
- As an **operator**, I want build commands approved for a workspace only, so a
  different checkout is not implicitly trusted.
- As an **operator**, I want to approve `php artisan *` without approving `php *`,
  so a narrower subtree is trusted than the whole interpreter.
- As an **operator**, I want a named session's approvals to persist and be
  restorable, so a long-running pairing does not re-ask.
- As a **harness author**, I want an MCP tool approved as
  `browser:navigate_to_url` (all params) or
  `browser:navigate_to_url:url=https://x` (exact), so external tools need no
  bespoke policy.
- As a **harness author**, I want the whitelist to be one small table and one
  matcher, so new tools get approvals for free.

## Acceptance Criteria

### Functional Requirements

Records

- [ ] An approval is `(scope, workspace, session, ref, params, any_params,
      created_at)` with `scope` in global/workspace/session.
- [ ] `ref` is the tool identity: `run_command:<bin>` for the shell tool,
      `suite:function` for external tools.
- [ ] `params` is an ordered token list (JSON array); `any_params` is a boolean.
- [ ] Global approvals have no workspace/session; workspace approvals have a
      workspace and no session; session approvals have a session (and its
      workspace).

Matching

- [ ] The `ref` must match exactly.
- [ ] With `any_params = false`, the stored params must equal the call params
      exactly (an empty list means "no parameters", e.g. bare `cat`).
- [ ] With `any_params = true`, the stored params must be a **prefix** of the
      call params (an empty prefix approves the whole ref, e.g. `browser:
      navigate_to_url`).
- [ ] The wildcard is terminal only; there is no interleaving and no `=` marker.

Scope resolution

- [ ] A matching deny at any scope denies the call.
- [ ] Otherwise, a matching allow at session, workspace, or global scope allows
      the call.
- [ ] No matching allow means **ask**.
- [ ] A deny and an allow that both match resolve to deny.

Tool-owned options

- [ ] Each tool implements an approval adapter that reports, for a specific call:
      its `ref`, its `params`, and the **approval options** it offers.
- [ ] An option carries a short key, a human label, whether it persists, and the
      rule (ref/params/any) it would store.
- [ ] The harness presents the tool's options plus deny, and the scope choice
      (global/workspace/session); it does not hard-code granularity.
- [ ] A tool may offer coarser or finer options than another; the harness is
      indifferent.

Command adapter

- [ ] The shell tool derives its ref as `run_command:<bin>` and its params as
      the command's argument tokens after the executable.
- [ ] Its options, per parsed segment, are: allow once; allow this exact command
      (`run_command:cat` params `[test]`); allow this command with any arguments
      (`run_command:cat` params `[]`, `any_params=true`); and, where a non-flag
      prefix exists, allow that prefix subtree (for example
      `run_command:php` params `[artisan]`, `any_params=true`).
- [ ] Approving bare `cat` stores `run_command:cat`, params `[]`,
      `any_params=false`.
- [ ] Path-aware trust is deferred: the workspace root is the cwd and
      relative-path base, but command-level approvals already gate every command,
      so a separate path gate would either be a no-op or block the global
      read-whitelist. Path-aware rules are future work (see Notes).

Operator flow

- [ ] On ask, the tool supplies its options; the operator selects one (or deny)
      and, for a persisting option, a scope.
- [ ] A denial is reported to the tool with the ref, params, and the matching
      rule.

Persistence

- [ ] Approvals are stored in the SQLite store and survive restarts.
- [ ] Redundant approvals (same scope/workspace/session/ref/params/any) are not
      duplicated.
- [ ] The matcher is testable with an in-memory approval set, with no store.

### Non-Functional Requirements

- [ ] Reliability: leak-clean under `make test-leak`.
- [ ] Security: no matching allow means ask; ambiguity never allows; a deny
      always wins; the matcher never evaluates the call.
- [ ] Portability: pure Pascal, macOS and Linux; no platform assumptions.
- [ ] Performance: matching is a small in-memory scan of the relevant scopes.
- [ ] `make check` passes.

## Success Metrics

### Quantitative

- Table-driven tests cover exact, prefix, whole-ref, deny, and cross-scope cases.
- A command tool round trip runs entirely against an in-memory approval set.

### Qualitative

- Adding a new tool's approvals is a ref/params adapter, not a new store.
- The whitelist reads as a small list of `ref:params` entries.

## Constraints

### Technical

- Must build with FPC 3.3.1, `{$mode delphi}`, and keep `make check` green.
- Must reuse `hildi.store`; a new migration adds the approvals table.
- Must not depend on the Sessions ledger feature to function; session-scoped
  approvals require it, but global/workspace approvals do not.
- The command tool's existing `TCommandPolicySource`/audit are removed in favor of
  this.

### Business / Time

- This is the foundation for every future tool's trust model; MCP arrives soon.

## Dependencies

### Internal

- `hildi.store` - approvals table (new migration) and workspace/session
  references.
- Workspaces feature - workspace identity and the active workspace root.
- Sessions/Ledger feature - session identity.
- `hildi.command.tool` - the first consumer and the adapter.
- `hildi.command.policy` - the command parser (segments) used by the
  adapter; the policy/allow/deny/roots model is retired.

### External

- None.

## Risks

- **Over-broad approvals.** `any_params` on an interpreter (`command_run:bash`,
  any) is effectively full trust. Mitigation: the operator chooses it explicitly;
  the decision reason names the rule; deny still wins.
- **Ref-key explosion.** Persisting every exact command could bloat the table.
  Mitigation: the "any" choice approximates a subtree; redundant rows are
  suppressed; the table is small and queryable.
- **Scope confusion.** Global vs workspace mistakes are easy. Mitigation: prompts
  state the scope and the matcher reports which rule matched.
- **MCP param canonicalization.** External tools need a stable param token order.
  Mitigation: each tool adapter defines its canonical params; v1 documents the
  contract.

## Out of Scope

- The session ledger and message restore (Sessions/Ledger feature).
- Workspace discovery and access rules beyond the active workspace (Workspaces
  feature).
- Approval propagation to a peer agent or across devices (Remote Agent
  Link, later).
- Rich rule editing UIs (a CLI list/remove command may come later).

## Future Considerations

- A `policy list` / `policy remove` CLI for reviewing the whitelist.
- Per-tool default scopes (for example "read commands default global").
- Approval expiry or one-time-per-day rules.
- Export/import of the whitelist for provisioning.
- Server-side approval mirroring via Agent to Agent (A2A).

## Notes

- **ICE score: Impact 9, Confidence 7, Ease 7.** It unblocks a trust model for
  every tool, not just the shell. Confidence is good because the model is small
  and the store exists; ease is good except for the schema and the command-tool
  refactor.
- **Sequencing:** approvals need workspace and session identity, so the Workspaces
  feature lands first or alongside; the Sessions/Ledger feature can follow.
- **Reuse note (Ponytail):** the store, migrations, and the command parser exist.
  The new pieces are the approvals table, the matcher, the scope resolution, and
  the command adapter.
