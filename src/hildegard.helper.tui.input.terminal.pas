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
    FOldTio: termios;
    FRawSet: Boolean;
    FDecoder: TKeyDecoder;
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
  SysUtils, baseunix;

constructor TInputSourceTerminal.Create;
var
  WS: TWinsize;
  Tio: termios;
begin
  inherited Create;
  FRawSet := False;
  if TCGetAttr(0, FOldTio) = 0 then
  begin
    Tio := FOldTio;
    CFMakeRaw(Tio);
    if TCSetAttr(0, TCSANOW, Tio) = 0 then
      FRawSet := True;
  end;
  FDecoder := TKeyDecoder.Create;
  FillChar(WS, SizeOf(WS), 0);
  if (fpioctl(0, TIOCGWINSZ, @WS) = 0) and (WS.ws_col > 0) and (WS.ws_row > 0)
  then
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
begin
  FDecoder.Free;
  if FRawSet then
    TCSetAttr(0, TCSANOW, FOldTio);
  inherited Destroy;
end;

function TInputSourceTerminal.ResizeEvent(out AEvent: TInputEvent): Boolean;
var
  WS: TWinsize;
begin
  AEvent := Default(TInputEvent);
  Result := False;
  FillChar(WS, SizeOf(WS), 0);
  if fpioctl(0, TIOCGWINSZ, @WS) <> 0 then
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
begin
  fpFD_ZERO(Fds);
  fpFD_SET(0, Fds);
  TV.tv_sec := 0;
  TV.tv_usec := 0;
  if fpSelect(1, @Fds, nil, nil, @TV) <= 0 then
    Exit;
  N := fpRead(0, @Bytes[0], SizeOf(Bytes));
  if N <= 0 then
    Exit;
  SetLength(Data, N);
  for I := 0 to N - 1 do
    Data[I] := Bytes[I];
  FDecoder.Feed(Data);
end;

function TInputSourceTerminal.Poll(out AEvent: TInputEvent): Boolean;
begin
  AEvent := Default(TInputEvent);
  if ResizeEvent(AEvent) then
    Exit(True);
  ReadAvailable;
  Result := FDecoder.Next(AEvent);
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
