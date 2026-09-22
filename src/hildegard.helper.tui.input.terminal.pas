unit hildegard.helper.tui.input.terminal;
{ Terminal input adapter: raw-mode byte reads, TIOCGWINSZ resize, and the pure
  escape-sequence decoder in hildegard.helper.tui.input.decode.

  This is the only place the toolkit touches the tty. It deliberately does not
  use FPC's keyboard unit: keyboard.InitKeyboard runs a kitty-key/DA1 probe that
  blocks in a blocking read (and can swallow the first keypress), and its decoder
  proved unreliable. Reading bytes ourselves over the RTL termio/baseunix units
  is deterministic, still dependency-free, and the mapping is unit-tested. }

{$mode delphi}{$H+}

interface

uses
  termio,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.input.decode;

type
  TInputSourceTerminal = class(TInterfacedObject, IInputSource)
  private
    FLastCol, FLastRow: Integer;
    FInputFd: Integer;
    FOpenedTty: Boolean;
    FOldTio: termios;
    FRawSet: Boolean;
    FDecoder: TKeyDecoder;
    FTrace: Boolean;
    FTracePath: string;
    procedure TraceLine(const S: string);
    procedure DrainInput;
    function ResizeEvent(out AEvent: TInputEvent): Boolean;
    procedure ReadAvailable;
  public
    constructor Create;
    destructor Destroy; override;
    function Poll(out AEvent: TInputEvent): Boolean;
    function Wait(ATimeoutMs: Integer; out AEvent: TInputEvent): Boolean;

    { Query the terminal background (OSC 11) and return its raw reply, draining
      the response so it never leaks to the shell. Empty if unsupported. Raw
      mode is already active on the input fd here, which is why this lives in
      the adapter rather than in the caller. }
    function QueryBackground: string;

    { True once SIGTERM/SIGINT/SIGHUP has been received; the caller should stop
      its loop so the terminal is restored on the normal exit path. }
    function Terminated: Boolean;
  end;

implementation

uses
  ctypes, SysUtils, baseunix;

function c_isatty(Fd: cint): cint; cdecl; external 'c' name 'isatty';
function c_tcflush(Fd, Queue: cint): cint; cdecl; external 'c' name 'tcflush';

var
  GTerminated: LongInt = 0;

procedure TermSignalHandler(Sig: cint); cdecl;
begin
  { Only sets a flag: the loop checks it and exits through the normal path so
    video/mouse/keyboard and termios are all restored. }
  GTerminated := 1;
end;

{ The fd to read keys from and to set raw mode on. Prefer stdin; some terminals
  (e.g. VSCode, Ghostty) launch the process with stdin not connected to the tty,
  so fall back to the controlling terminal. }
function OpenInputFd: Integer;
begin
  if c_isatty(0) = 1 then
    Exit(0);
  Result := fpOpen('/dev/tty', O_RDONLY);
end;

constructor TInputSourceTerminal.Create;
const
  { Enable button-event and SGR-extended mouse reporting so clicks, wheel and
    drag motion reach the app instead of the terminal scrollback. }
  MouseOn = #27'[?1000h'#27'[?1002h'#27'[?1006h';
var
  WS: TWinsize;
  Tio: termios;
begin
  inherited Create;
  FTracePath := GetEnvironmentVariable('HILDEGARD_TUI_TRACE');
  FTrace := FTracePath <> '';
  FRawSet := False;
  FOpenedTty := False;
  FInputFd := OpenInputFd;
  if FTrace then
    TraceLine(Format('open fd=%d opened=%s', [FInputFd, BoolToStr(FOpenedTty, True)]));
  if FInputFd < 0 then
    FInputFd := 0
  else
    FOpenedTty := FInputFd > 2;
  if TCGetAttr(FInputFd, FOldTio) = 0 then
  begin
    Tio := FOldTio;
    CFMakeRaw(Tio);
    if TCSetAttr(FInputFd, TCSANOW, Tio) = 0 then
      FRawSet := True;
  end;
  fpWrite(1, MouseOn[1], Length(MouseOn));
  fpsignal(SIGTERM, @TermSignalHandler);
  fpsignal(SIGINT, @TermSignalHandler);
  fpsignal(SIGHUP, @TermSignalHandler);
  FDecoder := TKeyDecoder.Create;
  FillChar(WS, SizeOf(WS), 0);
  if (fpioctl(FInputFd, TIOCGWINSZ, @WS) = 0) and (WS.ws_col > 0) and
    (WS.ws_row > 0) then
  begin
    FLastCol := WS.ws_col;
    FLastRow := WS.ws_row;
  end
  else
  begin
    FLastCol := 80;
    FLastRow := 25;
  end;
end;

destructor TInputSourceTerminal.Destroy;
const
  { Disable mouse reporting and, defensively, pop the kitty keyboard protocol
    (CSI < u) in case a previous program left it pushed. }
  MouseOff = #27'[?1006l'#27'[?1002l'#27'[?1000l'#27'[<u';
begin
  fpWrite(1, MouseOff[1], Length(MouseOff));
  { Discard pending input (late key-release events, a late OSC reply) so it is
    not handed to the shell once we restore the terminal. }
  DrainInput;
  FDecoder.Free;
  if FRawSet then
    TCSetAttr(FInputFd, TCSANOW, FOldTio);
  { Flush once more: bytes that arrived during teardown would otherwise be read
    by the shell after we exit. }
  c_tcflush(FInputFd, TCIFLUSH);
  if FOpenedTty then
    fpClose(FInputFd);
  fpsignal(SIGTERM, nil);
  fpsignal(SIGINT, nil);
  fpsignal(SIGHUP, nil);
  inherited Destroy;
end;

procedure TInputSourceTerminal.DrainInput;
var
  Bytes: array[0..255] of Byte;
  Fds: TFDSet;
  TV: TTimeVal;
  Attempt: Integer;
begin
  if FInputFd < 0 then
    Exit;
  for Attempt := 1 to 4 do
  begin
    fpFD_ZERO(Fds);
    fpFD_SET(FInputFd, Fds);
    TV.tv_sec := 0;
    TV.tv_usec := 0;
    if fpSelect(FInputFd + 1, @Fds, nil, nil, @TV) > 0 then
      fpRead(FInputFd, @Bytes[0], SizeOf(Bytes));
    Sleep(5);
  end;
  c_tcflush(FInputFd, TCIFLUSH);
end;

function TInputSourceTerminal.Terminated: Boolean;
begin
  Result := GTerminated <> 0;
end;

procedure TInputSourceTerminal.TraceLine(const S: string);
var
  F: TextFile;
begin
  if not FTrace then
    Exit;
  Assign(F, FTracePath);
  if FileExists(FTracePath) then
    Append(F)
  else
    Rewrite(F);
  WriteLn(F, S);
  Close(F);
end;

function TInputSourceTerminal.ResizeEvent(out AEvent: TInputEvent): Boolean;
var
  WS: TWinsize;
begin
  AEvent := Default(TInputEvent);
  Result := False;
  FillChar(WS, SizeOf(WS), 0);
  if fpioctl(FInputFd, TIOCGWINSZ, @WS) <> 0 then
    Exit;
  if (WS.ws_col <= 0) or (WS.ws_row <= 0) then
    Exit;
  if (WS.ws_col <> FLastCol) or (WS.ws_row <> FLastRow) then
  begin
    FLastCol := WS.ws_col;
    FLastRow := WS.ws_row;
    AEvent.Kind := ikResize;
    AEvent.NewSize.W := WS.ws_col;
    AEvent.NewSize.H := WS.ws_row;
    Result := True;
  end;
end;

procedure TInputSourceTerminal.ReadAvailable;
var
  Fds: TFDSet;
  TV: TTimeVal;
  Bytes: array[0..63] of Byte;
  Data: array of Byte;
  N, I: Integer;
  Hex: string;
begin
  fpFD_ZERO(Fds);
  fpFD_SET(FInputFd, Fds);
  TV.tv_sec := 0;
  TV.tv_usec := 0;
  if fpSelect(FInputFd + 1, @Fds, nil, nil, @TV) <= 0 then
    Exit;
  N := fpRead(FInputFd, @Bytes[0], SizeOf(Bytes));
  if N <= 0 then
    Exit;
  SetLength(Data, N);
  for I := 0 to N - 1 do
    Data[I] := Bytes[I];
  FDecoder.Feed(Data);
  if FTrace then
  begin
    Hex := '';
    for I := 0 to N - 1 do
      Hex := Hex + IntToHex(Bytes[I], 2) + ' ';
    TraceLine('bytes ' + Hex);
  end;
end;

function TInputSourceTerminal.Poll(out AEvent: TInputEvent): Boolean;
begin
  AEvent := Default(TInputEvent);
  if ResizeEvent(AEvent) then
  begin
    if FTrace then
      TraceLine(Format('event resize %dx%d', [AEvent.NewSize.W, AEvent.NewSize.H]));
    Exit(True);
  end;
  ReadAvailable;
  Result := FDecoder.Next(AEvent);
  if FTrace and Result then
    TraceLine(Format('event kind=%d key=%d ch=%s btn=%d xy=%d,%d',
      [Ord(AEvent.Kind), Ord(AEvent.Key.Kind),
      string(AEvent.Key.Ch), Ord(AEvent.Mouse.Button),
      AEvent.Mouse.X, AEvent.Mouse.Y]));
end;

function TInputSourceTerminal.QueryBackground: string;
const
  Query = #27']11;?'#27'\';
var
  Bytes: array[0..255] of Byte;
  N, I, Attempt: Integer;
  Fds: TFDSet;
  TV: TTimeVal;
begin
  Result := '';
  if FInputFd < 0 then
    Exit;
  fpWrite(1, Query[1], Length(Query));
  for Attempt := 1 to 15 do
  begin
    fpFD_ZERO(Fds);
    fpFD_SET(FInputFd, Fds);
    TV.tv_sec := 0;
    TV.tv_usec := 0;
    if fpSelect(FInputFd + 1, @Fds, nil, nil, @TV) > 0 then
    begin
      N := fpRead(FInputFd, @Bytes[0], SizeOf(Bytes));
      if N > 0 then
        for I := 0 to N - 1 do
          Result := Result + AnsiChar(Bytes[I]);
      if (Pos(#7, Result) > 0) or (Pos(#27 + '\', Result) > 0) then
        Break;
    end;
    Sleep(10);
  end;
  { Discard any straggler bytes (a late reply, or keys typed during startup) so
    they cannot reach the shell once we restore the terminal. }
  c_tcflush(FInputFd, TCIFLUSH);
  if FTrace then
    TraceLine('background query reply ' + Result);
end;

function TInputSourceTerminal.Wait(ATimeoutMs: Integer;
  out AEvent: TInputEvent): Boolean;
begin
  if Poll(AEvent) then
    Exit(True);
  if ATimeoutMs > 0 then
    Sleep(ATimeoutMs);
  Result := Poll(AEvent);
end;

end.
