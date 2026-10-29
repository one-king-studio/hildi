program smoke;
{ The live smoke: drive the REAL headless runtime through a scripted turn against
  a loopback fake provider, end to end.

    make smoke                  run every scenario
    make smoke SCENARIO=tool    run one
    make smoke-list             list them

  Hermetic: loopback only, an ephemeral port, a temp workspace and store, no
  network, no credentials. See docs/features/Live_Smoke/. }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}   // cthreads first; cwstring for Unicode
  SysUtils,
  hildi.session.client,
  smoke_runner;

var
  Names: TStringArray;
  Wanted, Bin: string;
  I, J, Failed, Ran: Integer;
  Out2: TSmokeOutcome;

procedure Usage;
var
  N: TStringArray;
  J: Integer;
begin
  WriteLn('usage: smoke [--scenario <name>] [--list] [--runtime <path>]');
  WriteLn;
  WriteLn('scenarios:');
  N := ScenarioNames;
  for J := 0 to High(N) do
    WriteLn('  ', N[J]);
end;

function FindArg(const AFlag: string): string;
var
  J: Integer;
begin
  Result := '';
  for J := 1 to ParamCount - 1 do
    if ParamStr(J) = AFlag then
      Exit(ParamStr(J + 1));
end;

begin
  {$ifdef unix}
  Bin := '';
  {$endif}
  Names := ScenarioNames;

  if FindArg('--help') <> '' then
  begin
    Usage;
    Halt(0);
  end;

  { --list is a flag, not a key/value pair. }
  for I := 1 to ParamCount do
    if ParamStr(I) = '--list' then
    begin
      for J := 0 to High(Names) do
        WriteLn(Names[J]);
      Halt(0);
    end;

  Wanted := FindArg('--scenario');
  Bin := FindArg('--runtime');
  if Bin = '' then
    Bin := GetEnvironmentVariable('HILDI_RUNTIME_BIN');
  if Bin = '' then
    Bin := ResolveRuntimeBinary('', ParamStr(0));
  if Bin = '' then
  begin
    WriteLn(StdErr, 'smoke: no runtime binary; build it (make headless-agent) or '
      + 'set HILDI_RUNTIME_BIN');
    Halt(2);
  end;

  Ran := 0;
  Failed := 0;
  for I := 0 to High(Names) do
  begin
    if (Wanted <> '') and (Names[I] <> Wanted) then
      Continue;
    Write(Format('%-12s ', [Names[I]]));
    Flush(Output);
    Out2 := RunScenario(Names[I]);
    Inc(Ran);
    if Out2.Ok then
      WriteLn('ok')
    else
    begin
      Inc(Failed);
      WriteLn('FAIL');
      WriteLn('  stage:  ', Out2.Stage);
      WriteLn('  detail: ', Out2.Detail);
    end;
  end;

  if Ran = 0 then
  begin
    WriteLn(StdErr, 'smoke: no scenario matched "' + Wanted + '"');
    Halt(2);
  end;

  WriteLn;
  if Failed = 0 then
    WriteLn(Format('%d scenario(s) passed', [Ran]))
  else
    WriteLn(Format('%d of %d scenario(s) FAILED', [Failed, Ran]));
  Halt(Ord(Failed <> 0));
end.
