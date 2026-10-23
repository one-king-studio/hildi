program dashboard_mock;
{ A MOCK of the Board Dashboard: a separate binary that watches the workspace's
  message board and task list, and lets an operator post an announcement.

  This is deliberately a mock. It reads no store and posts nothing: the data
  below is the real content of this workspace's board and task list, pasted in
  so the layout can be judged. The point of the mock is the SHAPE - three zones,
  what each one answers, and where an operator's attention goes first - not the
  wiring, which is specified in docs/features/Board_Dashboard/FEATURE.md.

  Layout:
    +---------------------------+---------------------------------+
    | Sessions                  | Board (one topic)               |
    |  live / idle / done       |  entries, newest first          |
    |  turn title, elapsed      |  kind chip, title, linkage      |
    |---------------------------|  toc: open questions etc.       |
    | > announcement            |                                 |
    +---------------------------+---------------------------------+
    | Tasks: a kanban, one column per status                       |
    +--------------------------------------------------------------+

  Keys: Tab / Shift-Tab switch zone; arrows move; 'q' or Ctrl-C quits.

  Run: make dashboard-mock }

{$mode delphi}{$H+}{$codepage utf8}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}   // cthreads first; cwstring for Unicode
  SysUtils, Classes,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.app, hildegard.helper.tui.surface.video,
  hildegard.helper.tui.input.terminal, hildegard.helper.tui.theme;

const
  KanbanShare = 3;        // the task board takes ~1/3 of the height
  MinKanbanH = 9;
  MinTopH = 8;
  LeftShare = 3;          // sessions take ~1/3 of the width
  MinLeftW = 30;
  MaxLeftW = 44;
  ComposeH = 3;           // separator + prompt + hint
  SpinIntervalMs = 120;

type
  TZone = (zSessions, zBoard, zTasks);

  { One row of mock session state. State is what the store can answer cheaply;
    the turn title is what only the live socket can answer. }
  TSessionMock = record
    LabelText: string;
    Title: string;
    State: string;      // 'working' / 'idle' / 'done'
    Elapsed: string;
  end;

  TBoardMock = record
    Kind: string;
    Title: string;
    Meta: string;
    Link: string;
  end;

  { The whole dashboard is one widget. A mock does not need the widget kit's
    composition, and painting it directly keeps the layout legible in one file -
    which is the point. The real feature composes panels plus a kanban widget. }
  TDashboard = class(TWidget)
  private
    FTheme: TTheme;
    FZone: TZone;
    FSessSel, FBoardSel, FColSel, FCardSel: Integer;
    FSpin: Integer;
    FOrigin: Int64;
    procedure Frame(const S: ISurface; const ARect: TRect;
      const ATitle, ARight: UnicodeString; AFocused: Boolean);
    procedure Text(const S: ISurface; X, Y: Integer; const AText: UnicodeString;
      const AAttr: TAttr; AMaxW: Integer);
    procedure DrawSessions(const S: ISurface; const ARect: TRect);
    procedure DrawBoard(const S: ISurface; const ARect: TRect);
    procedure DrawTasks(const S: ISurface; const ARect: TRect);
    procedure DrawFooter(const S: ISurface; const ARect: TRect);
  public
    constructor Create(const ATheme: TTheme);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
  end;

const
  { Box drawing, from the design language's light family. }
  ChTL = '╭'; ChTR = '╮'; ChBL = '╰'; ChBR = '╯';
  ChH = '─'; ChV = '│'; ChDotted = '┈';
  ChCursor = '❯'; ChIdle = '○'; ChOk = '✓'; ChDot = '·';

  { Sessions in this workspace. 'working' only appears while a turn is open. }
  Sessions: array[0..3] of TSessionMock = (
    (LabelText: 'main'; Title: 'Board dashboard mock';
     State: 'working'; Elapsed: '2m 14s'),
    (LabelText: 'tasks'; Title: 'Claim recovery + boundary tests';
     State: 'idle'; Elapsed: '14m'),
    (LabelText: 'docs'; Title: 'The recorder stores its patch';
     State: 'done'; Elapsed: '41m'),
    (LabelText: 'review'; Title: 'Read-only: reviewing the diff';
     State: 'idle'; Elapsed: '1h 02m'));

  { The coordination topic, newest first - the real entries. }
  Board: array[0..5] of TBoardMock = (
    (Kind: 'answer'; Title: 'Correction: your answer did set reply_to';
     Meta: '2h'; Link: '-> #1'),
    (Kind: 'answer'; Title: 'Closed: lanes done, recorder keeps its patch';
     Meta: '2h'; Link: '-> #1'),
    (Kind: 'status'; Title: 'Four docs files uncommitted; commit them';
     Meta: '3h'; Link: ''),
    (Kind: 'status'; Title: 'Gate free: 1,784 green at 7eaf6e4';
     Meta: '3h'; Link: ''),
    (Kind: 'answer'; Title: 'Lanes A and B done; wiring test asserts nothing';
     Meta: '4h'; Link: '-> #2'),
    (Kind: 'answer'; Title: 'Lanes agreed: tasks.* is mine';
     Meta: '5h'; Link: '-> #1'));

  { A braille frame by index, so the spinner is a pure function of time - the
    app clock owns the cadence, the widget owns nothing. }
  SpinFrames: array[0..9] of UnicodeString =
    ('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏');

var
  { Set by the quit keys and read by the Run loop's stop condition. Declared
    here, after the consts, because a var may not interrupt the type section. }
  QuitRequested: Boolean;

{ A rect built inline; the toolkit assigns fields rather than offering a
  constructor, and a local helper keeps the layout arithmetic readable. }
function R(X, Y, W, H: Integer): TRect;
begin
  Result.X := X;
  Result.Y := Y;
  Result.W := W;
  Result.H := H;
end;

function KindAttr(const ATheme: TTheme; const AKind: string): TAttr;
begin
  if AKind = 'question' then Result := ATheme.Warn
  else if AKind = 'decision' then Result := ATheme.Success
  else if AKind = 'answer' then Result := ATheme.Accent
  else if AKind = 'finding' then Result := ATheme.Text
  else Result := ATheme.Muted;
end;

{ A fixed chip width keeps the titles in one column, which is what makes the
  list scannable - the design language's "columns stay consistent". }
function KindChip(const AKind: string): UnicodeString;
var
  I: Integer;
begin
  Result := UnicodeString('[' + AKind + ']');
  I := Length(AKind) + 2;
  while I < 9 do
  begin
    Result := Result + ' ';
    Inc(I);
  end;
end;

constructor TDashboard.Create(const ATheme: TTheme);
begin
  inherited Create;
  FTheme := ATheme;
  FZone := zBoard;
  FSessSel := 0;
  FBoardSel := 0;
  FColSel := 1;          // CLAIMED: where the operator's attention goes
  FCardSel := 0;
  FOrigin := 0;
  SetAnimation(SpinIntervalMs);
end;

function TDashboard.Measure(const AAvail: TSize): TSize;
begin
  Result.W := AAvail.W;
  Result.H := AAvail.H;
end;

function TDashboard.Animating: Boolean;
begin
  Result := True;    // the working-session spinner
end;

function TDashboard.Advance(const ANowMs: Int64): Boolean;
var
  NewIndex: Integer;
begin
  if FOrigin = 0 then
    FOrigin := ANowMs;
  if ANowMs <= FOrigin then
    NewIndex := 0
  else
    NewIndex := ((ANowMs - FOrigin) div SpinIntervalMs) mod 10;
  Result := NewIndex <> FSpin;
  FSpin := NewIndex;
end;

procedure TDashboard.Text(const S: ISurface; X, Y: Integer;
  const AText: UnicodeString; const AAttr: TAttr; AMaxW: Integer);
var
  I: Integer;
  C: TCell;
begin
  for I := 1 to Length(AText) do
  begin
    if (AMaxW > 0) and (I > AMaxW) then
      Break;
    C := Default(TCell);
    C.Ch := UnicodeString(AText[I]);
    C.Attr := AAttr;
    S.Put(X + I - 1, Y, C);
  end;
end;

procedure TDashboard.Frame(const S: ISurface; const ARect: TRect;
  const ATitle, ARight: UnicodeString; AFocused: Boolean);
var
  I: Integer;
  A: TAttr;
begin
  if (ARect.W < 2) or (ARect.H < 2) then
    Exit;
  { The focused zone gets the bright border: focus is never colour alone - the
    title also carries a cursor in the list below it. }
  if AFocused then
    A := FTheme.Accent
  else
    A := FTheme.Border;

  S.FillRect(ARect, FTheme.Panel);
  Text(S, ARect.X, ARect.Y, ChTL, A, 1);
  Text(S, ARect.X + ARect.W - 1, ARect.Y, ChTR, A, 1);
  Text(S, ARect.X, ARect.Y + ARect.H - 1, ChBL, A, 1);
  Text(S, ARect.X + ARect.W - 1, ARect.Y + ARect.H - 1, ChBR, A, 1);
  for I := ARect.X + 1 to ARect.X + ARect.W - 2 do
  begin
    Text(S, I, ARect.Y, ChH, A, 1);
    Text(S, I, ARect.Y + ARect.H - 1, ChH, A, 1);
  end;
  for I := ARect.Y + 1 to ARect.Y + ARect.H - 2 do
  begin
    Text(S, ARect.X, I, ChV, A, 1);
    Text(S, ARect.X + ARect.W - 1, I, ChV, A, 1);
  end;

  if ATitle <> '' then
    Text(S, ARect.X + 1, ARect.Y, ' ' + ATitle + ' ', A, ARect.W - 2);
  if ARight <> '' then
    Text(S, ARect.X + ARect.W - 1 - Length(ARight) - 1, ARect.Y,
      ' ' + ARight + ' ', A, ARect.W - 2);
end;

procedure TDashboard.DrawSessions(const S: ISurface; const ARect: TRect);
var
  I, Y, X0, Inner: Integer;
  A, ElapsedAttr: TAttr;
  Mark, Line: UnicodeString;
begin
  Frame(S, ARect, 'Sessions', 'live 2', FZone = zSessions);
  Inner := ARect.W - 4;
  X0 := ARect.X + 2;
  Y := ARect.Y + 1;
  for I := 0 to High(Sessions) do
  begin
    if Y >= ARect.Y + ARect.H - ComposeH then
      Break;
    if I = FSessSel then
    begin
      A := FTheme.Accent;
      S.FillRect(R(X0 - 1, Y, ARect.W - 2, 1), A);
      if FZone = zSessions then
        Include(A.Style, sfReverse);
      ElapsedAttr := A;
    end
    else
    begin
      A := FTheme.Text;
      ElapsedAttr := FTheme.Muted;
    end;

    { The mark: a spinner for a working session, a ring for idle, a tick for
      done. Motion is reserved for the one thing that actually moves. }
    if Sessions[I].State = 'working' then
      Mark := SpinFrames[FSpin]
    else if Sessions[I].State = 'idle' then
      Mark := ChIdle
    else if Sessions[I].State = 'done' then
      Mark := ChOk
    else
      Mark := ChDot;

    { A working session's title is the live turn; an idle one's is its last
      completed reply - the distinction the design cares about. }
    Line := Mark + ' ' + UnicodeString(Sessions[I].LabelText) + ' ' + ChDot +
      ' ' + UnicodeString(Sessions[I].Title);
    Text(S, X0, Y, Line, A, Inner - Length(Sessions[I].Elapsed) - 1);
    Text(S, X0 + Inner - Length(Sessions[I].Elapsed), Y,
      UnicodeString(Sessions[I].Elapsed), ElapsedAttr,
      Length(Sessions[I].Elapsed));
    Inc(Y);
  end;

  { The compose line: an operator's announcement is a board post attributed to
    the operator, not to an agent. }
  if ARect.H >= ComposeH + 5 then
  begin
    Y := ARect.Y + ARect.H - ComposeH;
    for I := ARect.X + 1 to ARect.X + ARect.W - 2 do
      Text(S, I, Y, ChDotted, FTheme.Border, 1);
    Text(S, X0, Y + 1, ChCursor + ' ', FTheme.Accent, 2);
    Text(S, X0 + 2, Y + 1, 'announce to coordination', FTheme.Muted, Inner);
    Text(S, X0 + 2, Y + 2, 'ctrl+n topic  enter post', FTheme.Muted, Inner);
  end;
end;

procedure TDashboard.DrawBoard(const S: ISurface; const ARect: TRect);
var
  I, Y, X0, Inner: Integer;
  A: TAttr;
  Line, Toc, Right: UnicodeString;
begin
  Right := 'q 0 ' + ChDot + ' d 0 ' + ChDot + ' f 0';
  Frame(S, ARect, 'Board ' + ChDot + ' coordination', Right, FZone = zBoard);
  Inner := ARect.W - 4;
  X0 := ARect.X + 2;
  Y := ARect.Y + 1;

  for I := 0 to High(Board) do
  begin
    if Y >= ARect.Y + ARect.H - 3 then
      Break;
    if I = FBoardSel then
    begin
      A := FTheme.Accent;
      S.FillRect(R(X0 - 1, Y, ARect.W - 2, 1), A);
      if FZone = zBoard then
        Include(A.Style, sfReverse);
    end
    else
      A := KindAttr(FTheme, Board[I].Kind);

    Line := KindChip(Board[I].Kind) + UnicodeString(Board[I].Title);
    Text(S, X0, Y, Line, A, Inner - Length(Board[I].Meta) - 1);
    Text(S, X0 + Inner - Length(Board[I].Meta), Y,
      UnicodeString(Board[I].Meta), FTheme.Muted, Length(Board[I].Meta));
    Inc(Y);
  end;

  { The footer states what a reader owes, not just what exists. }
  Toc := 'open questions 0 ' + ChDot + ' decisions 0 ' + ChDot +
    ' findings 0 ' + ChDot + ' all answered';
  Text(S, X0, ARect.Y + ARect.H - 2, Toc, FTheme.Muted, Inner);
end;

procedure TDashboard.DrawTasks(const S: ISurface; const ARect: TRect);
var
  I, Col, X, W, Y, Inner, ColW: Integer;
  A: TAttr;
  Titles: array[0..4] of string;
  Counts: array[0..4] of Integer;
  Cards: array[0..4, 0..1] of string;
  Holders: array[0..4, 0..1] of string;
  N: array[0..4] of Integer;
begin
  Frame(S, ARect, 'Tasks', '4 live ' + ChDot + ' 2 done', FZone = zTasks);

  N[0] := 1; N[1] := 1; N[2] := 0; N[3] := 2; N[4] := 0;
  Titles[0] := 'OPEN'; Titles[1] := 'CLAIMED'; Titles[2] := 'BLOCKED';
  Titles[3] := 'DONE'; Titles[4] := 'DROPPED';
  Counts[0] := 1; Counts[1] := 1; Counts[2] := 0; Counts[3] := 2; Counts[4] := 0;
  Cards[0, 0] := '#1  Wire RenewClaims into the session';

  Holders[0, 0] := 'unclaimed ' + ChDot + ' 12m';
  Cards[1, 0] := '#2  Record the claim-recovery deviation';
  Holders[1, 0] := 'sess-main ' + ChDot + ' 3m';
  Cards[3, 0] := '#3  Correct the stale test-count claims';
  Holders[3, 0] := 'sess-docs ' + ChOk;
  Cards[3, 1] := '#4  Mock the board dashboard';
  Holders[3, 1] := 'sess-main ' + ChOk;

  ColW := (ARect.W - 2) div 5;
  if ColW < 8 then
    Exit;
  for Col := 0 to 4 do
  begin
    X := ARect.X + 1 + Col * ColW;
    W := ColW - 1;
    Inner := W - 2;

    { The column header: name, count, and a rule that makes the column read as
      a stack rather than a table row. }
    if (Col = FColSel) and (FZone = zTasks) then
      A := FTheme.Accent
    else
      A := FTheme.Title;
    Text(S, X, ARect.Y + 1, UnicodeString(Titles[Col] + ' ' +
      IntToStr(Counts[Col])), A, Inner);
    for I := X to X + W - 1 do
      Text(S, I, ARect.Y + 2, ChDotted, FTheme.Border, 1);

    { Cards. A card is a bordered box: the border is what makes it a thing you
      could pick up and move, which is the kanban affordance. }
    Y := ARect.Y + 4;
    for I := 0 to N[Col] - 1 do
    begin
      if Y + 3 > ARect.Y + ARect.H - 1 then
        Break;
      Frame(S, R(X, Y, W, 3), '', '', False);
      if (Col = FColSel) and (I = FCardSel) and (FZone = zTasks) then
        A := FTheme.Accent
      else
        A := FTheme.Text;
      Text(S, X + 1, Y + 1, UnicodeString(Cards[Col, I]), A, W - 2);
      Text(S, X + 1, Y + 2, UnicodeString(Holders[Col, I]), FTheme.Muted,
        W - 2);
      Inc(Y, 4);
    end;

    if N[Col] = 0 then
      Text(S, X + 1, ARect.Y + 4, '--', FTheme.Muted, Inner);
  end;
end;

procedure TDashboard.DrawFooter(const S: ISurface; const ARect: TRect);
begin
  S.FillRect(ARect, FTheme.Panel);
  Text(S, ARect.X, ARect.Y, 'MOCK ' + ChDot + ' reads nothing, writes nothing' +
    '   ' + ChDot + '   tab zone  arrows move  q quit', FTheme.Muted, ARect.W);
end;

procedure TDashboard.Render(const S: ISurface);
var
  W, H, TopH, KanbanH, LeftW: Integer;
  SessionsRect, BoardRect, TasksRect, FooterRect: TRect;
begin
  W := FBounds.W;
  H := FBounds.H;
  if (W <= 0) or (H <= 0) then
    Exit;

  S.FillRect(FBounds, FTheme.Base);

  FooterRect := R(0, H - 1, W, 1);
  KanbanH := H div KanbanShare;
  if KanbanH < MinKanbanH then
    KanbanH := MinKanbanH;
  TopH := H - 1 - KanbanH;
  if TopH < MinTopH then
  begin
    TopH := MinTopH;
    KanbanH := H - 1 - TopH;
  end;

  LeftW := W div LeftShare;
  if LeftW < MinLeftW then LeftW := MinLeftW;
  if LeftW > MaxLeftW then LeftW := MaxLeftW;
  if LeftW > W - 24 then LeftW := W - 24;
  if LeftW < 10 then LeftW := 10;

  SessionsRect := R(0, 0, LeftW, TopH);
  BoardRect := R(LeftW, 0, W - LeftW, TopH);
  TasksRect := R(0, TopH, W, KanbanH);

  DrawSessions(S, SessionsRect);
  DrawBoard(S, BoardRect);
  DrawTasks(S, TasksRect);
  DrawFooter(S, FooterRect);
end;

function TDashboard.HandleEvent(const E: TInputEvent): Boolean;
var
  Shift: Boolean;
begin
  if E.Kind <> ikKey then
    Exit(False);
  Result := True;

  if (E.Key.Kind = kkChar) and
    (((moCtrl in E.Key.Mods) and ((E.Key.Ch = 'c') or (E.Key.Ch = 'd'))) or
     ((E.Key.Mods = []) and (E.Key.Ch = 'q'))) then
  begin
    QuitRequested := True;
    Exit;
  end;

  Shift := moShift in E.Key.Mods;
  if E.Key.Kind = kkTab then
  begin
    if Shift then
    begin
      case FZone of
        zSessions: FZone := zTasks;
        zBoard: FZone := zSessions;
        zTasks: FZone := zBoard;
      end;
    end
    else
    begin
      case FZone of
        zSessions: FZone := zBoard;
        zBoard: FZone := zTasks;
        zTasks: FZone := zSessions;
      end;
    end;
    Exit;
  end;

  case E.Key.Kind of
    kkUp:
      case FZone of
        zSessions: if FSessSel > 0 then Dec(FSessSel);
        zBoard: if FBoardSel > 0 then Dec(FBoardSel);
        zTasks: if FCardSel > 0 then Dec(FCardSel);
      end;
    kkDown:
      case FZone of
        zSessions: if FSessSel < High(Sessions) then Inc(FSessSel);
        zBoard: if FBoardSel < High(Board) then Inc(FBoardSel);
        zTasks: if FCardSel < 1 then Inc(FCardSel);
      end;
    kkLeft:
      if FZone = zTasks then
      begin
        if FColSel > 0 then Dec(FColSel);
        FCardSel := 0;
      end;
    kkRight:
      if FZone = zTasks then
      begin
        if FColSel < 4 then Inc(FColSel);
        FCardSel := 0;
      end;
    kkEscape: QuitRequested := True;
  else
    Result := False;
  end;
end;

var
  Surface: ISurface;
  InputTerm: TInputSourceTerminal;
  Input: IInputSource;
  Theme: TTheme;
  Dash: TDashboard;
  App: TTuiApp;

function ShouldStop: Boolean;
begin
  Result := QuitRequested or InputTerm.Terminated;
end;

begin
  QuitRequested := False;
  Surface := TSurfaceVideo.Create;
  InputTerm := TInputSourceTerminal.Create;
  Input := InputTerm;
  Theme := DarkTheme;

  Dash := TDashboard.Create(Theme);
  App := TTuiApp.Create(Surface, Input, Dash);
  try
    App.Run(@ShouldStop);
  finally
    App.Free;
    Dash.Free;
    Input := nil;
    Surface := nil;
  end;
end.
