unit TUIInput;
{ Input events and sources for the TUI toolkit.

  The toolkit consumes these event shapes; widgets never read the terminal. The
  terminal adapter (FPC keyboard plus TIOCGWINSZ) is added in the terminal
  phase. TInputSourceScripted feeds canned events to tests. Mouse events are
  reserved in the contract so widgets can adopt them later without a break. }

{$mode delphi}{$H+}

interface

uses
  TUIBase;

type
  { moSuper is Cmd on macOS. Terminals rarely forward it; a terminal can be
    configured to send the kitty super bit (see MapCSIu). }
  TModifier = (moShift, moCtrl, moAlt, moSuper);
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

  TInputKind = (ikNone, ikKey, ikMouse, ikResize, ikPaste, ikFocus);

  TInputEvent = record
    Kind: TInputKind;
    Key: TKeyEvent;
    Mouse: TMouseEvent;
    NewSize: TSize;      // when Kind = ikResize
    Text: UnicodeString; // when Kind = ikPaste (a bracketed-paste payload)
    Focused: Boolean;    // when Kind = ikFocus: True on focus in
  end;

  { A non-blocking source of input events. Poll returns False when no event is
    ready; Wait idles for up to ATimeoutMs (zero is a pure poll). }
  IInputSource = interface
    function Poll(out AEvent: TInputEvent): Boolean;
    function Wait(ATimeoutMs: Integer; out AEvent: TInputEvent): Boolean;
  end;

  { Debounces a terminal size. A size is only reported once it has held still for
    a settle period, so dragging a window edge does not re-lay-out and repaint the
    screen on every intermediate size. Pure: the caller supplies the clock, which
    keeps it testable without a tty. }
  TResizeSettler = record
  private
    FCols, FRows: Integer;
    FPendingCols, FPendingRows: Integer;
    FSinceMs: Int64;
  public
    { Adopt ACols x ARows as the current size without reporting it. }
    procedure Init(ACols, ARows: Integer);
    { True while a differing size is waiting out the settle period. }
    function Pending: Boolean;
    { Offer the size the terminal reports now. Returns True once a differing size
      has held still for ASettleMs; AOutCols/AOutRows then hold it and it becomes
      the current size. }
    function Feed(ACols, ARows: Integer; ANowMs: Int64; ASettleMs: Integer;
      out AOutCols, AOutRows: Integer): Boolean;
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

procedure TResizeSettler.Init(ACols, ARows: Integer);
begin
  FCols := ACols;
  FRows := ARows;
  FPendingCols := 0;
  FPendingRows := 0;
  FSinceMs := 0;
end;

function TResizeSettler.Pending: Boolean;
begin
  Result := FPendingCols > 0;
end;

function TResizeSettler.Feed(ACols, ARows: Integer; ANowMs: Int64;
  ASettleMs: Integer; out AOutCols, AOutRows: Integer): Boolean;
begin
  AOutCols := FCols;
  AOutRows := FRows;
  Result := False;
  if (ACols = FCols) and (ARows = FRows) then
  begin
    FPendingCols := 0;
    FPendingRows := 0;
    Exit;
  end;
  if (ACols <> FPendingCols) or (ARows <> FPendingRows) then
  begin
    { Still moving: restart the settle timer. }
    FPendingCols := ACols;
    FPendingRows := ARows;
    FSinceMs := ANowMs;
    Exit;
  end;
  if ANowMs - FSinceMs < ASettleMs then
    Exit;
  FCols := ACols;
  FRows := ARows;
  FPendingCols := 0;
  FPendingRows := 0;
  AOutCols := FCols;
  AOutRows := FRows;
  Result := True;
end;

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
