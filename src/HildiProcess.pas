unit HildiProcess;
{ A background "subagent" primitive: runs one host shell command on its own
  thread, streams stdout/stderr as it arrives, enforces a timeout, and can be
  cancelled. Output is delivered through a callback, so the same runner can
  feed a console reporter, a queue, or a UI. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Process;

type
  TOutputKind = (okStarted, okStdout, okStderr, okFinished);

  { NOTE: the callback is invoked from the runner thread. If several runners
    share one callback (e.g. a logger), that callback must be thread-safe. }
  TOutputEvent = procedure(const AId: string; AKind: TOutputKind;
    const AText: string; AExitCode: Integer) of object;

  TCommandRunner = class(TThread)
  private
    FId: string;
    FCommand: string;
    FWorkDir: string;
    FTimeoutMs: QWord;
    FShellExecutable: string;
    FShellSwitch: string;
    FOnOutput: TOutputEvent;
    FExitCode: Integer;
    FTimedOut: Boolean;
    FProcess: TProcess;
    function WaitReadable(ATimeoutMs: Integer): Boolean;
    procedure Emit(AKind: TOutputKind; const AText: string;
      AExitCode: Integer = 0);
  protected
    procedure Execute; override;
  public
    { Created suspended; call Start to launch. ATimeoutMs = 0 means no limit.
      The shell and its command switch default to POSIX bash; callers may pass
      another profile (e.g. a future cmd.exe) without changing this unit. }
    constructor Create(const AId, ACommand: string; ATimeoutMs: QWord = 0;
      const AWorkDir: string = ''; AOnOutput: TOutputEvent = nil;
      const AShellExecutable: string = '/bin/bash';
      const AShellSwitch: string = '-c');
    procedure Cancel;
    property Id: string read FId;
    property ExitCode: Integer read FExitCode;
    property TimedOut: Boolean read FTimedOut;
  end;

  { Normalizes a raw TProcess.ExitStatus into the project convention: a 0..255
    exit code, or 128+signal. TProcess.ExitStatus varies across FPC
    builds/platforms (raw wait() status, an already-decoded code, or a negative
    signal); this maps all three. Exported so the stdio child manager reuses one
    mapping rather than copying it. }
function NormalizeExit(Status: Integer): Integer;

implementation

{$ifdef unix}
uses
  BaseUnix;   // for fpSelect / TFDSet in WaitReadable
{$endif}

{ TProcess.ExitStatus is not consistent across FPC builds/platforms: on Unix it
  may be the raw wait() status (exit code shifted into the high byte, signal in
  the low bits) or an already-decoded code (negative for signal deaths). Map all
  of those to one friendly convention: 0..255 exit code, or 128+signal. }
function NormalizeExit(Status: Integer): Integer;
begin
  if Status < 0 then
    Result := 128 - Status                        // negative signal convention
  else if Status > 255 then
  begin
    if (Status and $7F) = 0 then
      Result := (Status shr 8) and $FF            // raw wait(): normal exit
    else
      Result := 128 + (Status and $7F);           // raw wait(): signalled
  end
  else
    Result := Status;                             // already an exit code
end;

constructor TCommandRunner.Create(const AId, ACommand: string;
  ATimeoutMs: QWord; const AWorkDir: string; AOnOutput: TOutputEvent;
  const AShellExecutable, AShellSwitch: string);
begin
  inherited Create(True);
  FId := AId;
  FCommand := ACommand;
  FTimeoutMs := ATimeoutMs;
  FWorkDir := AWorkDir;
  FShellExecutable := AShellExecutable;
  FShellSwitch := AShellSwitch;
  FOnOutput := AOnOutput;
  FreeOnTerminate := False;
end;

procedure TCommandRunner.Cancel;
begin
  Terminate;
end;

procedure TCommandRunner.Emit(AKind: TOutputKind; const AText: string;
  AExitCode: Integer);
begin
  if Assigned(FOnOutput) then
    FOnOutput(FId, AKind, AText, AExitCode);
end;

{$ifdef unix}
function TCommandRunner.WaitReadable(ATimeoutMs: Integer): Boolean;
var
  Fds: TFDSet;
  Tv: TTimeVal;
begin
  fpFD_ZERO(Fds);
  fpFD_SET(cint(FProcess.Output.Handle), Fds);
  Tv.tv_sec := ATimeoutMs div 1000;
  Tv.tv_usec := (ATimeoutMs mod 1000) * 1000;
  Result := fpSelect(cint(FProcess.Output.Handle) + 1, @Fds, nil, nil, @Tv) > 0;
end;
{$else}
function TCommandRunner.WaitReadable(ATimeoutMs: Integer): Boolean;
begin
  Sleep(ATimeoutMs);
  Result := FProcess.Output.NumBytesAvailable > 0;
end;
{$endif}

procedure TCommandRunner.Execute;
var
  Buf: array[0..8191] of Byte;
  N: LongInt;
  Started: QWord;
  Launched: Boolean;
  Data: string;

  procedure Drain;
  begin
    while WaitReadable(0) do
    begin
      N := FProcess.Output.Read(Buf, SizeOf(Buf));
      if N <= 0 then
        Break;
      SetString(Data, PAnsiChar(@Buf[0]), N);
      Emit(okStdout, Data);
    end;
  end;

begin
  Launched := False;
  FProcess := TProcess.Create(nil);
  try
    FProcess.Executable := FShellExecutable;
    FProcess.Parameters.Add(FShellSwitch);
    FProcess.Parameters.Add(FCommand);
    if FWorkDir <> '' then
      FProcess.CurrentDirectory := FWorkDir;
    FProcess.Options := [poUsePipes, poStderrToOutput];
    {$ifdef unix}
    FProcess.Options := FProcess.Options + [poNewProcessGroup];
    {$endif}
    try
      FProcess.Execute;
      Launched := True;
    except
      on E: Exception do
      begin
        FExitCode := 127;
        Emit(okStderr, 'failed to start: ' + E.Message + LineEnding);
      end;
    end;

    if Launched then
    begin
      Emit(okStarted, '');
      Started := GetTickCount64;
      while not Terminated do
      begin
        if WaitReadable(100) then
        begin
          N := FProcess.Output.Read(Buf, SizeOf(Buf));
          if N > 0 then
          begin
            SetString(Data, PAnsiChar(@Buf[0]), N);
            Emit(okStdout, Data);
          end
          else
            Break;
        end
        else if not FProcess.Running then
          Break;
        if (FTimeoutMs > 0) and (GetTickCount64 - Started >= FTimeoutMs) then
        begin
          FTimedOut := True;
          Emit(okStderr, '<<timeout after ' + IntToStr(FTimeoutMs) +
            ' ms; killing>>' + LineEnding);
          FProcess.Terminate(124);
          Break;
        end;
      end;
      if Terminated and FProcess.Running then
        FProcess.Terminate(130);
      Drain;
      FProcess.WaitOnExit;
      FExitCode := NormalizeExit(FProcess.ExitStatus);
      if FTimedOut then
        FExitCode := 124        // conventional "timed out" sentinel
      else if Terminated then
        FExitCode := 130;       // conventional "cancelled" sentinel
    end;
  finally
    FProcess.Free;
  end;
  Emit(okFinished, '', FExitCode);
end;

end.
