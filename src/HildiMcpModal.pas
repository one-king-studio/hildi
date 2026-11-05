unit HildiMcpModal;
{ The `/mcp` dialog: every installed MCP server with its three separate facts —
  connection, enabled, active — and a per-row action.

  Lives in src/ rather than the TUI library because it is about MCP servers, not
  about text and layout: a stranger's project would not want it. It sits beside
  HildiSkillModal, which is the same shape.

  A COMPOSITE, in the specific sense that matters here: TModal owns the frame and
  renders FRows as its ONE content widget, so TMcpModal overrides only
  HandleEvent - it must offer input to the rows before claiming keys itself - and
  FooterClicked. It does NOT re-declare Measure/Arrange/Render/HitTest/
  CopySelection/Advance/Animating: TModal already forwards those to its content,
  and a second forward here would be a no-op that looked like diligence.

  Checked, not assumed, because the distinction is exactly what four composites
  got wrong: TModal forwards CopySelection and HandleEvent to FContent, and
  TMcpRows returns False from Advance and Animating, so there is no animation to
  forward today. If TMcpRows ever animates, TMcpModal must override both, and
  nothing will fail if it does not. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils,
  TUIBase, TUIInput, TUISurface, TUIWidget, TUIGrapheme, TUITheme,
  TUIWidgetsModal,
  HildiSessionProtocol, HildiMCPConfig;

type
  { Reconnect requested for one server key. }
  TMcpReconnectEvent = procedure(const AKey: string) of object;
  { Add requested: the modal closes and the host opens the add form. }
  TMcpAddEvent = procedure of object;

  { The rows. A separate widget rather than painting inside the modal, because
    TModal owns the frame and this owns the list — the same split HildiSkillModal
    makes, and it keeps per-row hit-testing inside the row widget. }
  TMcpRows = class(TWidget)
  private
    FTheme: TTheme;
    FRows: TMcpRowStatusArray;
    FSel: Integer;
    FWidth: Integer;
    { -1 when the point is not over a row. Private, per the established shape:
      HitTest answers "is the point mine", a row index is this widget's own
      business. }
    { A one-line message from the host, e.g. why an action could not run. }
    FErrorHint: string;
    { BUSY: an action is in flight (a probe or a reconnect, which may wait on a
      server that never answers its tools/list). While busy the list paints a
      spinner and every CTA is refused, because letting the operator close the
      dialog mid-action is how a hang became "it crashed" - the modal vanished
      with nothing to say what was happening. }
    FBusy: Boolean;
    FBusyText: string;
    FBusySinceMs: Int64;
    function RowAt(AY: Integer): Integer;
    function RowTop(AIndex: Integer): Integer;
    procedure Move(ASteps: Integer);
  public
    constructor Create(const ATheme: TTheme);
    procedure SetRows(const ARows: TMcpRowStatusArray);
    { The selected row's key, '' when the list is empty. }
    function SelectedKey: string;
    { Show a message under the list (an action that could not run). '' clears it. }
    procedure SetHint(const AText: string);
    { An action started: show a spinner with AText and refuse every CTA until
      ClearBusy. }
    procedure SetBusy(const AText: string);
    procedure ClearBusy;
    property Busy: Boolean read FBusy;
    procedure SelectFirst;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function HitTest(AX, AY: Integer): Boolean; override;
    function CopySelection(const S: ISurface): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
  end;

  TMcpModal = class(TModal)
  private
    FRows: TMcpRows;
    FOnReconnect: TMcpReconnectEvent;
    FOnAdd: TMcpAddEvent;
    { TModal has no close protocol: the HOST owns FCloseModal. So dismissal is a
      callback rather than a method on this widget - the same shape OnAdd uses. }
    FOnClose: TMcpAddEvent;
    { An action is in flight. Owned here because the DIALOG decides what to
      refuse (Esc, the other CTAs); the rows widget only paints it. }
    FBusy: Boolean;
    procedure RequestClose;
    procedure Reconnect;
    procedure RefreshFooter;
  public
    constructor Create(const ATheme: TTheme);
    { Replace the list. The caller sets connection to mcUnknown before a probe
      has answered; this widget only renders what it is given. }
    procedure SetRows(const ARows: TMcpRowStatusArray);
    function SelectedKey: string;
    { A message under the list, from the host. '' clears it. }
    procedure SetHint(const AText: string);
    { An action started: spinner + elapsed, and every CTA (including Esc) is
      refused until ClearBusy. A server that never answers its tools/list hangs
      here, and this is what says "waiting" instead of "crashed". }
    procedure SetBusy(const AText: string);
    procedure ClearBusy;
    property Busy: Boolean read FBusy;
    property OnReconnect: TMcpReconnectEvent read FOnReconnect write FOnReconnect;
    property OnAdd: TMcpAddEvent read FOnAdd write FOnAdd;
    { The host closes its own modal. }
    property OnClose: TMcpAddEvent read FOnClose write FOnClose;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  protected
    procedure FooterClicked(const AKey: string); override;
    { TModal does not forward Animating, so without this the app never repaints
      while busy and the spinner freezes on its first frame - the very "unclear
      what is happening" the indicator exists to fix. }
    function Animating: Boolean; override;
  end;

{ The spinner frame for a start time. A pure function of the clock, so Redraw
  advances it without the widget owning a timer - the app already redraws every
  frame, and a TSpinner here would need Advance() plumbing for one glyph. }
function SpinnerFrame(const AStartMs: Int64): string;

{ The three statuses as one short line, so a row fits a narrow dialog. Separate
  glyphs per fact because "down" and "not in use" are different answers and the
  whole point of this dialog is not to conflate them. }
function McpStatusText(const ARow: TMcpRowStatus): string;

implementation

const
  RowHeight = 1;
  { Status column width: enough for "up on loaded" plus its separators. }
  MaxKeyCols = 18;
  MaxDescCols = 40;

function SpinnerFrame(const AStartMs: Int64): string;
const
  Frames: array[0..9] of string =
    ('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏');
var
  Elapsed: Int64;
begin
  Elapsed := GetTickCount64 - AStartMs;
  if Elapsed < 0 then
    Elapsed := 0;
  Result := Frames[(Elapsed div 90) mod 10];
end;

function McpStatusText(const ARow: TMcpRowStatus): string;
begin
  { Connection: a probe answered it, or nobody has asked yet. mcUnknown renders
    as a dash, never as "down" - claiming down for an unprobed server would be a
    lie the operator then acts on. }
  case ARow.Connection of
    mcConnected:    Result := 'up';
    mcDisconnected: Result := 'down';
  else
    Result := '--';
  end;
  if ARow.Enabled then
    Result := Result + ' on'
  else
    Result := Result + ' off';
  if ARow.Active then
    Result := Result + ' loaded'
  else
    Result := Result + ' idle';
end;

{ Clip AText to AMaxCells on a grapheme boundary. Slicing by byte or code unit
  would split a wide character or a combining mark and corrupt the row. }
function ClipCells(const AText: UnicodeString; AMaxCells: Integer): UnicodeString;
var
  C: TClusterArray;
  I, W: Integer;
begin
  Result := '';
  if AMaxCells <= 0 then
    Exit;
  if StringWidth(AText) <= AMaxCells then
    Exit(AText);
  C := Clusters(AText);
  W := 0;
  for I := 0 to High(C) do
  begin
    if W + ClusterWidth(C[I]) > AMaxCells - 1 then
      Break;
    Result := Result + C[I];
    Inc(W, ClusterWidth(C[I]));
  end;
  Result := Result + '~';
end;

function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

{ --- TMcpRows ----------------------------------------------------------- }

constructor TMcpRows.Create(const ATheme: TTheme);
begin
  inherited Create;
  FTheme := ATheme;
  FSel := -1;
end;

procedure TMcpRows.SetRows(const ARows: TMcpRowStatusArray);
begin
  FRows := ARows;
  if Length(FRows) = 0 then
    FSel := -1
  else if (FSel < 0) or (FSel > High(FRows)) then
    FSel := 0;
end;

function TMcpRows.SelectedKey: string;
begin
  if (FSel >= 0) and (FSel <= High(FRows)) then
    Result := FRows[FSel].Key
  else
    Result := '';
end;

procedure TMcpRows.SetHint(const AText: string);
begin
  FErrorHint := AText;
end;

procedure TMcpRows.SetBusy(const AText: string);
begin
  FBusy := True;
  FBusyText := AText;
  FBusySinceMs := GetTickCount64;
end;

procedure TMcpRows.ClearBusy;
begin
  FBusy := False;
  FBusyText := '';
end;

procedure TMcpRows.SelectFirst;
begin
  if Length(FRows) > 0 then
    FSel := 0
  else
    FSel := -1;
end;

procedure TMcpRows.Move(ASteps: Integer);
var
  N: Integer;
begin
  N := FSel + ASteps;
  if (N < 0) or (N > High(FRows)) then
    Exit;
  FSel := N;
end;

function TMcpRows.RowTop(AIndex: Integer): Integer;
begin
  Result := FBounds.Y + AIndex * RowHeight;
end;

function TMcpRows.RowAt(AY: Integer): Integer;
var
  Rel: Integer;
begin
  Result := -1;
  if Length(FRows) = 0 then
    Exit;
  Rel := AY - FBounds.Y;
  if Rel < 0 then
    Exit;
  Result := Rel div RowHeight;
  if Result > High(FRows) then
    Result := -1;
end;

function TMcpRows.Measure(const AAvail: TSize): TSize;
begin
  { One row per server; an empty list still reserves a line so the dialog does
    not collapse to a sliver. }
  Result.W := AAvail.W;
  Result.H := Length(FRows) * RowHeight;
  if Result.H = 0 then
    Result.H := 1;
end;

procedure TMcpRows.Arrange(const ABounds: TRect);
begin
  inherited Arrange(ABounds);
  FWidth := ABounds.W;
end;

procedure TMcpRows.Render(const S: ISurface);
var
  I, Y, KeyW, DescW, StatusW, StatusX: Integer;
  Line, Key, Desc, Status: UnicodeString;
  SelAttr, KeyAttr, DescAttr, BadAttr: TAttr;
begin
  if FBounds.W < 8 then
    Exit;
  StatusW := 14;
  KeyW := MaxKeyCols;
  if KeyW > FBounds.W div 3 then
    KeyW := FBounds.W div 3;
  DescW := FBounds.W - KeyW - StatusW - 4;
  if DescW > MaxDescCols then
    DescW := MaxDescCols;
  if DescW < 4 then
    DescW := 4;
  StatusX := FBounds.X + KeyW + DescW + 3;

  SelAttr := OnBg(FTheme.Text, FTheme.RaisedBg);
  KeyAttr := OnBg(FTheme.Text, FTheme.Bg);
  DescAttr := OnBg(FTheme.Muted, FTheme.Bg);
  { A server that is enabled but DOWN is the one combination that needs action,
    so it is the only one painted as a problem. }
  BadAttr := OnBg(FTheme.Accent, FTheme.Bg);

  if Length(FRows) = 0 then
  begin
    PutText(S, FBounds.X, FBounds.Y,
      'no MCP servers configured', DescAttr);
    Exit;
  end;

  for I := 0 to High(FRows) do
  begin
    Y := RowTop(I);
    if Y >= FBounds.Y + FBounds.H then
      Break;
    if FRows[I].LabelText <> '' then
      Key := UnicodeString(FRows[I].LabelText)
    else
      Key := UnicodeString(FRows[I].Key);
    Desc := UnicodeString(FRows[I].Description);
    Status := UnicodeString(McpStatusText(FRows[I]));
    Line := ClipCells(Key, KeyW);
    PutText(S, FBounds.X, Y, Line, KeyAttr);
    if Desc <> '' then
      PutText(S, FBounds.X + KeyW + 1, Y, ClipCells(Desc, DescW), DescAttr);
    if (FRows[I].Enabled) and (FRows[I].Connection = mcDisconnected) then
      PutText(S, StatusX, Y, Status, BadAttr)
    else
      PutText(S, StatusX, Y, Status, DescAttr);
    { The selected row is marked by its key cell alone rather than by repainting
      the line, so a hover-highlighted status cannot lose its colour. }
    if I = FSel then
      PutText(S, FBounds.X, Y, ClipCells(Key, KeyW), SelAttr);
    { A failed probe or reconnect is the one thing the operator must not miss,
      and it was silently dropped: the row carried Error and nothing painted it,
      so a reconnect that failed looked exactly like one that did nothing. It
      replaces the STATUS cell rather than extending the line, because a long
      error would otherwise push the row past the frame. }
    if FRows[I].Error <> '' then
      PutText(S, StatusX, Y, ClipCells(UnicodeString(FRows[I].Error),
        FBounds.W - (StatusX - FBounds.X)), BadAttr);
  end;
  if FBusy then
  begin
    { The elapsed count is the point: a server that never answers its tools/list
      hangs here, and "2s... 7s... 31s..." is what tells the operator it is
      WAITING rather than crashed. }
    Line := ClipCells(UnicodeString(SpinnerFrame(FBusySinceMs)),
      FBounds.W);
    PutText(S, FBounds.X, FBounds.Y + FBounds.H - 1, Line, BadAttr);
    if FBounds.W > 2 then
      PutText(S, FBounds.X + 2, FBounds.Y + FBounds.H - 1,
        ClipCells(UnicodeString(FBusyText + ' ' +
          IntToStr((GetTickCount64 - FBusySinceMs) div 1000) + 's'),
          FBounds.W - 2), BadAttr);
  end
  else if (FErrorHint <> '') then
    PutText(S, FBounds.X, FBounds.Y + FBounds.H - 1,
      ClipCells(UnicodeString(FErrorHint), FBounds.W), BadAttr);
end;

function TMcpRows.HandleEvent(const E: TInputEvent): Boolean;
var
  Hit: Integer;
begin
  Result := False;
  if E.Kind = ikMouse then
  begin
    if (E.Mouse.Button = mbLeft) and HitTest(E.Mouse.X, E.Mouse.Y) then
    begin
      Hit := RowAt(E.Mouse.Y);
      if Hit >= 0 then
      begin
        FSel := Hit;
        Result := True;
      end;
    end;
    Exit;
  end;
  if E.Kind <> ikKey then
    Exit;
  case E.Key.Kind of
    kkUp:
      begin
        Move(-1);
        Result := True;
      end;
    kkDown:
      begin
        Move(1);
        Result := True;
      end;
  else
    ;   // everything else is the modal's
  end;
end;

function TMcpRows.HitTest(AX, AY: Integer): Boolean;
begin
  { The list occupies whole rows from its own top, so the base answer is right -
    but only when a row is actually there, otherwise a click on empty space would
    claim the event and swallow it. }
  Result := False;
  if (not Visible) or (Length(FRows) = 0) then
    Exit;
  if (AX < FBounds.X) or (AX >= FBounds.X + FBounds.W) then
    Exit;
  Result := RowAt(AY) >= 0;
end;

function TMcpRows.CopySelection(const S: ISurface): Boolean;
begin
  { The dialog has no text worth copying except its rows, and a row is a summary
    rather than content. False, so an enclosing pane may answer instead. }
  Result := False;
end;

function TMcpRows.Advance(const ANowMs: Int64): Boolean;
begin
  { True while busy: the elapsed counter and the spinner both change every
    frame, so the app must keep repainting. Returning False (as this did) would
    freeze the indicator at its first frame. }
  Result := FBusy;
end;

function TMcpRows.Animating: Boolean;
begin
  Result := FBusy;
end;

{ --- TMcpModal ---------------------------------------------------------- }

constructor TMcpModal.Create(const ATheme: TTheme);
begin
  FRows := TMcpRows.Create(ATheme);
  { Not scrollable: the row widget lays out whole rows and the list is short.
    A scroll container would also intercept the arrow keys the rows use. }
  inherited Create(ATheme, FRows, False);
  SetTitle('MCP servers');
  RefreshFooter;
end;

procedure TMcpModal.RefreshFooter;
begin
  { Groups separated by two spaces, not the middle dot: the house style, and it
    keeps ONE separator alive in the tree. The dot is still accepted by both the
    splitter and the drawing walk, but a second style in use is how the two
    drifted apart in the first place. }
  { Chords, not single letters: a bare 'a' is typable text in a form, and a
    dialog whose CTAs are one letter apart invites a mistyped destructive key.
    'connect' rather than 'reconnect' because the key is for TESTING a server -
    it works whether or not the transport was ever up. }
  SetFooter('ctrl+a add   ctrl+t connect   esc close');
end;

procedure TMcpModal.SetRows(const ARows: TMcpRowStatusArray);
begin
  FRows.SetRows(ARows);
  FRows.SelectFirst;
end;

function TMcpModal.SelectedKey: string;
begin
  Result := FRows.SelectedKey;
end;

procedure TMcpModal.SetHint(const AText: string);
begin
  FRows.SetHint(AText);
end;

procedure TMcpModal.RequestClose;
begin
  { The single close path, so the busy guard lives here as well as in the key
    arm: nothing may dismiss the dialog while an action is unresolved. }
  if FBusy then
    Exit;
  if Assigned(FOnClose) then
    FOnClose();
end;

procedure TMcpModal.Reconnect;
var
  Key: string;
begin
  if FBusy then
    Exit;
  Key := FRows.SelectedKey;
  if (Key = '') or (not Assigned(FOnReconnect)) then
  begin
    FRows.SetHint('select a server first');
    Exit;
  end;
  FOnReconnect(Key);
end;

function TMcpModal.Animating: Boolean;
begin
  Result := FBusy;
end;

procedure TMcpModal.SetBusy(const AText: string);
begin
  FBusy := True;
  FRows.SetBusy(AText);
end;

procedure TMcpModal.ClearBusy;
begin
  FBusy := False;
  FRows.ClearBusy;
end;

function TMcpModal.HandleEvent(const E: TInputEvent): Boolean;
begin
  { The rows first, so arrows move the selection; the modal keeps the rest. }
  if FRows.HandleEvent(E) then
    Exit(True);
  if E.Kind = ikKey then
    case E.Key.Kind of
      kkEscape:
        begin
          { BLOCKED while an action is in flight. Closing the dialog during a
            hung tools/list is what made a slow server look like a crash: the
            modal vanished and nothing said the work was still running. Esc is
            swallowed (True) so the unhandled-Escape path cannot pop the plane
            either. }
          if FBusy then
            Exit(True);
          RequestClose;
          Exit(True);
        end;
      kkChar:
        begin
          { A CHORD, so a plain letter still belongs to the list: ctrl+t tests a
            server, ctrl+a adds one. }
          if moCtrl in E.Key.Mods then
          begin
            if (E.Key.Ch = 't') or (E.Key.Ch = 'T') then
            begin
              Reconnect;
              Exit(True);
            end;
            if (E.Key.Ch = 'a') or (E.Key.Ch = 'A') then
            begin
              { Refused while busy, like ctrl+t: stacking a second action on top
                of an unresolved one is how two waits become one invisible one. }
              if FBusy then
                Exit(True);
              if Assigned(FOnAdd) then
                FOnAdd();
              Exit(True);
            end;
          end;
        end;
    else
      ;
    end;
  Result := inherited HandleEvent(E);
end;

procedure TMcpModal.FooterClicked(const AKey: string);
begin
  { The click carries the pair's KEY, which is now the chord text. }
  if AKey = 'esc' then
  begin
    if FBusy then
      Exit;
    RequestClose;
  end
  else if AKey = 'ctrl+t' then
    Reconnect
  else if AKey = 'ctrl+a' then
  begin
    if FBusy then
      Exit;
    if Assigned(FOnAdd) then
      FOnAdd();
  end
  else
    inherited FooterClicked(AKey);
end;

end.
