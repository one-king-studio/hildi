# Command Tool

## Overview

This feature gives the agent a shell: a `run_command` tool that executes a
command through the existing process runner, plus a **policy layer** that decides
whether a command may run freely, must be approved by a human, or is denied
outright. Commands are parsed into their individual segments so the policy can
reason about each executable and each literal path argument, and the resulting
policy (allow/deny patterns, allowed roots, remembered approvals) is stored in
the local SQLite store.

The policy is a **guardrail, not a sandbox**. It raises the cost of a bad or
surprising command and makes the agent's intended actions visible and
reviewable; it does not confine a determined process at the OS level. That
distinction is deliberate and load-bearing (see Risks).

**v1 targets Unix hosts and the POSIX shell (`/bin/bash`).** Windows is a
planned follow-on, not a v1 deliverable: the shell to invoke, the quoting and
operator syntax to parse, and the path semantics differ by platform, so the
shell, parser, and path checks sit behind an explicit platform seam (a shell
profile plus a syntax mode) rather than being hard-wired to POSIX. v1 implements
only the POSIX mode, but it must not bake POSIX assumptions into shared units, so
adding a `cmd.exe` mode later is additive rather than a rewrite. The current
foundation is Unix-only in several places (the runner hard-codes `/bin/bash`,
uses Unix-only process-group/select code, and the vendored SQLite build is
Unix-only); v1 accepts that and records the foundation gaps Windows will need.

## Problem Statement

The harness can already execute a command (`hildi.process`) and the
loop can already dispatch tools (`hildi.agent`), but nothing decides
*which* commands should run. The only built-in tool is `get_system_time`. For the
helper to be useful it must run real commands; for it to be safe to leave
running, an operator must be able to say "these commands are fine, ask me about
anything else, never run these", and to see what the agent tried to run.

Today there is no shell tool, no command parsing, no notion of a policy, no
approval path, and no place to keep allow/deny decisions. The gap is the tool,
the parser/classifier, the policy engine, and the approval seam - not command
execution, which exists.

Applying the first rung of the Ponytail ladder (`docs/guidelines/ponytail.md`):
execution already exists (`hildi.process`), durable key/value settings
already exist (`hildi.store`), JSON already exists (`fpjson`), and the
tool contract already exists (`TToolRegistry`). The genuinely new pieces are the
command parser/classifier, the policy decision, and the tool wiring.

## Goals

- Provide a `run_command` tool that executes a command via the bounded process
  runner and returns its output, exit code, and timeout/cancel status to the
  model.
- Parse a command line into simple-command segments (respecting quotes and
  escapes) and extract, per segment, the executable and its arguments.
- Classify each segment against a stored policy: **allow**, **ask**, or **deny**.
- Best-effort path analysis: identify literal path arguments and redirection
  targets, and flag those that escape the allowed roots.
- Support interactive approval: when the policy says *ask*, prompt the operator
  with the exact command and the reason, and allow a session "always allow".
- Require a short, human-readable **reason** on every tool call, so the operator
  can see why the agent is asking to run something and the audit trail records
  intent, not just the command.
- Persist the policy and remembered approvals in the SQLite store (settings),
  and record an audit trail of attempted commands and decisions.
- Run on Unix (macOS and Linux) against the chosen POSIX shell, with shell,
  parser syntax mode, and path semantics selected through a platform seam so
  Windows (`cmd.exe`) can be added later without reworking the parser or policy.
- Be honest in the API and the docs about what the policy can and cannot
  guarantee, and about what Windows support will still require from the
  foundation.

## User Stories

- As an **operator**, I want commands matching my allowlist to run without
  prompting, so the agent stays useful without constant interruption.
- As an **operator**, I want anything not covered by my allowlist to prompt me
  with the exact command before it runs, so I can catch surprises.
- As an **operator**, I want to mark specific commands as always denied, so a
  destructive pattern can never run by accident.
- As an **operator**, I want to see which executable(s) a command line will run
  and which literal paths it touches, so approval is informed rather than blind.
- As an **operator**, I want the agent to state a short reason for each tool call,
  so I can judge the request and read the audit log as intent, not just argv.
- As an **operator**, I want to approve a command once, only for that exact
  command, or for any arguments, so repeated safe commands stop nagging me while
  changed arguments still ask.
- As an **operator**, I want my policy and remembered approvals to survive
  restarts, so I configure once.
- As an **operator**, I want a durable audit trail of what was attempted, allowed,
  denied, and its outcome, so I can review what the agent did.
- As a **harness author**, I want the policy engine to be a pure, injectable
  component, so it is fully testable without executing anything.
- As the **agent**, I want a clear error when a command is denied or fails, so I
  can choose a different approach.
- As a **harness author**, I want the shell, parser syntax, and path rules behind
  a platform seam, so a future Windows operator can be supported without a
  rewrite.

## Acceptance Criteria

### Functional Requirements

Command tool

- [ ] A `run_command` tool is registered and advertised with a documented
      parameter schema (`command` required; optional `cwd` and `timeout_ms`).
- [ ] The tool executes the command through `hildi.process`
      synchronously and returns combined stdout/stderr plus the exit code.
- [ ] A command that times out or is cancelled reports that distinctly (using the
      existing 124/130 conventions), not as a generic failure.
- [ ] Output returned to the model is size-capped, with an explicit truncation
      marker, so a chatty command cannot blow up the context window.
- [ ] The tool never raises; failures become an error tool result.

Tool-call reason (shared tool contract)

- [ ] Every advertised tool requires a non-empty `reason` string in its
      parameters, injected or validated by the tool contract so it cannot be
      forgotten by a tool author.
- [ ] A tool call whose arguments omit `reason`, or supply a blank one, is not
      executed; it returns an error tool result and the loop continues.
- [ ] The reason is surfaced to the transcript on the tool-call event, so it can
      be displayed, and to the command tool so it appears in the approval prompt
      and the audit record.
- [ ] The reason is data, displayed and stored, never interpreted as a command.

Platform

- [ ] v1 executes through a POSIX shell, default `/bin/bash -c`, selectable via
      configuration (for example `$SHELL` or an explicit policy setting).
- [ ] The shell is described by a small platform/profile abstraction (executable,
      argument form, syntax mode, path style) rather than being hard-coded in
      the tool, even though only the POSIX profile ships in v1.
- [ ] The command parser and policy take a syntax mode as input; v1 implements
      the POSIX mode, and the type reserves the `cmd.exe` mode for later.
- [ ] Path classification is implemented for POSIX paths (`/`, `~`, relative
      `..`); it must not resolve, normalise, or emit Windows-style paths in v1.
- [ ] Attempting to run on a platform whose shell or store dependencies are not
      yet available fails with a clear configuration error, not a crash or a
      silent wrong-shell invocation.

Command parsing

- [ ] In POSIX mode, a command line is split into simple-command segments at
      unquoted `;`, `&&`, `||`, `|`, `&`, and newlines.
- [ ] Segments are tokenized respecting POSIX single quotes, double quotes, and
      backslash escapes; a quoted or escaped operator is not treated as an
      operator.
- [ ] For each segment the executable (argv[0]) and its arguments are extracted,
      skipping leading `VAR=value` assignments.
- [ ] Redirection operators and their targets are recognised and separated from
      the argv.
- [ ] A syntactically unparseable command (for example unbalanced quotes) is
      classified as **ask**, never silently allowed.

Policy

- [ ] The policy returns one of three decisions per command line: allow, ask, or
      deny; a deny on any segment denies the whole command.
- [ ] The decision is derived from stored allow patterns, deny patterns, and
      allowed roots, matched against segment executables and literal paths.
- [ ] Deny patterns take precedence over allow patterns.
- [ ] A command line with no matching allow rule is **ask** by default (never
      allow-by-default).
- [ ] Allowlisting an interpreter or indirection command (`sh`, `bash`, `env`,
      `xargs`, `sudo`, `eval`, and the like) is treated as high-risk and requires
      explicit acknowledgment to add.
- [ ] Best-effort path checks flag literal absolute paths, `~`, and `..`
      traversals that escape the allowed roots; paths from unexpanded variables
      (`$HOME/...`) are reported as unresolvable rather than assumed safe.
      (Windows path forms are reserved for the future `cmd.exe` syntax mode.)
- [ ] Matching is on the executable name and the literal argument tokens; the
      policy never evaluates the command.

Approval

- [ ] Approval is requested **per simple-command segment**, not once for the
      whole line: `cat /etc/os-release && uname -a` shows and decides those two
      commands separately. The whole line is still executed as one command once
      every segment is approved.
- [ ] The approval handler may choose: allow this once, always allow this exact
      command (executable plus arguments), always allow this executable with any
      arguments, or deny. The default with no handler available is deny.
- [ ] "Always allow any arguments" persists a wildcard pattern
      (`<executable> *`) that covers all later use regardless of arguments.
      "Always allow this exact command" persists the exact argv, so a different
      argument needs a new approval.
- [ ] A wildcard approval overrides granular approvals: once given, later
      matching segments in the same command (and later commands) do not prompt.
- [ ] Decisions are made from the parsed segments; a deny on any segment refuses
      the whole command and nothing is executed.
- [ ] In non-interactive mode (`-p`, piped stdin) with no handler, an *ask*
      decision is denied, never silently allowed.
- [ ] A denied command returns a distinct error tool result naming the
      offending segment and the policy reason; it is not executed.

Store integration

- [ ] Allow patterns, deny patterns, allowed roots, and remembered approvals are
      read from and written to `hildi.store` settings.
- [ ] The policy is reloaded from the store when it changes, or at session start;
      a missing policy yields safe defaults (ask everything, deny nothing).
- [ ] An audit record is written for each attempted command with the decision, the
      agent's stated reason, the approver (if any), and the outcome (exit code,
      timeout, denial).
- [ ] The store is optional at the policy-engine level: the engine is testable
      with an in-memory policy source, so no test touches SQLite.

### Non-Functional Requirements

- [ ] Reliability: leak-clean under `make test-leak`; the runner thread and all
      owned streams/objects are freed on every path.
- [ ] Portability: builds and runs on macOS and Linux with FPC 3.3.1;
      `cthreads` remains first on Unix.
- [ ] Portability: POSIX specifics (the `/bin/bash` default, `;`/`&&` operators,
      `/` and `~` paths) are confined to the POSIX shell profile and POSIX syntax
      mode, not assumed by the policy, the tool, or shared units, so a future
      Windows profile is additive.
- [ ] Security: the policy fails closed (ask/deny, never allow) on ambiguity; the
      API key and other secrets are never included in command env dumps or logs.
- [ ] Security: command text is passed to the shell as data through the existing
      runner; the tool introduces no new injection surface beyond the shell the
      operator already chose to expose.
- [ ] Testability: the parser and policy are pure and tested exhaustively offline;
      execution is tested with harmless commands only.
- [ ] Performance: parsing and policy decision are negligible relative to process
      startup.
- [ ] `make check` passes.

## Success Metrics

### Quantitative

- Policy decisions are covered by table-driven tests across allow/ask/deny,
  compound commands, quoting, redirection, interpreters, and path escapes, for
  the POSIX syntax mode (the only mode in v1).
- A full tool round trip (model calls `run_command`, command runs, output is fed
  back) is exercised against a fake provider, offline, in a test.
- No network access is required by any test in this feature.
- No leaks reported by `make test-leak`.

### Qualitative

- An operator can explain, from the audit log, exactly what ran and what was
  denied.
- The allowlist is a small, readable list of command names, not a scripting
  language.
- The docs make the guardrail-vs-sandbox boundary impossible to miss.

## Constraints

### Technical

- Must build with Free Pascal 3.3.1, `{$mode delphi}`, and keep `make check`
  green.
- Must reuse `hildi.process` for execution; no second process runner.
- Must reuse `hildi.store` settings for persistence; no new database.
- Must not change the `TToolHandler` signature if avoidable; the shell tool holds
  its policy and approver as instance state.
- Must remain single-threaded at the loop level; the runner's thread is joined by
  the synchronous tool adapter before the handler returns.
- Must isolate POSIX specifics behind a shell/profile abstraction and a syntax
  mode, so shared units are platform-neutral and a future Windows profile is
  additive. v1 ships the POSIX profile only.
- Must not build on an unstated cross-platform claim: the runner's hard-coded
  `/bin/bash`, the Unix-only process-group/select code, the CLI's libc
  `isatty`/env calls, and the Unix-only vendored SQLite build remain Windows
  blockers; v1 records them as prerequisite foundation work rather than
  pretending they are solved.

### Business / Time

- This is the feature that turns the helper from a chat toy into something that
  can do work; it gates every future system-action tool.

## Dependencies

### Internal

- `hildi.process` - execution, streaming, timeout, cancellation.
- `hildi.agent` - `TToolRegistry`, `TToolHandler`, `TToolSpec`, plus
  the shared change to require a `reason` on every tool call
  (`Tool_Reason_v1.SPEC.md`).
- `hildi.store` - `GetSetting`/`SetSetting` for policy and audit.
- `hildi.llm` - `TToolSpec` shape for the advertised schema.
- `hildi.transcript` - gains the tool-call reason for display.
- The CLI (`examples/agent_cli.pas`) - wires the tool, the approver, and the
  store.

### External

- A POSIX shell (`/bin/bash`) via `TProcess`. The runner currently hard-codes it;
  v1 keeps that default but routes it through the shell profile.
- FPC `fpjson`/`jsonparser` for the parameter schema and policy serialization.
- (Future, not v1) `cmd.exe` on Windows and a Windows SQLite build; the vendored
  build and `make libsqlite` are Unix-only today, so the store-backed policy will
  need a Windows build path or an in-memory fallback when Windows is targeted.

## Risks

- **The policy is mistaken for a sandbox.** A static parser cannot see through
  variable expansion, command substitution, `eval`, globs, nested interpreters,
  or symlinks; an allowlisted interpreter is effectively an allowlist for
  everything it can run. Mitigation: name the ceiling in the unit header and the
  SPEC, never describe it as isolation, default-deny interpreters, and keep the
  real-sandbox feature separate and signposted.
- **"Which directories are affected" cannot be answered reliably.** Best-effort
  literal-path and `cd` analysis misses expanded and indirect paths. Mitigation:
  report unresolvable paths instead of assuming safe; treat the allowed-roots
  check as a hint, not a guarantee.
- **Approval fatigue.** Prompting on every novel command makes the tool unusable
  and users click "always allow" reflexively. Mitigation: three approval scopes
  (once, exact command, any arguments), per-segment prompts, and a small curated
  default allowlist for read-only commands.
- **The pattern language is a small DSL with sharp edges.** A single-word
  `executable` pattern means "any arguments"; an exact command uses a leading
  `=` (`=uname`, `=cat /etc/os-release`). Mitigation: the grammar is small,
  documented, and table-tested; an unexpected pattern simply fails to match and
  the command asks.
- **Command output floods the context window.** Mitigation: a hard output cap
  with a truncation marker, and side-channel display of the rest in the
  transcript.
- **Policy and audit writes race the single-threaded loop.** Mitigation: policy
  accesses are synchronous and serialized by the loop; the store is opened once.
- **Runner callback fires on another thread while the tool is synchronous.**
  Mitigation: the adapter collects output under a lock and joins the runner.
- **POSIX assumptions leak into the policy or shared units, making Windows a
  rewrite instead of an addition.** Mitigation: even in a Unix-only v1, route the
  shell, parser syntax, and path checks through a profile/syntax-mode seam, and
  keep POSIX literals out of the policy and tool.
- **Windows looks closer than it is (deferred).** When Windows is targeted,
  `cmd.exe` is a second shell with different operators, escaping (`^`), variables
  (`%VAR%`), and builtins, and the foundation (runner, process-group/select code,
  CLI libc calls, Unix-only SQLite build) is also a blocker. Mitigation: treat it
  as a distinct follow-on with its own parser mode, test tables, and foundation
  work; v1 must not claim Windows support.

## Future Considerations

- **Prefer typed tools over shell for common actions** (read/write/list/search):
  they sidestep parsing ambiguity and can enforce paths directly. The shell tool
  remains the escape hatch.
- A real OS-level sandbox tier using OS primitives (macOS
  `sandbox-exec`/seatbelt, Linux `bwrap`/namespaces, Windows Job
  Objects/AppContainer, or containers/seccomp), with the policy deciding
  *whether* to enter it. This is a separate, larger feature and the honest
  complement to the guardrail defined here.
- Closing the Windows foundation gap: a platform shell profile in the runner,
  cross-platform process/group and output-reading paths, cross-platform CLI
  terminal/env handling, and a Windows SQLite build.
- Remote approval through the Hildegard service (the Remote Agent Link feature
  will define its own approval transport).
- Policy rule syntax richer than exact/glob on executable names (for example
  argument constraints, per-rule allowed roots).
- Per-tool policy so the same allow/ask/deny engine gates non-shell tools
  (system actions, remote actions).
- Per-command resource limits (CPU, memory, disk quotas) beyond timeout.
- Learning: propose allowlist additions from approvals, for the operator to
  confirm.
- Streaming command output to the transcript while the command runs.

## Notes

- **ICE score: Impact 10, Confidence 6, Ease 6.** Impact is maximal: without a
  shell tool the agent cannot act. Confidence is moderate: the gate's honest
  ceiling must be communicated and the approval UX must not become fatigue. Ease
  is moderate: the parser is bounded and pure, execution and storage already
  exist, and v1 is Unix-only; the care is in the policy's edge cases and tests.
  Windows would lower both confidence and ease and is deferred.
- **Sequencing:** independent of Remote Agent Link, but it is the natural first
  consumer of that link's approval/audit model. It should land before the link so
  the remote path has a vetted command tool to expose. Unix (POSIX) ships first
  behind the shell/syntax seam; Windows is a later follow-on once its foundation
  gaps close.
- **Reuse note (Ponytail):** execution (`process`), persistence (`store` settings),
  JSON (`fpjson`), and the tool contract (`agent`) all exist. Only the parser,
  policy, approval seam, and tool adapter are new. Building a shell parser into a
  security boundary, or a new persistence layer, would climb past the available
  rung.
- **Safety-spec note:** the FEATURE deliberately states the guardrail's limits as
  acceptance criteria (unparseable -> ask, unresolved paths reported, interpreters
  flagged), because a security control that overstates itself is worse than none.
- **Scope note:** this document intentionally has no "Out of Scope" section at the
  operator's request; the deferred items that would normally live there (real OS
  sandbox, remote approval, per-command resource limits) are recorded under
  "Future Considerations" instead, and the guardrail's limits are stated as risks
  and acceptance criteria.
