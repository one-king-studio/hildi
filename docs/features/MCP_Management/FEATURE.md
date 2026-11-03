# MCP Management Dialog

## Overview

A `/mcp` command that opens a dialog listing every installed MCP server with two
distinct status columns, and lets the operator reconnect a dropped server or add
a new one — without leaving the TUI and without hand-editing a JSON config.

## Problem Statement

MCP servers are the harness's main capability extension, and today they are
invisible and unmanageable from the TUI:

- **No list.** The only surface is the tail `<mcp_servers>` block in the harness
  context; the operator sees `state="closed"` and nothing else.
- **No reconnect.** A server that dies (`mssDead`) stays dead until the runtime
  restarts. There is no way to refresh an expired OAuth token from the UI.
- **No add.** Adding a server means writing `mcp_servers` rows by hand or
  running `hildi-agent-cli mcp add` in another terminal.
- **No "when to use".** A server definition carries a name and connection
  parameters but **nothing that tells the model or the operator what the server is
  for**. `@browsermcp/mcp` is discoverable only by reading its args.

Ponytail, rung 1: does this need building? The store and config layers already
exist (`ListMcpServers`, `SaveMcpServer`, `ValidateMcpServerRow`); what is missing
is a UI surface and two fields. Rung 2: the dialog infrastructure already exists
(`TModal`), and the skills lane already established the "ask the runtime for
detail" wire pattern. So this is a thin layer over existing parts, not a new
subsystem.

## Goals

- Show every installed server with **connection** and **activation** status,
  which are different questions and must not be conflated.
- Probe connection state **only when the dialog opens**, never on a timer.
- Let the operator **reconnect** a disconnected server (refresh transport/auth)
  without changing whether it is active for the session.
- Let the operator **add** a server: unique key, optional label, optional
  description of when to use it, and connection parameters.

## User Stories

- As an operator, I want to open one dialog and see which MCP servers are up so
  that I can tell a broken integration from an inactive one.
- As an operator, I want to reconnect an expired server so that I don't have to
  restart the runtime to recover it.
- As an operator, I want to add a server from the TUI so that setup does not
  require a second terminal or hand-edited rows.
- As a model, I want each server to carry a short description of when to use it
  so that tool selection is informed rather than guessed from the name.

## Acceptance Criteria

### Functional Requirements

- [ ] `/mcp` opens a dialog listing every installed server, workspace-scoped
      first, then global.
- [ ] Each row shows: key, label (or key if absent), description (truncated),
      connection status, activation status.
- [ ] Connection status is `connected` / `disconnected` / `failed`, and is
      **probed when the dialog opens only** — opening twice re-probes; leaving it
      open does not poll.
- [ ] Activation status is whether the server is **active for this session**,
      which is independent of whether its transport is up.
- [ ] `r` (or the row's CTA) reconnects a **disconnected or failed** server:
      re-open the transport and re-auth if the token expired. It does **not**
      change activation.
- [ ] `a` opens an add form: key (required, unique, validated), label
      (optional), description (optional), transport (stdio/http), command+args or
      URL+headers, env, cwd, timeouts.
- [ ] Saving a server persists it and it appears in the list without a restart.
- [ ] A probe failure or a dead server never blocks the UI: the dialog renders
      with whatever it has and shows the error per row.

### Non-Functional Requirements

- [ ] The probe runs off the UI thread; the dialog opens immediately and rows
      fill in as answers arrive.
- [ ] No new polling loop. Probing is an explicit action, not a tick.
- [ ] The list itself stays cheap over the wire: status and metadata only, never
      tool schemas or bodies.

## Out of Scope

- Editing an existing server's connection parameters (delete + re-add for now).
- Deleting a server (the CLI already does it; a destructive action in a dialog
  needs its own confirm flow).
- OAuth token management beyond "reconnect triggers the existing refresh path".
- Per-tool enable/disable.
