unit hildegard.helper.tui.input;
{ Input events and sources for the TUI toolkit.

  The toolkit consumes these event shapes; widgets never read the terminal. The
  terminal adapter (FPC keyboard plus TIOCGWINSZ) is added in the terminal
  phase. TInputSourceScripted feeds canned events to tests. Mouse events are
  reserved in the contract so widgets can adopt them later without a break. }

{$mode delphi}{$H+}

interface

uses
  hildegard.helper.tui.base;

type
  TModifier = (moShift, moCtrl, moAlt);
  TModifiers = set of TModifier;

  TKeyKind = (kkNone, kkChar, kkEnter, kkEscape, kkTab, kkBackspace, kkDelete,
    kkUp, kkDown, kkLeft, kkRight, kkPageUp, kkPageDown, kkHome, kkEnd,
    kkFunction);

  TKeyEvent = record
    Kind: TKeyKind;
    Ch: UnicodeString;   // when Kind = kkChar
    FuncIndex: Integer;  // when Kind = kkFunction (1 = F1)
    Mods: TModifiers;
  end;

  TMouseButton = (mbNone, mbLeft, mbMiddle, mbRight, mbWheelUp, mbWheelDown);
  TMouseEvent = record
    X, Y: Integer;
    Button: TMouseButton;
    Mods: TModifiers;
  end;

  TInputKind = (ikNone, ikKey, ikMouse, ikResize);

  TInputEvent = record
    Kind: TInputKind;
    Key: TKeyEvent;
    Mouse: TMouseEvent;
    NewSize: TSize;      // when Kind = ikResize
  end;

  { A non-blocking source of input events. Poll returns False when no event is
    ready; Wait idles for up to ATimeoutMs (zero is a pure poll). }
  IInputSource = interface
    function Poll(out AEvent: TInputEvent): Boolean;
    function Wait(ATimeoutMs: Integer; out AEvent: TInputEvent): Boolean;
  end;

  { Scripted source for tests: events are queued with Push and drained in order
    by Poll. Wait does not block - scripted tests always drive Poll directly. }
  TInputSourceScripted = class(TInterfacedObject, IInputSource)
  private
    FQueue: array of TInputEvent;
    FHead: Integer;
  public
    procedure Push(const AEvent: TInputEvent);
    function Poll(out AEvent: TInputEvent): Boolean;
    function Wait(ATimeoutMs: Integer; out AEvent: TInputEvent): Boolean;
  end;

implementation

procedure TInputSourceScripted.Push(const AEvent: TInputEvent);
begin
  SetLength(FQueue, Length(FQueue) + 1);
  FQueue[High(FQueue)] := AEvent;
end;

function TInputSourceScripted.Poll(out AEvent: TInputEvent): Boolean;
begin
  AEvent := Default(TInputEvent);
  Result := FHead < Length(FQueue);
  if Result then
  begin
    AEvent := FQueue[FHead];
    Inc(FHead);
  end;
end;

function TInputSourceScripted.Wait(ATimeoutMs: Integer;
  out AEvent: TInputEvent): Boolean;
begin
  Result := Poll(AEvent);
end;

end.
