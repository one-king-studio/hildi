# Provider Configuration

## Overview

Everything that determines *which* provider hildi talks to, *how* the request is
shaped, and *what we record about it afterwards*. Today that is three environment
variables and a hard-coded endpoint, resolved in-process at startup and then
forgotten. This feature makes the provider a first-class, inspectable, selectable
thing: stored in the database, editable through a dialog, selectable per session,
and recorded on every turn so the operator can report on what actually ran.

## Problem Statement

An operator who wants to point hildi at a different provider, or tune how a model
is sampled, has one lever: edit `.env` and restart. There is no way to see what
the current setting is from inside the app, no way to hold two providers, and no
record afterwards of which model produced a given turn.

Three concrete costs:

1. **Configuring is invisible.** The resolution order is
   shell env → `.env` → `ResolveLLMConfig` defaults, spread across three units and
   applied in each process separately. Nothing in the UI states the endpoint or
   the model in effect, so "why is it hitting Fireworks" is answered by reading
   source.
2. **The request is not tunable at all.** `BuildRequestBody` emits exactly four
   keys plus `tools`: `model`, `stream`, `stream_options`, `messages`. There is no
   `temperature`, no `max_tokens`, no `top_p` — not because they were rejected,
   but because nothing ever added them. A provider that needs an explicit output
   cap, or a model that must run deterministically for a tool-heavy workload,
   cannot be expressed.
3. **The record is lossy.** `requests.model` exists, but `turns` has no model
   column, so a turn's summary attributes its token counts to no particular model
   or provider. Comparing two runs is guesswork.

## Who loads the environment (answered, because it is asked often)

**The harness loads it, not the TUI — and it loads it per process, from the
process's own working directory.**

| Process | Loads `.env`? | Where |
| --- | --- | --- |
| `hildi` (TUI) | **No, not explicitly.** It gets it as a side effect of opening a view. | `TSessionView.Init` → `LoadDotEnvFile('.env')` |
| `hildi-agent` (runtime) | **Yes**, via the same path: it builds a `THarnessSession`, which opens a `TSessionView`. | same line |
| `hildi-agent-cli` (CLI) | **Yes, twice by accident** — once in the example, then again inside the view. | `examples/agent_cli.pas` and `TSessionView.Init` |

The mechanism: `LoadDotEnvFile` (`src/HildiEnv.pas`) parses `NAME=VALUE` and
applies each pair **only if the variable is not already set**, so shell
environment wins over `.env`. It is called in exactly two places:
`src/HildiHarnessView.pas` (the harness) and `examples/agent_cli.pas` (the CLI).
The TUI example never calls it.

Why the TUI still "has" the variables: the runtime it spawns inherits the TUI's
environment (`SpawnDetached` runs the binary under `nohup sh -c`, which inherits
the parent's env and cwd), and the runtime then loads `.env` from **its own cwd**.
`examples/agent_cli.pas` does the same. So the effective configuration is a
function of where the process was started, and two processes started from
different directories can disagree about the provider while sharing a session.

**The property that matters:** only the **runtime** builds the LLM request, and
only the runtime's environment feeds it. The TUI holds a `TSessionView` and can
*display* a resolved model name, but it never constructs a `TLLMClient` and has
no channel to set the runtime's sampling parameters. Any configuration that the
operator must be able to change from the TUI therefore has to cross the spawn
boundary — either through the inherited environment or through the session
protocol.

## Goals

- Make every parameter of the provider request expressible without a code change.
- Never send a parameter the operator did not set: absent means *omitted*, so the
  provider's own default applies.
- Record what actually ran, per turn, so it can be reported and surfaced.
- Give the TUI somewhere to display and (later) edit the connection settings
  without making the TUI own the request.

## User Stories

- As an operator, I want to cap a model's output with `max_tokens` so that a
  runaway generation cannot burn a budget, without editing source.
- As an operator, I want to run a tool-heavy session deterministically
  (`temperature=0`) and a drafting session creatively, in the same install.
- As an operator, I want to see which provider and model a past turn used, so I
  can compare quality and cost across them.
- As an operator, I want to configure a second provider and switch to it from a
  dialog, rather than maintaining two `.env` files and two shells.
- As an operator, I want to pick a model from the provider's own list, so I do not
  have to discover valid model ids by trial and error.

## Acceptance Criteria

Later stages depend on earlier ones; each is independently useful.

### Stage 1 — Request parameters (this SPEC: `LLM_Request_Parameters_v1`)

- [ ] `temperature`, `top_p`, `max_tokens`, `stop`, `frequency_penalty`,
      `presence_penalty` and `seed` are settable from the environment.
- [ ] An unset parameter is **absent from the JSON body**, not zero.
- [ ] An invalid value is a configuration error naming the variable, reported
      before any network I/O, never a silently coerced value.
- [ ] The four keys sent today are byte-identical when no parameter is set.

### Stage 2 — Provider records in the database

- [ ] A provider (name, endpoint, API key reference, default parameters) is
      stored in the store and listed, not read from `.env`.
- [ ] The `.env` path keeps working as a fallback, because it is how every
      install is configured today.
- [ ] The API key is stored through the existing credentials mechanism, never in
      plaintext in a settings row.

### Stage 3 — A dialog to manage connections

- [ ] A `/provider` dialog can list, add, edit and select provider records.
- [ ] Selecting a provider and a model takes effect for the next turn, without a
      restart and without a new session.

### Stage 4 — Dynamic model discovery

- [ ] The configured provider's model list is fetched and offered as a choice,
      rather than typed from memory.

### Stage 5 — Recording what ran

- [ ] A turn records the provider, model and the sampling parameters in effect.
- [ ] The recorded information is available to the session header and to a
      report, alongside the token and duration statistics already stored.

### Non-Functional Requirements

- [ ] No new dependency for the request shape: `fpjson` already serialises it.
- [ ] The request body stays a pure function of its inputs, so the tests can
      assert on it offline through `TFakeTransport`.
- [ ] No API key is ever written to a log line, an error detail, or the store in
      plaintext.
- [ ] Portability: the parameter plumbing is platform-neutral (macOS + Linux).

## Success Metrics

### Quantitative

- Zero keys added to the request body when nothing is configured (asserted by
  test, so the default path cannot drift).
- Gate stays green, including the leak build.

### Qualitative

- An operator can answer "what is it talking to, and with what settings" from the
  UI, without reading `.env`.

## Constraints

- **Only the runtime builds the request.** The TUI cannot set sampling parameters
  directly; anything configurable from the UI must reach the runtime through the
  inherited environment or the session protocol.
- **`HildiProcess` must not depend on `HildiAgent`** (the Process Split), and
  `HildiLLM` is the only unit allowed to know the provider JSON shape.
- **Migrations are contended.** `HildiStore.pas` is shared with other lanes; the
  highest version on `main` is 21 and the MCP lane has claimed 22. Any provider
  table starts at **23**.
- **The API key is never a command-line flag.** It is read from the environment
  or `.env` today, deliberately (see `Harness_UI_v1.SPEC.md`).

## Dependencies

- `src/HildiLLM.pas` — `TLLMConfig`, `ResolveLLMConfig`, `BuildRequestBody`.
- `src/HildiEnv.pas` — `LoadDotEnvFile`, `GetEnvLegacy`.
- `src/HildiStore.pas` — the `settings` table (flat key/value) and the
  `credentials` mechanism.
- `src/HildiSessionProtocol.pas` — only if a stage must cross the spawn boundary
  with something the environment cannot carry.

## Sequencing

| Stage | What | Blocks on |
| --- | --- | --- |
| 1 | Request parameters from the environment | nothing — buildable now |
| 2 | Provider records in the store | a migration number (main is 21, MCP holds 22 → start at 23) |
| 3 | A dialog to manage connections | stage 2, and `TModal` row hit-testing (card #36) |
| 4 | Dynamic model discovery | stage 2; needs one new HTTP call (`GET /models`) |
| 5 | Record provider/model/params on the turn | stage 2 for the provider id; the model and params are already available at `BeginRequest` |

Stage 5's storage already exists in part: `requests.model` is recorded per
request, and `turns` carries the token and duration aggregates. What is missing
is the **provider identity** and the **parameters**, and a `turns` column to
report on them without joining `requests`.

## Out of Scope

- Per-message or per-tool sampling overrides.
- `tool_choice` and `parallel_tool_calls`. They change the loop's contract rather
  than sampling, and `parallel_tool_calls=false` would fight the parallel tool
  executor. Revisit as their own feature.
- Provider-specific wire formats. hildi speaks OpenAI-compatible chat completions
  and one normalised usage shape; adding a second protocol is not this feature.
- Automatic failover between providers.
- Cost accounting (pricing tables). Recording tokens and the model is in scope;
  turning that into money is not.

## Risks

| Risk | Mitigation |
| --- | --- |
| A sentinel `0` temperature silently changes behaviour for existing installs | Tri-state: absent means omit the key. A test asserts the body is unchanged when nothing is set. |
| Secrets leak through a provider row or a log | Key goes through the credential store; the request body test asserts the key is only ever in the `Authorization` header. |
| Storing config in the DB splits the source of truth with `.env` | Explicit precedence, documented and tested: store → env → default. |
| Migration version collision with another lane | Start at 23 and re-check `main` before landing. |

## Related

- `LLM_Request_Parameters_v1.SPEC.md` — Stage 1, the concrete first slice.
- `../Agent_Loop/LLM_Client_v1.SPEC.md`, `LLM_Client_v2.SPEC.md` — the client this
  extends.
- `docs/research/cli-agent-harness-parity.md` — the survey noting we have `.env`
  only, where other harnesses have declarative config files.
