program headless_agent;
{ The headless agent: hosts one session's runtime. A client (the TUI or the CLI)
  spawns it detached and attaches over the session's Unix socket. It has no
  terminal and no widgets.

  argv: --session-runtime <id> --workspace <path> --store <path>
        [--model M] [--endpoint URL] [--idle-ms N]

  Config also comes from the environment/.env. Run it via a client; a direct
  run needs a session id and store. }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}   // cthreads first; cwstring for Unicode
  SysUtils,
  HildiSessionRuntime;

{ Process-wide allocator tuning from src/hildi_tls_shim.c (linked into this
  program). Capping glibc's per-thread arenas is worth ~10 MB of RSS on a
  session runtime: see docs/research/memory-footprint.md. It must run before the
  first thread is created and before any C allocation, so it is the first
  statement of the program body -- no unit initialization above it spawns a
  thread or calls into SQLite/mbedTLS. Declared here rather than in a unit so
  the TUI client stays free of the agent units. }
function hildi_alloc_init: Integer; cdecl; external;

var
  Args: array of string;
  I: Integer;
begin
  { Before any thread or C allocation: see the declaration above. }
  hildi_alloc_init;
  SetLength(Args, ParamCount);
  for I := 0 to ParamCount - 1 do
    Args[I] := ParamStr(I + 1);
  Halt(RunSessionRuntime(Args));
end.
