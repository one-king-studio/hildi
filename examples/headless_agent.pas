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

var
  Args: array of string;
  I: Integer;
begin
  SetLength(Args, ParamCount);
  for I := 0 to ParamCount - 1 do
    Args[I] := ParamStr(I + 1);
  Halt(RunSessionRuntime(Args));
end.
