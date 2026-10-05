# Tool Streaming

## Overview

A tool call today is a black box. The loop calls the handler, the handler runs to
completion, and one result string comes back. For a long-running tool — a shell
command that compiles, installs, or tails a log — the operator sees nothing until
it finishes, and a timeout kills it with only whatever it produced before the
kill. There is no way to watch progress, and no way to react to output while it
is still arriving.

This feature makes every tool's output a **stream**, RxJS-shaped. A tool is given
an **observer** and may flush chunks as it produces them (`next`), then complete
with its result. A tool that produces everything at once simply never calls
`next` and completes in a single shot. The same seam covers both, so nothing
special-cases `run_command`; it is merely the first tool that streams.

The stream is the **result being produced**, not a side channel: the chunks
accumulate to the authoritative result the model sees, so the live view and a
resumed view render the same thing.

## Problem Statement

- A long-running `run_command` blocks the turn with no visible progress.
- The output is collected and truncated to one string; intermediate bytes are
  discarded even though the process runner already produces them.
- There is no seam for a tool to report progress, so a future tool (a download,
  a search, a code generator) cannot either.
- The operator cannot tell a hung command from a slow one.

## Goals

- One output seam for every tool: an observer with `next` (a chunk) and
  `complete`.
- Streaming reaches the operator live: tool block → agent event → turn event →
  session protocol → driver → TUI.
- The stream is the result: chunks accumulate to the model's result, and the
  persisted result is authoritative, so live and resume match.
- `run_command` streams its stdout/stderr as it arrives; the other tools are
  single-shot with no code change beyond the seam.
- A model-defined command timeout: the model picks what fits the command; an
  operator may still impose a cap.

## Non-Goals

- Cancelling an in-flight tool from the UI (the loop checks cancel between
  requests). A follow-on.
- Binary or partial-UTF-8 output handling; chunks are text.
- Backpressure: the observer is a fire-and-forget sink, like the process runner's
  output callback.

## User Stories

- As an **operator**, I want to watch a long command's output as it arrives, so I
  can tell progress from a hang.
- As an **operator**, I want the model to choose a timeout that fits the command,
  rather than being killed at a fixed default, while I can still cap it.
- As a **harness author**, I want one output seam every tool shares, so a new
  streaming tool needs no special plumbing.
- As a **harness author**, I want the live and resumed views to match, so the
  stream is the result rather than a parallel display channel.

## Acceptance Criteria

### Functional

- [ ] `TToolObserver` is the output seam: `Next` flushes a chunk, `Complete`
      ends the stream.
- [ ] `TToolHandler` receives an observer; every registered tool takes it (the
      non-streaming ones ignore it).
- [ ] `run_command` forwards the process runner's stdout/stderr chunks to the
      observer as they arrive.
- [ ] The agent emits `OnToolOutput` per chunk; the turn worker republishes it as
      `teToolOutput`; the session protocol carries it as `tool_output`; the
      remote driver maps it back.
- [ ] The TUI appends streamed chunks to the live tool block and replaces its
      body with the authoritative result when the call completes.
- [ ] The model defines the command timeout, with an optional operator cap.

### Non-Functional

- [ ] The observer is thread-safe (chunks arrive on the runner thread).
- [ ] A chunk that no client consumes costs nothing (no queue growth).
- [ ] Leak-clean; `make check` passes.

## Dependencies

- The agent loop's tool execution and the event seam (Agent Loop).
- The session protocol and runtime (Headless Sessions).
- The command tool and the process runner.

## Risks

- **Live/resume parity.** The persisted result is the whole output; the live
  block streams chunks. Resolved by replacing the body with the authoritative
  result on completion.
- **Unbounded growth.** A chatty command could grow the live block without
  bound; the result cap must bound the live body too.
