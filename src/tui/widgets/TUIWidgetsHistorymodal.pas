unit TUIWidgetsHistorymodal;
{ The shared history dialog: the captured turns, newest first, with each turn's
  file stats. `/undo`, `/redo` and `/revert` all open it, because the operator is
  answering one question - WHICH TURN? - three times, and only the action
  differs.

  It browses; it does not act. It never touches a store, never moves a file, and
  knows nothing about undo or revert: it reports the selected turn id and the
  host decides what that means. That is what lets one dialog serve three
  commands without a mode flag deciding what a keystroke does.

  Rows are handed in already resolved (status, files, counts), so the dialog has
  no query and is testable with no database. See Turn_Summary_v1.SPEC.md,
  "One dialog, two handlers". }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils,
  TUIBase, TUIInput,
  TUISurface, TUIWidget,
  TUITheme, TUIGrapheme;

type
  { One turn as the dialog shows it. Resolved by the host from the turn record
    and the change log; the dialog only renders and selects. }
  THistoryRow = record
    TurnId: Int64;
    Seq: Integer;
    { What the turn was, for recognition: the prompt's first line. }
    Title: string;
    { How many files the turn's net rows touched, and the patch-backed counts.
      Files = 0 means the turn changed nothing (a read-only turn). }
    Files: Integer;
    Added, Removed: Integer;
    { False when the turn's changes carry no patch (the process tier), so the
      counts would be a lie. The row says so rather than showing +0 -0. }
    CountsKnown: Boolean;
    { Whether this turn is currently undone - the dialog shows it, because the
      list is the same list for undo, redo and revert. }
    Undone: Boolean;
    { Whether this turn may be acted on at all: a running or failed turn cannot
      be undone, and a turn below the redo floor cannot be redone. The host
      decides; the dialog greys it out and refuses to select it. }
    Selectable: Boolean;
  end;
  THistoryRowArray = array of THistoryRow;

  { What the dialog was opened for. It does not change what the LIST is - only
    the title and the footer verb - so one dialog serves all three commands
    without a mode flag deciding behaviour on a keystroke. }
  THistoryIntent = (hiUndo, hiRedo, hiRevert);

  THistoryChooseEvent = procedure(const ATurnId: Int64) of object;

  THistoryModal = class(TWidget)
  private
    FTheme: TTheme;
    FRows: THistoryRowArray;
    FSelected: Integer;
    FIntent: THistoryIntent;
    FOnChoose: THistoryChooseEvent;
    function VisibleRows: Integer;
    function SelectedRow: THistoryRow;
    procedure MoveSelection(ADelta: Integer);
    procedure Choose;
    function IntentVerb: string;
    { The row's position relative to the operator's current place: 0 is the
      newest turn for an undo, and -1, -2 step backwards. A REDO list runs the
      other way - +1, +2 forwards - because redoing walks into the future. The
      operator is choosing a DISTANCE and a direction, not reading a database
      sequence number they have never seen before. }
    function RowOrdinal(AIndex: Integer): Integer;
  public
    constructor Create(const ATheme: TTheme);
    { Replace the row set (already resolved). Newest first, as given. }
    procedure SetRows(const ARows: THistoryRowArray);
    property Intent: THistoryIntent read FIntent write FIntent;
    { The turn the operator activated, or 0. }
    function SelectedTurnId: Int64;
    property OnChoose: THistoryChooseEvent read FOnChoose write FOnChoose;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

const
  HistoryMinWidth = 56;
  { Borders (2) + title + footer. }
  HistoryChromeRows = 4;

implementation

constructor THistoryModal.Create(const ATheme: TTheme);
begin
  inherited Create;
  FTheme := ATheme;
  FSelected := 0;
  FIntent := hiUndo;
end;

procedure THistoryModal.SetRows;

  function CopyOfRow(const ARow: THistoryRow): THistoryRow;
  begin
    { A record with a managed field cannot be assigned wholesale across units
      safely in every FPC build; copying field by field keeps the string owned by
      this instance. }
    Result := Default(THistoryRow);
    Result.TurnId := ARow.TurnId;
    Result.Seq := ARow.Seq;
    Result.Title := ARow.Title;
    Result.Files := ARow.Files;
    Result.Added := ARow.Added;
    Result.Removed := ARow.Removed;
    Result.CountsKnown := ARow.CountsKnown;
    Result.Undone := ARow.Undone;
    Result.Selectable := ARow.Selectable;
  end;

var
  I: Integer;
begin
  SetLength(FRows, Length(ARows));
  for I := 0 to High(ARows) do
    FRows[I] := CopyOfRow(ARows[I]);
  FSelected := 0;
  { Land on the first SELECTABLE row: opening on a greyed-out turn would make
    Enter do nothing and look broken. }
  for I := 0 to High(FRows) do
    if FRows[I].Selectable then
    begin
      FSelected := I;
      Break;
    end;
end;

function THistoryModal.RowOrdinal(AIndex: Integer): Integer;
begin
  { Undo walks backwards from the newest: 0, -1, -2. Redo walks forwards into the
    turns an undo took away: +1, +2. Either way the operator reads a distance
    from where they are, which is what the choice actually is - a raw turn
    sequence number would be a database detail they have never seen. }
  if FIntent = hiRedo then
    Result := AIndex + 1
  else
    Result := -AIndex;
end;

function THistoryModal.IntentVerb: string;
begin
  case FIntent of
    hiUndo: Result := 'undo to this turn';
    hiRedo: Result := 'redo to this turn';
  else
    Result := 'revert this turn';
  end;
end;

function THistoryModal.VisibleRows: Integer;
begin
  Result := FBounds.H - HistoryChromeRows;
  if Result < 1 then
    Result := 1;
end;

function THistoryModal.SelectedRow: THistoryRow;
begin
  if (FSelected >= 0) and (FSelected <= High(FRows)) then
    Result := FRows[FSelected]
  else
    Result := Default(THistoryRow);
end;

function THistoryModal.SelectedTurnId: Int64;
var
  R: THistoryRow;
begin
  R := SelectedRow;
  if not R.Selectable then
    Exit(0);
  Result := R.TurnId;
end;

procedure THistoryModal.MoveSelection(ADelta: Integer);
var
  I: Integer;
begin
  { Skip unselectable rows when moving, so the arrow keys never land somewhere
    Enter is refused. If every row is unselectable the selection simply stays. }
  I := FSelected;
  repeat
    Inc(I, ADelta);
    if (I < 0) or (I > High(FRows)) then
      Exit;
  until FRows[I].Selectable;
  FSelected := I;
end;

procedure THistoryModal.Choose;
var
  Id: Int64;
begin
  Id := SelectedTurnId;
  if (Id = 0) or (not Assigned(FOnChoose)) then
    Exit;
  FOnChoose(Id);
end;

function THistoryModal.Measure(const AAvail: TSize): TSize;
begin
  Result.W := AAvail.W - 6;
  if Result.W < HistoryMinWidth then
    Result.W := AAvail.W;
  Result.H := AAvail.H - 4;
  if Result.H < HistoryChromeRows + 3 then
    Result.H := AAvail.H;
end;

procedure THistoryModal.Render(const S: ISurface);
var
  L, R, T, B, X, Y, I, Index: Integer;
  Bg, BorderAttr, TitleAttr, NormalAttr, MutedAttr, SelAttr, DimAttr,
    OkAttr, UndoneAttr: TAttr;
  Row: THistoryRow;
  Line, Stats, Badge, Num: string;
begin
  if (FBounds.W < 12) or (FBounds.H < HistoryChromeRows) then
    Exit;
  L := FBounds.X;
  R := FBounds.X + FBounds.W - 1;
  T := FBounds.Y;
  B := FBounds.Y + FBounds.H - 1;

  Bg := OnBg(FTheme.Text, FTheme.RaisedBg);
  BorderAttr := OnBg(FTheme.Border, FTheme.RaisedBg);
  TitleAttr := OnBg(FTheme.Title, FTheme.RaisedBg);
  NormalAttr := OnBg(FTheme.Text, FTheme.RaisedBg);
  MutedAttr := OnBg(FTheme.Muted, FTheme.RaisedBg);
  SelAttr := OnBg(FTheme.AccentSoft, FTheme.RaisedBg);
  DimAttr := OnBg(FTheme.Muted, FTheme.RaisedBg);
  OkAttr := OnBg(FTheme.Success, FTheme.RaisedBg);
  UndoneAttr := OnBg(FTheme.Error, FTheme.RaisedBg);

  S.FillRect(FBounds, Bg);
  PutCh(S, L, T, '╭', BorderAttr);
  PutCh(S, R, T, '╮', BorderAttr);
  PutCh(S, L, B, '╰', BorderAttr);
  PutCh(S, R, B, '╯', BorderAttr);
  for X := L + 1 to R - 1 do
  begin
    PutCh(S, X, T, '─', BorderAttr);
    PutCh(S, X, B, '─', BorderAttr);
  end;
  for Y := T + 1 to B - 1 do
  begin
    PutCh(S, L, Y, '│', BorderAttr);
    PutCh(S, R, Y, '│', BorderAttr);
  end;

  PutText(S, L + 2, T, UnicodeString(' History '), TitleAttr);

  if Length(FRows) = 0 then
  begin
    PutText(S, L + 2, T + 1, UnicodeString('no turns recorded yet'), MutedAttr);
  end
  else
    for I := 0 to VisibleRows - 1 do
    begin
      Index := I;
      if Index > High(FRows) then
        Break;
      Y := T + 1 + I;
      Row := FRows[Index];

      { The stat column first, so the numbers line up down the list regardless of
        how long each title is. An unknown count says '?', never 0. }
      if Row.Files = 0 then
        Stats := '     -'
      else if Row.CountsKnown then
        Stats := Format('%2d  +%d -%d', [Row.Files, Row.Added, Row.Removed])
      else
        Stats := Format('%2d    +? -?', [Row.Files]);

      if Row.Undone then
        Badge := 'undone'
      else
        Badge := '';

      if RowOrdinal(Index) < 0 then
        Num := '-'+IntToStr(-RowOrdinal(Index))
      else
        Num := ' ' + IntToStr(RowOrdinal(Index));
      Line := Format('%4s  %s  %s', [Num, Stats, Row.Title]);
      if Badge <> '' then
        Line := Line + '  [' + Badge + ']';

      if not Row.Selectable then
      begin
        { Visible but not actionable: the operator needs to see the turn exists
          and why Enter will not take it. }
        PutText(S, L + 2, Y, UnicodeString(Line), DimAttr);
      end
      else if Index = FSelected then
      begin
        PutText(S, L, Y, StringOfChar(WideChar(' '), FBounds.W), SelAttr);
        PutText(S, L + 1, Y, UnicodeString('>' + Line), SelAttr);
      end
      else if Row.Undone then
        PutText(S, L + 2, Y, UnicodeString(Line), UndoneAttr)
      else
        PutText(S, L + 2, Y, UnicodeString(Line), NormalAttr);
    end;

  PutText(S, L + 2, B, UnicodeString(IntentVerb), OkAttr);
  PutText(S, R - 20, B, UnicodeString('enter choose  esc close'), MutedAttr);
end;

function THistoryModal.HandleEvent(const E: TInputEvent): Boolean;
begin
  Result := False;
  if E.Kind <> ikKey then
    Exit;
  if Length(FRows) = 0 then
    { Only Escape is meaningful on an empty list. }
    Exit(E.Key.Kind = kkEscape);
  case E.Key.Kind of
    kkUp: begin MoveSelection(-1); Result := True; end;
    kkDown: begin MoveSelection(1); Result := True; end;
    kkHome:
      begin
        FSelected := 0;
        if not FRows[0].Selectable then
          MoveSelection(1);
        Result := True;
      end;
    kkEnd:
      begin
        FSelected := High(FRows);
        if not FRows[FSelected].Selectable then
          MoveSelection(-1);
        Result := True;
      end;
    kkEnter: begin Choose; Result := True; end;
  else
    { Escape and anything else are the host's: the plane pop is deferred there,
      the same discipline as the sessions modal. }
    Result := False;
  end;
end;

end.
