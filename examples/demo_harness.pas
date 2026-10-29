program demo_harness;
{ Demo: schedule several shell "subagents" and let the pool run up to three of
  them at a time. Output is reassembled into whole lines and printed with an
  agent tag, so interleaved streams from concurrent subagents stay readable.

  Build:  fpc -Fusrc -odemo_harness demo/demo_harness.pas
  Run:    ./demo_harness }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}   // must come first on Unix
  SysUtils, Classes, SyncObjs, Generics.Collections,
  hildi.process, hildi.pool;

type
  { Thread-safe console reporter. TAgentPool calls OnOutput from worker threads,
    so all shared state (the per-agent partial-line buffers, and stdout itself)
    is guarded by one lock. }
  TReporter = class
  private
    FLock: TCriticalSection;
    FPartial: TDictionary<string, string>;
    procedure WriteLine(const S: string);
    procedure FlushPartial(const AId: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnOutput(const AId: string; AKind: TOutputKind;
      const AText: string; AExitCode: Integer);
  end;

constructor TReporter.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FPartial := TDictionary<string, string>.Create;
end;

destructor TReporter.Destroy;
begin
  FPartial.Free;
  FLock.Free;
  inherited Destroy;
end;

{ Caller must hold FLock. }
procedure TReporter.WriteLine(const S: string);
begin
  Write(S);
  Flush(Output);
end;

procedure TReporter.FlushPartial(const AId: string);
var
  Rest: string;
begin
  FLock.Acquire;
  try
      if FPartial.TryGetValue(AId, Rest) and (Rest <> '') then
    begin
      WriteLine('  [' + AId + '] ' + Rest + LineEnding);
      FPartial.AddOrSetValue(AId, '');
    end;
  finally
    FLock.Release;
  end;
end;

procedure TReporter.OnOutput(const AId: string; AKind: TOutputKind;
  const AText: string; AExitCode: Integer);
var
  Data, Partial, Line: string;
  Start, P: Integer;
begin
  case AKind of
    okStarted:
      begin
        FLock.Acquire;
        try
          WriteLine(Format('[%-6s] === started ===%s', [AId, LineEnding]));
        finally
          FLock.Release;
        end;
      end;

    okStdout, okStderr:
      begin
        FLock.Acquire;
        try
          if not FPartial.TryGetValue(AId, Partial) then
            Partial := '';
          Data := Partial + AText;
          Start := 1;
          for P := 1 to Length(Data) do
            if Data[P] = #10 then
            begin
              Line := Copy(Data, Start, P - Start);
              if (Line <> '') and (Line[Length(Line)] = #13) then
                Delete(Line, Length(Line), 1);
              WriteLine('  [' + AId + '] ' + Line + LineEnding);
              Start := P + 1;
            end;
          FPartial.AddOrSetValue(AId, Copy(Data, Start, MaxInt));
        finally
          FLock.Release;
        end;
      end;

    okFinished:
      begin
        FlushPartial(AId);
        FLock.Acquire;
        try
          WriteLine(Format('[%-6s] === finished (exit=%d) ===%s',
            [AId, AExitCode, LineEnding]));
        finally
          FLock.Release;
        end;
      end;
  end;
end;

var
  Reporter: TReporter;
  Pool: TAgentPool;
begin
  Reporter := TReporter.Create;
  Pool := TAgentPool.Create(3, Reporter.OnOutput);
  try
    Pool.Submit('alpha', 'for i in 1 2 3; do echo "step $i"; sleep 0.3; done');
    Pool.Submit('beta',  'for i in 1 2 3 4; do echo "tick $i"; sleep 0.15; done');
    Pool.Submit('gamma', 'echo "compiling..."; sleep 0.2; echo "boom" >&2; exit 2');
    Pool.Submit('delta', 'echo "sleeping forever"; sleep 30', 800);

    Pool.WaitAll;
    WriteLn('all subagents finished');
  finally
    Pool.Free;
    Reporter.Free;
  end;
end.
