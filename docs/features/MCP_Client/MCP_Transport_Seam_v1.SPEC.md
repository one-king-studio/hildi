# Component Specification: MCP Transport Seam v1

**Related Feature:** [MCP_HTTP_v2_FEATURE.md](MCP_HTTP_v2_FEATURE.md)

**Depends on:** `hildi.mcp.client`, `hildi.stdio.child`.
**Depended on by:** `Mcp_HTTP_Transport_v1.SPEC.md`.

## Purpose

Extract the transport seam so `TMcpClient` no longer depends on `TStdioChild`.
The client keeps its JSON-RPC codec, correlation, tool mapping, and dispatch;
only the byte transport changes. The stdio child becomes one implementation.

This makes the FEATURE's "one transport interface" claim true, and is the
prerequisite for HTTP.

## Requirements

### Functional

- [ ] An `IMcpTransport` interface: `Open`, `Send`, `Receive`, `Close`, `Dead`.
- [ ] `TStdioTransport` implements it by wrapping `TStdioChild` (no behaviour
      change).
- [ ] `TMcpClient` holds an `IMcpTransport` and uses only its methods; the
      `TStdioChild` type does not appear in the client.
- [ ] `TMcpClientConfig` names the transport kind; the client constructs the
      matching transport (or the manager injects it — SPEC pins construction).
- [ ] All existing MCP tests pass unchanged (stdio behaviour is identical).

### Non-Functional

- [ ] No dependency change; `make check` green.

## Contracts & Interfaces

```pascal
unit hildi.mcp.transport;
{ The byte-transport seam for the MCP client: framed JSON-RPC lines in and out.
  Implementations: stdio (a child's pipes), HTTP (a remote endpoint). }

{$mode delphi}{$H+}

interface

uses
  SysUtils, hildi.stdio.child;

type
  { Why a Receive returned False (mirrors TStdioReadResult). }
  TMcpRecvResult = (mrOk, mrTimeout, mrEof, mrTooLong, mrError);

  { A bidirectional, line-framed JSON-RPC transport. One implementation per
    connection. Not thread-safe; driven on the loop's thread. }
  IMcpTransport = interface
    { Establish the connection. False + AError on failure. Idempotent. }
    function Open(out AError: string): Boolean;
    { Send one framed line (no trailing newline). False + AError on a broken
      transport. }
    function Send(const ALine: string; out AError: string): Boolean;
    { Receive one line within ATimeoutMs. True (mrOk) or False + AReason. }
    function Receive(out ALine: string; ATimeoutMs: Integer;
      out AReason: TMcpRecvResult): Boolean;
    { Tear down. Idempotent. }
    procedure Close;
    { True once a failure marked the transport unusable (drives reconnect). }
    function Dead: Boolean;
  end;

  { The stdio child as a transport. }
  TStdioTransport = class(TInterfacedObject, IMcpTransport)
  public
    constructor Create(const AConfig: TStdioChildConfig);
    destructor Destroy; override;
    function Open(out AError: string): Boolean;
    function Send(const ALine: string; out AError: string): Boolean;
    function Receive(out ALine: string; ATimeoutMs: Integer;
      out AReason: TMcpRecvResult): Boolean;
    procedure Close;
    function Dead: Boolean;
  end;

implementation
end.
```

### Data Contracts

- **Framing.** `Send`/`Receive` move one JSON-RPC line (LF framing is the
  transport's business). `TStdioTransport` maps `TStdioChild`'s
  `WriteLine`/`ReadLine` and its `TStdioReadResult` onto `TMcpRecvResult`.
- **`Dead`.** Set by a failed send/receive; the client's `FDead` becomes a
  mirror of the transport's, so the manager's reconnect logic is unchanged.

### Event Contracts

- None.

## Architecture

### Prior Art & Reuse

- **`TStdioChild`** is the whole stdio implementation; the wrapper is thin.
- **`TMcpClient`** already isolates its transport calls in `WaitResponse`/`Call`/
  `Open`/`Close`; the swap is mechanical.
- **Genuine gap:** the interface and the wrapper.

### Component Boundaries

- **Responsibilities:** the seam; the stdio wrapper.
- **Dependencies:** `stdio.child`.

## Validation Rules

- `Open` is idempotent; `Send`/`Receive` before `Open` fail cleanly.

## Error Handling

- A transport error sets `Dead`; the client surfaces it as today.

## Testing Requirements

### Unit Tests

- [ ] `TStdioTransport` round-trips a line against a `/bin/sh` echo (mirrors the
      child test).
- [ ] The existing `TMcpClientTest` suite passes with the client on the seam
      (no test changes = the seam is faithful).

## Success Criteria

- [ ] The client compiles and runs with no `TStdioChild` reference; `make check`
      green.

## Future Considerations

- The HTTP transport (next SPEC) implements the same interface.
