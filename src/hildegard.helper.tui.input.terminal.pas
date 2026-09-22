unit hildegard.helper.tui.input.terminal;
{ Terminal input adapter: FPC keyboard decoding plus TIOCGWINSZ resize.

  This is the only place the toolkit touches the keyboard. Poll first checks the
  window size (emitting ikResize when it changed) and then decodes one key via
  the enhanced keyboard events. The core input unit has no terminal dependency. }

{$mode delphi}{$H+}

interface

uses
  keyboard,
  hildegard.helper.tui.base, hildegard.helper.tui.input;

type
  TInputSourceTerminal = class(TInterfacedObject, IInputSource)
  private
    FLastCol, FLastRow: Integer;
    function ResizeEvent(out AEvent: TInputEvent): Boolean;
    function MapKey(const AKey: TEnhancedKeyEvent;
      out AEvent: TInputEvent): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function Poll(out AEvent: TInputEvent): Boolean;
    function Wait(ATimeoutMs: Integer; out AEvent: TInputEvent): Boolean;
  end;

implementation

uses
  SysUtils, baseunix, termio;

constructor TInputSourceTerminal.Create;
var
  WS: TWinsize;
begin
  inherited Create;
  InitKeyboard;
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
  DoneKeyboard;
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

function TInputSourceTerminal.MapKey(const AKey: TEnhancedKeyEvent;
  out AEvent: TInputEvent): Boolean;
var
  Mods: TModifiers;
begin
  AEvent := Default(TInputEvent);
  Result := False;
  Mods := [];
  if essShift in AKey.ShiftState then
    Include(Mods, moShift);
  if essCtrl in AKey.ShiftState then
    Include(Mods, moCtrl);
  if (essAlt in AKey.ShiftState) or (essAltGr in AKey.ShiftState) then
    Include(Mods, moAlt);
  AEvent.Kind := ikKey;
  AEvent.Key.Mods := Mods;
  case AKey.VirtualKeyCode of
    kbdUp:
      AEvent.Key.Kind := kkUp;
    kbdDown:
      AEvent.Key.Kind := kkDown;
    kbdLeft:
      AEvent.Key.Kind := kkLeft;
    kbdRight:
      AEvent.Key.Kind := kkRight;
    kbdPgUp:
      AEvent.Key.Kind := kkPageUp;
    kbdPgDn:
      AEvent.Key.Kind := kkPageDown;
    kbdHome:
      AEvent.Key.Kind := kkHome;
    kbdEnd:
      AEvent.Key.Kind := kkEnd;
    kbdDelete:
      AEvent.Key.Kind := kkDelete;
  else
    if (AKey.VirtualKeyCode >= kbdF1) and (AKey.VirtualKeyCode <= kbdF20) then
    begin
      AEvent.Key.Kind := kkFunction;
      AEvent.Key.FuncIndex := AKey.VirtualKeyCode - kbdF1 + 1;
    end
    else
      case AKey.UnicodeChar of
        #13:
          AEvent.Key.Kind := kkEnter;
        #27:
          AEvent.Key.Kind := kkEscape;
        #9:
          AEvent.Key.Kind := kkTab;
        #8, #127:
          AEvent.Key.Kind := kkBackspace;
      else
        if Ord(AKey.UnicodeChar) >= 32 then
        begin
          AEvent.Key.Kind := kkChar;
          AEvent.Key.Ch := UnicodeString(AKey.UnicodeChar);
        end
        else
          Exit(False);
      end;
  end;
  Result := True;
end;

function TInputSourceTerminal.Poll(out AEvent: TInputEvent): Boolean;
var
  K: TEnhancedKeyEvent;
begin
  AEvent := Default(TInputEvent);
  if ResizeEvent(AEvent) then
    Exit(True);
  K := PollEnhancedKeyEvent;
  Result := MapKey(K, AEvent);
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
