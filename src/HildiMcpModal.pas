unit HildiMcpModal;
{ The `/mcp` dialog: every installed MCP server with its three separate facts —
  connection, enabled, active — and a per-row action.

  Lives in src/ rather than the TUI library because it is about MCP servers, not
  about text and layout: a stranger's project would not want it. It sits beside
  HildiSkillModal, which is the same shape.

  A COMPOSITE, so it forwards every protocol method its base declares. That is
  not tidiness: TWidget grew HitTest and CopySelection, and four composites in
  the app failed to forward one and each was found by an operator in a terminal
  rather than by a test. Measure/Arrange/Render/HandleEvent/Advance/Animating/
  HitTest/CopySelection are all overridden below. }

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
    function RowAt(AY: Integer): Integer;
    function RowTop(AIndex: Integer): Integer;
    procedure Move(ASteps: Integer);
  public
    constructor Create(const ATheme: TTheme);
    procedure SetRows(const ARows: TMcpRowStatusArray);
    { The selected row's key, '' when the list is empty. }
    function SelectedKey: string;
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
    procedure RequestClose;
    procedure Reconnect;
    procedure RefreshFooter;
  public
    constructor Create(const ATheme: TTheme);
    { Replace the list. The caller sets connection to mcUnknown before a probe
      has answered; this widget only renders what it is given. }
    procedure SetRows(const ARows: TMcpRowStatusArray);
    function SelectedKey: string;
    property OnReconnect: TMcpReconnectEvent read FOnReconnect write FOnReconnect;
    property OnAdd: TMcpAddEvent read FOnAdd write FOnAdd;
    { The host closes its own modal. }
    property OnClose: TMcpAddEvent read FOnClose write FOnClose;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  protected
    procedure FooterClicked(const AKey: string); override;
  end;

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
  end;
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
  Result := False;
end;

function TMcpRows.Animating: Boolean;
begin
  Result := False;
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
  SetFooter('a add   r reconnect   esc close');
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

procedure TMcpModal.RequestClose;
begin
  if Assigned(FOnClose) then
    FOnClose();
end;

procedure TMcpModal.Reconnect;
var
  Key: string;
begin
  Key := FRows.SelectedKey;
  if (Key = '') or (not Assigned(FOnReconnect)) then
    Exit;
  FOnReconnect(Key);
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
          RequestClose;
          Exit(True);
        end;
      kkChar:
        begin
          if (E.Key.Ch = 'r') or (E.Key.Ch = 'R') then
          begin
            Reconnect;
            Exit(True);
          end;
          if (E.Key.Ch = 'a') or (E.Key.Ch = 'A') then
          begin
            if Assigned(FOnAdd) then
              FOnAdd();
            RequestClose;
            Exit(True);
          end;
        end;
    else
      ;
    end;
  Result := inherited HandleEvent(E);
end;

procedure TMcpModal.FooterClicked(const AKey: string);
begin
  if AKey = 'esc' then
    RequestClose
  else if AKey = 'r' then
    Reconnect
  else if AKey = 'a' then
  begin
    if Assigned(FOnAdd) then
      FOnAdd();
    RequestClose;
  end
  else
    inherited FooterClicked(AKey);
end;

end.
