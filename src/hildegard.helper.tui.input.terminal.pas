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
    function ResizeEvent(out AEvent: TInputEvent): Boolean;
    procedure ReadAvailable;
  public
    constructor Create;
    destructor Destroy; override;
    function Poll(out AEvent: TInputEvent): Boolean;
    function Wait(ATimeoutMs: Integer; out AEvent: TInputEvent): Boolean;
  end;

implementation

uses
  ctypes, SysUtils, baseunix;

function c_isatty(Fd: cint): cint; cdecl; external 'c' name 'isatty';

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
  MouseOff = #27'[?1006l'#27'[?1002l'#27'[?1000l';
begin
  fpWrite(1, MouseOff[1], Length(MouseOff));
  FDecoder.Free;
  if FRawSet then
    TCSetAttr(FInputFd, TCSANOW, FOldTio);
  if FOpenedTty then
    fpClose(FInputFd);
  inherited Destroy;
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
