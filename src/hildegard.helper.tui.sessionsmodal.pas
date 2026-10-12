unit hildegard.helper.tui.sessionsmodal;
{ The /sessions modal: list the workspace's sessions, search them, and manage a
  row (rename, pin/unpin, archive/restore). It reads the titles and keywords
  Reply Metadata persists; it does not derive them. Opening a session is out of
  v1 (the driver seam). Modelled on TApprovalModal: dim, trap input, theme roles.
  See docs/features/Session_Management/Session_Modal_v1.SPEC.md. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.theme, hildegard.helper.tui.grapheme,
  hildegard.helper.fuzzy,
  hildegard.helper.session;

type
  { A row action; the host performs the store write and re-reads the rows. }
  TSessionAction = (saRename, saTogglePin, saToggleArchive);
  TSessionActionEvent = procedure(const ASessionId: string;
    AAction: TSessionAction) of object;
  TSessionRenameEvent = procedure(const ASessionId, ANewTitle: string) of object;

  TSessionsModal = class(TWidget)
  private
    FTheme: TTheme;
    FRows: TSessionRowArray;
    FCurrent: string;
    FSelected: Integer;
    FFilter: string;
    FShowArchived: Boolean;
    FRenaming: Boolean;
    FRenameText: string;
    FOnAction: TSessionActionEvent;
    FOnRename: TSessionRenameEvent;
    function Match(AIndex: Integer): Boolean;
    function VisibleRows: TArray<Integer>;
    function RowHeight: Integer;
    function InnerWidth: Integer;
    procedure MoveSelection(ADelta: Integer);
    function SelectedVisibleId: string;
    procedure FireAction(AAction: TSessionAction);
  public
    constructor Create(const ATheme: TTheme);
    { Replace the row set (already resolved: title, keywords, flags). }
    procedure SetRows(const ARows: TSessionRowArray);
    procedure SetCurrent(const ASessionId: string);
    { The number of rows that pass the current filter. }
    function VisibleCount: Integer;
    function SelectedSessionId: string;
    property ShowArchived: Boolean read FShowArchived write FShowArchived;
    property Filter: string read FFilter write FFilter;
    property Renaming: Boolean read FRenaming;
    property OnAction: TSessionActionEvent read FOnAction write FOnAction;
    property OnRename: TSessionRenameEvent read FOnRename write FOnRename;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

const
  { The dialog's minimum width and the chrome rows (borders + title + filter +
    footer). }
  SessionsMinWidth = 56;
  SessionsChromeRows = 5;

type
  { A footer hint: the keybinding (dimmed) and its action (normal), matching the
    approval modal's `enter accept   esc deny` convention. }
  TSessionsFooterHint = record
    Key: string;
    Action: string;
  end;

const
  SessionsFooter: array[0..4] of TSessionsFooterHint = (
    (Key: 'ctrl+p'; Action: ' pin'),
    (Key: 'ctrl+a'; Action: ' archive'),
    (Key: 'ctrl+r'; Action: ' rename'),
    (Key: 'ctrl+x'; Action: ' archived'),
    (Key: 'esc'; Action: ' close'));
  FooterGap = '   ';

function SessionsFooterWidth: Integer;

implementation

function SessionsFooterWidth: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := Low(SessionsFooter) to High(SessionsFooter) do
  begin
    if I > Low(SessionsFooter) then
      Inc(Result, StringWidth(UnicodeString(FooterGap)));
    Inc(Result, StringWidth(UnicodeString(SessionsFooter[I].Key)));
    Inc(Result, StringWidth(UnicodeString(SessionsFooter[I].Action)));
  end;
end;

constructor TSessionsModal.Create(const ATheme: TTheme);
begin
  inherited Create;
  FTheme := ATheme;
  FRows := nil;
  FSelected := 0;
end;

procedure TSessionsModal.SetRows(const ARows: TSessionRowArray);
begin
  FRows := ARows;
  if FSelected > VisibleCount - 1 then
    FSelected := VisibleCount - 1;
  if FSelected < 0 then
    FSelected := 0;
end;

procedure TSessionsModal.SetCurrent(const ASessionId: string);
begin
  FCurrent := ASessionId;
end;

function TSessionsModal.RowHeight: Integer;
begin
  Result := 1;   { one line per row: title, and keywords appended }
end;

function TSessionsModal.InnerWidth: Integer;
begin
  Result := FBounds.W - 4;
  if Result < 1 then
    Result := 1;
end;

function TSessionsModal.Match(AIndex: Integer): Boolean;
var
  I: Integer;
begin
  if FRows[AIndex].Archived and (not FShowArchived) then
    Exit(False);
  if FFilter = '' then
    Exit(True);
  Result := FuzzyMatches(FFilter, FRows[AIndex].Title) or
    FuzzyMatches(FFilter, FRows[AIndex].Id);
  if not Result then
    for I := 0 to High(FRows[AIndex].Keywords) do
      if FuzzyMatches(FFilter, FRows[AIndex].Keywords[I]) then
        Exit(True);
end;

function TSessionsModal.VisibleRows: TArray<Integer>;
var
  I, N: Integer;
begin
  Result := nil;
  N := 0;
  for I := 0 to High(FRows) do
    if Match(I) then
    begin
      SetLength(Result, N + 1);
      Result[N] := I;
      Inc(N);
    end;
end;

function TSessionsModal.VisibleCount: Integer;
begin
  Result := Length(VisibleRows);
end;

function TSessionsModal.SelectedVisibleId: string;
var
  V: TArray<Integer>;
begin
  Result := '';
  V := VisibleRows;
  if (FSelected >= 0) and (FSelected <= High(V)) then
    Result := FRows[V[FSelected]].Id;
end;

function TSessionsModal.SelectedSessionId: string;
begin
  Result := SelectedVisibleId;
end;

procedure TSessionsModal.MoveSelection(ADelta: Integer);
var
  N: Integer;
begin
  N := VisibleCount;
  if N = 0 then
    Exit;
  FSelected := FSelected + ADelta;
  if FSelected < 0 then
    FSelected := 0;
  if FSelected > N - 1 then
    FSelected := N - 1;
end;

procedure TSessionsModal.FireAction(AAction: TSessionAction);
var
  Id: string;
begin
  Id := SelectedVisibleId;
  if Id = '' then
    Exit;
  if Assigned(FOnAction) then
    FOnAction(Id, AAction);
end;

function TSessionsModal.Measure(const AAvail: TSize): TSize;
begin
  Result := Default(TSize);
  Result.W := SessionsMinWidth;
  { At least wide enough for the footer hints, plus the two border columns and
    the two inner pads. }
  if SessionsFooterWidth + 4 > Result.W then
    Result.W := SessionsFooterWidth + 4;
  if Result.W > AAvail.W then
    Result.W := AAvail.W;
  Result.H := VisibleCount * RowHeight + SessionsChromeRows;
  if Result.H > AAvail.H then
    Result.H := AAvail.H;
  if Result.H < SessionsChromeRows + 1 then
    Result.H := SessionsChromeRows + 1;
end;

function IfThenStr(ACond: Boolean; const ATrue, AFalse: string): string;
begin
  if ACond then
    Result := ATrue
  else
    Result := AFalse;
end;

procedure TSessionsModal.Render(const S: ISurface);
var
  L, R, T, B, X, Row, I, Idx, First, Shown, K: Integer;
  Bg, BorderAttr, TitleAttr, NormalAttr, MutedAttr, ActiveAttr, DimAttr: TAttr;
  V: TArray<Integer>;
  Line, Chips, Mark: UnicodeString;
begin
  if (FBounds.W < 4) or (FBounds.H < 4) then
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
  ActiveAttr := OnBg(FTheme.AccentSoft, FTheme.RaisedBg);
  DimAttr := OnBg(FTheme.Muted, FTheme.RaisedBg);

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
  for X := T + 1 to B - 1 do
  begin
    PutCh(S, L, X, '│', BorderAttr);
    PutCh(S, R, X, '│', BorderAttr);
  end;
  PutText(S, L + 2, T, ' Sessions ', TitleAttr);

  { The filter line. }
  if FRenaming then
    PutText(S, L + 2, T + 1, UnicodeString('rename: ' + FRenameText + '_'),
      ActiveAttr)
  else
    PutText(S, L + 2, T + 1,
      UnicodeString('filter: ' + FFilter +
        IfThenStr(FShowArchived, '   [archived shown]', '')), MutedAttr);

  V := VisibleRows;
  Shown := B - T - 4;   { rows between the filter and the footer }
  if Shown < 1 then
    Shown := 1;
  First := 0;
  if FSelected >= Shown then
    First := FSelected - Shown + 1;
  if Length(V) = 0 then
    PutText(S, L + 2, T + 2, '(no sessions)', MutedAttr);
  for I := 0 to Shown - 1 do
  begin
    Idx := First + I;
    if Idx > High(V) then
      Break;
    Row := T + 2 + I;
    Mark := '  ';
    if FRows[V[Idx]].Id = FCurrent then
      Mark := '» ';
    Line := Mark + UnicodeString(FRows[V[Idx]].Title);
    if Line = Mark then
      Line := Mark + UnicodeString(Copy(FRows[V[Idx]].Id, 1, 12));
    Chips := '';
    for K := 0 to High(FRows[V[Idx]].Keywords) do
    begin
      if K > 0 then
        Chips := Chips + ' · ';
      Chips := Chips + UnicodeString(FRows[V[Idx]].Keywords[K]);
    end;
    if FRows[V[Idx]].Pinned then
      Line := '★ ' + Line;
    if Idx = FSelected then
      PutText(S, L + 2, Row, Line, ActiveAttr)
    else if FRows[V[Idx]].Archived then
      PutText(S, L + 2, Row, Line, DimAttr)
    else
      PutText(S, L + 2, Row, Line, NormalAttr);
    if (Chips <> '') and (Idx <> FSelected) then
      PutText(S, L + 2 + StringWidth(Line) + 2, Row, Chips, MutedAttr);
  end;

  { Footer, right-aligned: keys dimmed, actions normal (the approval modal's
    convention). }
  Row := B - 1;
  X := R - 1 - StringWidth(UnicodeString(FooterGap)) - SessionsFooterWidth;
  if X < L + 2 then
    X := L + 2;
  for I := Low(SessionsFooter) to High(SessionsFooter) do
  begin
    if I > Low(SessionsFooter) then
      Inc(X, StringWidth(UnicodeString(FooterGap)));
    PutText(S, X, Row, UnicodeString(SessionsFooter[I].Key), DimAttr);
    Inc(X, StringWidth(UnicodeString(SessionsFooter[I].Key)));
    PutText(S, X, Row, UnicodeString(SessionsFooter[I].Action), NormalAttr);
    Inc(X, StringWidth(UnicodeString(SessionsFooter[I].Action)));
  end;
end;

function TSessionsModal.HandleEvent(const E: TInputEvent): Boolean;
var
  Id: string;
begin
  Result := True;
  if E.Kind <> ikKey then
    Exit(False);
  if FRenaming then
  begin
    if E.Key.Kind = kkEscape then
    begin
      FRenaming := False;
      Exit;
    end;
    if E.Key.Kind = kkEnter then
    begin
      Id := SelectedVisibleId;
      FRenaming := False;
      if (Id <> '') and Assigned(FOnRename) then
        FOnRename(Id, FRenameText);
      Exit;
    end;
    if E.Key.Kind = kkBackspace then
    begin
      if FRenameText <> '' then
        SetLength(FRenameText, Length(FRenameText) - 1);
      Exit;
    end;
    if (E.Key.Kind = kkChar) and (E.Key.Ch <> '') then
      FRenameText := FRenameText + string(E.Key.Ch);
    Exit;
  end;
  case E.Key.Kind of
    kkUp: MoveSelection(-1);
    kkDown: MoveSelection(1);
    kkPageUp: MoveSelection(-5);
    kkPageDown: MoveSelection(5);
    kkHome: FSelected := 0;
    kkEnd: FSelected := VisibleCount - 1;
    kkBackspace:
      if FFilter <> '' then
        SetLength(FFilter, Length(FFilter) - 1);
    kkChar:
      begin
        if E.Key.Ch = '' then
          Exit;
        { Actions are Ctrl-modified, so plain typing only filters (a stray 'a'
          while typing must not archive a session). }
        if moCtrl in E.Key.Mods then
        begin
          if (E.Key.Ch = 'p') or (E.Key.Ch = 'P') then
            FireAction(saTogglePin)
          else if (E.Key.Ch = 'a') or (E.Key.Ch = 'A') then
            FireAction(saToggleArchive)
          else if (E.Key.Ch = 'x') or (E.Key.Ch = 'X') then
            FShowArchived := not FShowArchived
          else if (E.Key.Ch = 'r') or (E.Key.Ch = 'R') then
          begin
            FRenaming := True;
            FRenameText := '';
          end
          else
            Result := False;
        end
        else
          FFilter := FFilter + string(E.Key.Ch);
      end;
  else
    Result := False;
  end;
end;

end.
