unit hildi.dashboard.panel;
{ The Board Dashboard's widget: three zones over a workspace's coordination
  state. It reads no store itself - a host fills the data with SetData/InitData
  and draws it - so the same panel serves the real binary and the layout mock.

  Layout:
    +--------------------------------------------------------------+
    | Tasks - a kanban, ~60% of the height                          |
    |  OPEN | CLAIMED | BLOCKED | DONE | DROPPED                    |
    |  each lane scrolls on its own; a border separates the lanes   |
    +--------------------------------------------------------------+
    | Channels   | Messages                                         |
    |  live feed |  the live feed is EVERY topic (default view);    |
    |  # topic   |  picking a channel filters to that topic         |
    +--------------------------------------------------------------+
    | open questions N . decisions N . findings N . <state>         |
    +--------------------------------------------------------------+

  Why tasks on top: the kanban is the thing an operator scans for "what is
  happening", so it gets the eye-line and the majority of the height. Sessions
  moved into the channel list, where they already are - a session works on a
  topic.

  Keys: Tab / Shift-Tab switch zone; arrows move; PgUp/PgDn scroll a lane;
        'q' or Ctrl-C quits. Escape does NOT quit - it is the universal "back
        out of this" key, and quitting on it lost the dashboard to a reflexive
        press.

  Run: make dashboard-mock }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  {$ifdef unix}cthreads, cwstring,{$endif}   // cthreads first; cwstring for Unicode
  SysUtils, Classes, DateUtils,
  tui.base, tui.input,
  tui.surface, tui.widget,
  tui.app, tui.surface.video,
  tui.input.terminal, tui.theme;

const
  TasksPercent = 60;      // the kanban takes 60% of the height
  MinTasksH = 8;
  ChanW = 22;             // the channel list's width
  MinMsgH = 4;
  SpinIntervalMs = 120;
  LaneCount = 5;
  { No gutter between stacked cards: the cards sit flush, so the eye reads one
    column of content rather than a series of separated objects. }
  CardPad = 0;
  { Horizontal padding inside a card, each side. Content starts at CardPadX and
    the wrap width gives up twice that. }
  CardPadX = 1;

type
  TZone = (zTasks, zChannels, zMessages);

  TCardMock = record
    Id: string;
    Title: string;
    Holder: string;
  end;
  TCardArray = array of TCardMock;

  TBoardMock = record
    Kind: string;
    Author: string;
    Topic: string;
    Title: string;
    Meta: string;
    Link: string;
  end;
  TBoardArray = array of TBoardMock;

  TChanMock = record
    Name: string;         // '' => the live feed (every topic)
    Unread: Integer;
  end;
  TChanArray = array of TChanMock;

  TWrapArray = array of UnicodeString;

  { A host's data refresh: refill the panel's globals, return True when what is
    on screen would actually differ (so the panel only repaints on a change).
    A plain function pointer: the host's data is globals or captured state, and
    requiring an object method would force a holder class for no gain. }
  TDashboardRefresh = function: Boolean;

  { The whole dashboard is one widget. A mock does not need the widget kit's
    composition, and painting it directly keeps the layout legible in one file -
    which is the point. The real feature composes panels plus a kanban widget. }
  TDashboard = class(TWidget)
  private
    FTheme: TTheme;
    FZone: TZone;
    FLane: Integer;
    FCard: array[0..LaneCount - 1] of Integer;
    FScroll: array[0..LaneCount - 1] of Integer;
    FChanSel: Integer;
    FMsgSel: Integer;
    FMsgScroll: Integer;
    FSpin: Integer;
    FOrigin: Int64;
    FOnPoll: TDashboardRefresh;
    FPollMs: Integer;
    FLastPoll: Int64;
    FHasPolled: Boolean;
    FReadAt: Int64;       // epoch secs of the last data fill, for the age chip
    procedure Frame(const S: ISurface; const ARect: TRect;
      const ATitle, ARight: UnicodeString; AFocused: Boolean);
    { A frame with explicit border and fill attributes, for surfaces that are
      not plain panels: a card sits on a raised (lighter) background, and the
      focused card's BORDER takes the accent while its content does not. }
    procedure FrameEx(const S: ISurface; const ARect: TRect;
      const ATitle, ARight: UnicodeString;
      const ABorder, AFill: TAttr);
    procedure Text(const S: ISurface; X, Y: Integer; const AText: UnicodeString;
      const AAttr: TAttr; AMaxW: Integer);
    procedure VLine(const S: ISurface; X, Y0, Y1: Integer;
      const AAttr: TAttr);
    procedure DrawTasks(const S: ISurface; const ARect: TRect);
    procedure DrawChannels(const S: ISurface; const ARect: TRect);
    procedure DrawMessages(const S: ISurface; const ARect: TRect);
    procedure DrawStatus(const S: ISurface; const ARect: TRect);
    function StatsLine: UnicodeString;
    procedure EnsureVisible(ALane, AVisH, AInnerW: Integer);
    { BLOCKED and DROPPED are optional columns: empty ones are not drawn, so
      navigation must skip them or the selection lands on nothing. }
    function LaneVisible(ALane: Integer): Boolean;
    procedure MoveLane(ADelta: Integer);
  public
    constructor Create(const ATheme: TTheme);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;

    { Near-realtime reading. The panel owns the CLOCK and the STALENESS rule;
      the host owns the store, so it supplies a callback that refills the data
      globals and returns whether anything actually changed. The panel calls it
      at most once per APollMs, and only when the app ticks.

      This keeps the panel free of any store unit - the same reason the mock can
      drive it with static data. }
    procedure SetPoll(AIntervalMs: Integer; ARefresh: TDashboardRefresh);
    { Called by a host after it has filled the data, so the age chip is honest. }
    procedure MarkRead(AEpochSec: Int64);
    property ReadAt: Int64 read FReadAt;
  end;

const
  { Box drawing, from the design language's light family. }
  ChTL = '╭'; ChTR = '╮'; ChBL = '╰'; ChBR = '╯';
  ChH = '─'; ChV = '│'; ChDotted = '┈';
  ChCursor = '❯'; ChIdle = '○'; ChOk = '✓'; ChDot = '·';
  ChUp = '▲'; ChDown = '▼'; ChHash = '#';

  { A braille frame by index, so the spinner is a pure function of time - the
    app clock owns the cadence, the widget owns nothing. }
  SpinFrames: array[0..9] of UnicodeString =
    ('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏');

var
  { Set by the quit keys and read by the Run loop's stop condition. Declared
    here, after the consts, because a var may not interrupt the type section. }
  QuitRequested: Boolean;

  Lanes: array[0..LaneCount - 1] of TCardArray;
  LaneTitles: array[0..LaneCount - 1] of string;
  Board: TBoardArray;
  Chans: TChanArray;

{ Fill the globals above with a static workspace's shape. The mock calls this
  so it needs no store; the real binary fills the same globals from the store
  instead, and draws through the one panel implementation either way. }
procedure InitData;

{ Render one frame to stdout as plain lines. No terminal is opened, so this
  works over a pipe - the way a real binary gets verified without a tty. }
procedure DumpFrame(AWidth, AHeight: Integer);

implementation

function R(X, Y, W, H: Integer): TRect;
begin
  Result.X := X;
  Result.Y := Y;
  Result.W := W;
  Result.H := H;
end;

procedure AddCard(var ALane: TCardArray; const AId, ATitle, AHolder: string);
begin
  SetLength(ALane, Length(ALane) + 1);
  ALane[High(ALane)].Id := AId;
  ALane[High(ALane)].Title := ATitle;
  ALane[High(ALane)].Holder := AHolder;
end;

procedure AddEntry(const AKind, AAuthor, ATopic, ATitle, AMeta, ALink: string);
begin
  SetLength(Board, Length(Board) + 1);
  Board[High(Board)].Kind := AKind;
  Board[High(Board)].Author := AAuthor;
  Board[High(Board)].Topic := ATopic;
  Board[High(Board)].Title := ATitle;
  Board[High(Board)].Meta := AMeta;
  Board[High(Board)].Link := ALink;
end;

procedure AddChan(const AName: string; AUnread: Integer);
begin
  SetLength(Chans, Length(Chans) + 1);
  Chans[High(Chans)].Name := AName;
  Chans[High(Chans)].Unread := AUnread;
end;

{ The mock's data: the real shape of this workspace's task list and board.
  Card TITLES are deliberately of mixed length so the wrap path is exercised -
  a uniform one-line card would hide exactly the bug this layout can have. }
procedure InitData;
begin
  LaneTitles[0] := 'OPEN';
  LaneTitles[1] := 'CLAIMED';
  LaneTitles[2] := 'BLOCKED';
  LaneTitles[3] := 'DONE';
  LaneTitles[4] := 'DROPPED';

  SetLength(Lanes[0], 0);
  AddCard(Lanes[0], '#8', 'Tier C: ln/readlink/chmod need new FS primitives',
    'unclaimed ' + ChDot + ' 12m');

  SetLength(Lanes[1], 0);
  AddCard(Lanes[1], '#10',
    'Board Dashboard: settle the two open design questions and render the mock',
    'sess-main ' + ChDot + ' 3m');
  AddCard(Lanes[1], '#13',
    'Cursor honesty: last_seen_at, >=N unread, new-session-current, revival notice',
    'sess-main ' + ChDot + ' 8m');
  AddCard(Lanes[1], '#14',
    'Conditional coordination: cross-session unread + mode-transition notices',
    'sess-docs ' + ChDot + ' 21m');

  SetLength(Lanes[2], 0);
  AddCard(Lanes[2], '#9', 'Operator identity has no session to attribute to',
    'blocked on #10');

  SetLength(Lanes[3], 0);
  AddCard(Lanes[3], '#6', '$() expressions must be visible in the approval dialog',
    'sess-main ' + ChOk);
  AddCard(Lanes[3], '#7', 'Coarse-grained approval buckets by effect class',
    'sess-tasks ' + ChOk);
  AddCard(Lanes[3], '#12', 'Split TUI into core and widgets',
    'sess-main ' + ChOk);

  SetLength(Lanes[4], 0);

  SetLength(Board, 0);
  AddEntry('answer', 'tasks', 'coordination',
    'Correction: your answer did set reply_to', '2h', '-> #1');
  AddEntry('answer', 'docs', 'coordination',
    'Closed: lanes done, recorder keeps its patch', '2h', '-> #1');
  AddEntry('status', 'main', 'coordination',
    'Four docs files uncommitted; commit them', '3h', '');
  AddEntry('status', 'tasks', 'coordination',
    'Gate free: 1,784 green at 7eaf6e4', '3h', '');
  AddEntry('decision', 'main', 'tui-split',
    'Core keeps tui.*, widgets take tui.widgets.*', '5h', '');
  AddEntry('finding', 'main', 'tui-split',
    'test_split would have gone silently vacuous', '5h', '');
  AddEntry('question', 'docs', 'dashboard',
    'Should the feed be the default view?', '6h', '');
  AddEntry('status', 'main', 'dashboard',
    'Layout mock rendered headlessly at last', '7h', '');

  SetLength(Chans, 0);
  AddChan('', 0);                    // the live feed: every topic
  AddChan('coordination', 0);
  AddChan('tui-split', 2);
  AddChan('dashboard', 1);
end;

{ A lane header's colour encodes what the lane MEANS, so the header reads
  before the label does: OPEN is plain and slightly dim, CLAIMED is the amber
  of work in flight, BLOCKED is a dull red (not Error - it is a warning, not a
  failure), DONE is the same cool green the message pane uses for success, and
  DROPPED is muted because nothing lives there. }
function LaneHeadAttr(const ATheme: TTheme; ALane: Integer): TAttr;
begin
  case ALane of
    0: Result := ATheme.Muted;                        // OPEN - plain, dimmed
    1: Result := ATheme.Warn;                         // CLAIMED - amber
    { WithStyle ADDS flags (Result.Style + AStyle); it cannot remove one. Error
      carries sfBold, and bold red reads as a fault in the dashboard itself
      rather than a caution in the work, so the flag is excluded directly. }
    2: begin
         Result := ATheme.Error;
         Exclude(Result.Style, sfBold);
       end;
    3: Result := ATheme.Success;                      // DONE - cool green
  else
    Result := ATheme.Muted;                           // DROPPED - muted
  end;
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
{ A fixed chip width keeps the titles in one column, which is what makes the
  list scannable - the design language's "columns stay consistent". The width
  must clear the LONGEST kind ('decision' and 'question' are 10 chars with
  brackets): padding only to 9 left those two with no gap before the author,
  and the first render showed `[decision]main`. }
function KindChip(const AKind: string): UnicodeString;
const
  ChipW = 11;
var
  I: Integer;
begin
  Result := UnicodeString('[' + AKind + ']');
  I := Length(AKind) + 2;
  while I < ChipW do
  begin
    Result := Result + ' ';
    Inc(I);
  end;
end;

{ Word-wrap to AWidth columns. A word longer than the width is hard-broken
  rather than dropped: a task title is content, and silently vanishing text is
  worse than an ugly break. Always returns at least one line, so a caller can
  treat an empty title as a one-line card. }
function WrapLines(const AText: UnicodeString; AWidth: Integer): TWrapArray;
var
  Rest: UnicodeString;
  Space, I: Integer;
begin
  Result := nil;
  SetLength(Result, 0);
  if AWidth < 1 then
    AWidth := 1;
  Rest := AText;
  while Rest <> '' do
  begin
    if Length(Rest) <= AWidth then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Rest;
      Break;
    end;
    Space := 0;
    for I := AWidth downto 1 do
      if Rest[I] = ' ' then
      begin
        Space := I;
        Break;
      end;
    SetLength(Result, Length(Result) + 1);
    if Space = 0 then
    begin
      Result[High(Result)] := Copy(Rest, 1, AWidth);
      Rest := Copy(Rest, AWidth + 1, Length(Rest));
    end
    else
    begin
      Result[High(Result)] := Copy(Rest, 1, Space - 1);
      Rest := Copy(Rest, Space + 1, Length(Rest));
    end;
  end;
  if Length(Result) = 0 then
  begin
    SetLength(Result, 1);
    Result[0] := '';
  end;
end;

{ A card's height is a function of its wrapped title: 2 border rows + one
  title row per wrapped line + 1 holder row. This is why cards resize instead
  of being clipped to a fixed box. }
function CardHeight(const ACard: TCardMock; AInnerW: Integer): Integer;
begin
  Result := 2 + Length(WrapLines(UnicodeString(ACard.Title), AInnerW)) + 1;
end;

constructor TDashboard.Create(const ATheme: TTheme);
var
  I: Integer;
begin
  inherited Create;
  FTheme := ATheme;
  FZone := zTasks;
  FLane := 1;            // CLAIMED: where the operator's attention goes
  for I := 0 to LaneCount - 1 do
  begin
    FCard[I] := 0;
    FScroll[I] := 0;
  end;
  FChanSel := 0;         // the live feed
  FMsgSel := 0;
  FMsgScroll := 0;
  FOrigin := 0;
  FOnPoll := nil;
  FPollMs := 0;
  FLastPoll := 0;
  FHasPolled := False;
  FReadAt := 0;
  SetAnimation(SpinIntervalMs);
end;

procedure TDashboard.SetPoll(AIntervalMs: Integer; ARefresh: TDashboardRefresh);
begin
  FOnPoll := ARefresh;
  FPollMs := AIntervalMs;
  FLastPoll := 0;
  FHasPolled := False;   // poll on the next tick, so the first frame is current
end;

procedure TDashboard.MarkRead(AEpochSec: Int64);
begin
  FReadAt := AEpochSec;
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
  Changed: Boolean;
begin
  if FOrigin = 0 then
    FOrigin := ANowMs;
  if ANowMs <= FOrigin then
    NewIndex := 0
  else
    NewIndex := ((ANowMs - FOrigin) div SpinIntervalMs) mod 10;
  { The spinner changing is a repaint; so is the store returning new data. }
  Changed := NewIndex <> FSpin;
  FSpin := NewIndex;

  { Poll at most once per interval, and never more often than the app ticks.
    A poll that reports a change forces a repaint; one that does not is free.

    FHasPolled is a separate flag, NOT `FLastPoll = 0`: the app's clock can
    legitimately be 0 on the first tick, so a 0 sentinel made the first two
    ticks both poll. The throttle test caught that. }
  if (@FOnPoll <> nil) and (FPollMs > 0) then
  begin
    if (not FHasPolled) or (ANowMs - FLastPoll >= FPollMs) then
    begin
      FHasPolled := True;
      FLastPoll := ANowMs;
      if FOnPoll() then
        Changed := True;
    end;
  end;

  Result := Changed;
end;

procedure TDashboard.Text(const S: ISurface; X, Y: Integer;
  const AText: UnicodeString; const AAttr: TAttr; AMaxW: Integer);
var
  I: Integer;
  C: TCell;
  N: Integer;
begin
  { Truncation carries an ellipsis. Cutting a title mid-word with no mark made
    a real board read `...stale branche` - indistinguishable from a title that
    genuinely ends there. One cell is reserved for the mark. }
  N := Length(AText);
  if (AMaxW > 0) and (N > AMaxW) then
    N := AMaxW;
  for I := 1 to N do
  begin
    if (AMaxW > 0) and (I > AMaxW) then
      Break;
    { The last cell before the cut becomes the ellipsis, so a truncated line
      still reports its whole width and the reader sees it was cut. }
    if (AMaxW > 1) and (Length(AText) > AMaxW) and (I = AMaxW) then
    begin
      C := Default(TCell);
      C.Ch := '…';
      C.Attr := AAttr;
      S.Put(X + I - 1, Y, C);
      Break;
    end;
    C := Default(TCell);
    C.Ch := UnicodeString(AText[I]);
    C.Attr := AAttr;
    S.Put(X + I - 1, Y, C);
  end;
end;

procedure TDashboard.VLine(const S: ISurface; X, Y0, Y1: Integer;
  const AAttr: TAttr);
var
  Y: Integer;
begin
  for Y := Y0 to Y1 do
    Text(S, X, Y, ChV, AAttr, 1);
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
  { The right label must stop one cell short of the corner or it overwrites it -
    the first headless render showed `live 2 ╭`, with the corner gone. Skip it
    entirely when the frame is too narrow to hold a label and both corners. }
  if (ARight <> '') and (ARect.W >= Length(ARight) + 6) then
    Text(S, ARect.X + ARect.W - Length(ARight) - 3, ARect.Y,
      ' ' + ARight + ' ', A, Length(ARight) + 2);
end;

procedure TDashboard.FrameEx(const S: ISurface; const ARect: TRect;
  const ATitle, ARight: UnicodeString; const ABorder, AFill: TAttr);
var
  I: Integer;
begin
  if (ARect.W < 2) or (ARect.H < 2) then
    Exit;
  S.FillRect(ARect, AFill);
  Text(S, ARect.X, ARect.Y, ChTL, ABorder, 1);
  Text(S, ARect.X + ARect.W - 1, ARect.Y, ChTR, ABorder, 1);
  Text(S, ARect.X, ARect.Y + ARect.H - 1, ChBL, ABorder, 1);
  Text(S, ARect.X + ARect.W - 1, ARect.Y + ARect.H - 1, ChBR, ABorder, 1);
  for I := ARect.X + 1 to ARect.X + ARect.W - 2 do
  begin
    Text(S, I, ARect.Y, ChH, ABorder, 1);
    Text(S, I, ARect.Y + ARect.H - 1, ChH, ABorder, 1);
  end;
  for I := ARect.Y + 1 to ARect.Y + ARect.H - 2 do
  begin
    Text(S, ARect.X, I, ChV, ABorder, 1);
    Text(S, ARect.X + ARect.W - 1, I, ChV, ABorder, 1);
  end;
  if (ATitle <> '') and (ARect.W >= Length(ATitle) + 4) then
    Text(S, ARect.X + 1, ARect.Y, ' ' + ATitle + ' ', ABorder, ARect.W - 2);
  if (ARight <> '') and (ARect.W >= Length(ARight) + 6) then
    Text(S, ARect.X + ARect.W - Length(ARight) - 3, ARect.Y,
      ' ' + ARight + ' ', ABorder, Length(ARight) + 2);
end;

{ The kanban. One frame around all five lanes, with a vertical rule between
  lanes rather than a box each: a box per lane doubles the border weight and
  reads as five panels instead of one board. Each lane scrolls on its own, so a
  long lane and an empty one can coexist without the empty one wasting rows. }
procedure TDashboard.DrawTasks(const S: ISurface; const ARect: TRect);
var
  L, I, J, X, Y, LaneW, InnerW, CardH, VisTop, VisBot, Total, Sel,
    LaneX, VisCount, K, Wrapped: Integer;
  A, CardFill, CardBorder, LaneFill, LaneHead: TAttr;
  BandBg: Byte;
  Lines: TWrapArray;
  Right: UnicodeString;
  Active: array[0..LaneCount - 1] of Integer;
  Live, Done: Integer;
begin
  Live := Length(Lanes[0]) + Length(Lanes[1]) + Length(Lanes[2]);
  Done := Length(Lanes[3]);
  Right := UnicodeString(IntToStr(Live)) + ' live ' + ChDot + ' ' +
    UnicodeString(IntToStr(Done)) + ' done';
  Frame(S, ARect, 'Tasks', Right, FZone = zTasks);

  if (ARect.W < 12) or (ARect.H < 5) then
    Exit;

  { BLOCKED and DROPPED are optional: an empty BLOCKED lane is good news and
    an empty DROPPED lane is the normal case, so neither should hold a column
    of screen hostage. The three working lanes are always shown. }
  VisCount := 0;
  for L := 0 to LaneCount - 1 do
    if (L <> 2) and (L <> 4) or (Length(Lanes[L]) > 0) then
    begin
      Active[VisCount] := L;
      Inc(VisCount);
    end;

  LaneW := (ARect.W - 2) div VisCount;
  if LaneW < 8 then
    Exit;

  VisTop := ARect.Y + 2;                    // first row a card may occupy
  VisBot := ARect.Y + ARect.H - 2;          // last row a card may occupy

  { Lanes share the board's own background, EXCEPT the focused lane, which sits
    one shade darker - that is the active-lane highlight, and it is the only
    thing that tints the lane. The lane HEADER band sits at the card's own
    shade (RaisedBg) on every lane: the band marks the boundary between header
    and cards, so no rule row is needed and that row goes back to the cards. }
  CardFill := OnBg(FTheme.Panel, FTheme.RaisedBg);

  for K := 0 to VisCount - 1 do
  begin
    L := Active[K];
    LaneX := ARect.X + 1 + K * LaneW;
    InnerW := LaneW - 1;
    Total := Length(Lanes[L]);

    if (L = FLane) and (FZone = zTasks) then
      LaneFill := OnBg(FTheme.Panel, FTheme.SunkenBg)
    else
      LaneFill := FTheme.Panel;
    { The band sits at the card's own shade, not above it: a brighter band drew
      the eye to the header strip instead of the cards under it. The colour
      change between band and lane is what marks the boundary. }
    BandBg := FTheme.RaisedBg;
    LaneHead := OnBg(LaneHeadAttr(FTheme, L), BandBg);

    { The lane track: fill the column first, so cards sit on it. }
    for Y := ARect.Y + 1 to ARect.Y + ARect.H - 2 do
      S.FillRect(R(LaneX, Y, InnerW, 1), LaneFill);

    { The header band: the full lane width on the header row, so the title and
      the scroll arrows sit ON a bar rather than floating. }
    S.FillRect(R(LaneX, ARect.Y + 1, InnerW, 1), OnBg(FTheme.Panel, BandBg));

    { The lane header: padded off the lane's left edge, name and count. }
    Text(S, LaneX + 1, ARect.Y + 1, UnicodeString(LaneTitles[L] + ' ' +
      IntToStr(Total)), LaneHead, InnerW - 2);

    { Scroll affordance, in the header's right edge, so a clipped lane says so
      rather than looking complete. }
    if FScroll[L] > 0 then
      Text(S, LaneX + InnerW - 2, ARect.Y + 1, ChUp, LaneHead, 1);
    if Total > 0 then
    begin
      Y := VisTop;
      I := FScroll[L];
      while (I < Total) and (Y <= VisBot) do
      begin
        Inc(Y, CardHeight(Lanes[L][I], InnerW - 1 - 2 * CardPadX) + CardPad);
        Inc(I);
      end;
      if I < Total then
        Text(S, LaneX + InnerW - 1, ARect.Y + 1, ChDown, LaneHead, 1);
    end;

    { Cards, from the lane's scroll offset. Height is computed from the wrapped
      title, so every card is exactly as tall as its content. }
    Y := VisTop;
    I := FScroll[L];
    while I < Total do
    begin
      Wrapped := InnerW - 1 - 2 * CardPadX;
      CardH := CardHeight(Lanes[L][I], Wrapped);
      if Y + CardH - 1 > VisBot then
        Break;
      Sel := FCard[L];
      { The selected card takes the accent on its BORDER only. Its content stays
        the ordinary text colour: a full inverse or accent block is gaudy, and
        the border alone is enough to say "this one". }
      if (L = FLane) and (I = Sel) and (FZone = zTasks) then
      begin
        CardBorder := OnBg(FTheme.Accent, FTheme.RaisedBg);
        A := OnBg(FTheme.Text, FTheme.RaisedBg);
      end
      else
      begin
        CardBorder := OnBg(FTheme.Border, FTheme.RaisedBg);
        A := OnBg(FTheme.Text, FTheme.RaisedBg);
      end;

      FrameEx(S, R(LaneX, Y, InnerW, CardH), UnicodeString(Lanes[L][I].Id),
        '', CardBorder, CardFill);

      { Content is inset by CardPadX on both sides - the padding that makes a
        card readable - so the id, the wrapped title and the holder all align. }
      Lines := WrapLines(UnicodeString(Lanes[L][I].Title), Wrapped);
      for J := 0 to High(Lines) do
        Text(S, LaneX + 1 + CardPadX, Y + 1 + J, Lines[J], A, Wrapped);
      Text(S, LaneX + 1 + CardPadX, Y + CardH - 2,
        UnicodeString(Lanes[L][I].Holder), OnBg(FTheme.Muted, FTheme.RaisedBg),
        Wrapped);
      Inc(Y, CardH + CardPad);
      Inc(I);
    end;

    { The rule between lanes, never after the last one. It is always the plain
      border: the focused lane is signalled by its own darker fill, so colouring
      the divider too would say the same thing twice and read as noise. }
    if K < VisCount - 1 then
      VLine(S, LaneX + LaneW - 1, ARect.Y + 1, ARect.Y + ARect.H - 2,
        FTheme.Border);
  end;
end;

{ The channel list: the live feed first, then one row per topic. Picking a row
  filters the message pane - this is the Slack shape the operator asked for. }
procedure TDashboard.DrawChannels(const S: ISurface; const ARect: TRect);
var
  I, Y, X0, Inner: Integer;
  A: TAttr;
  Line: UnicodeString;
  Name: string;
begin
  Frame(S, ARect, 'Channels', '', FZone = zChannels);
  Inner := ARect.W - 2;
  X0 := ARect.X + 1;
  Y := ARect.Y + 1;
  for I := 0 to High(Chans) do
  begin
    if Y > ARect.Y + ARect.H - 2 then
      Break;
    if I = FChanSel then
    begin
      A := FTheme.Accent;
      S.FillRect(R(X0, Y, Inner, 1), A);
      if FZone = zChannels then
        Include(A.Style, sfReverse);
    end
    else
      A := FTheme.Text;

    if Chans[I].Name = '' then
      Name := 'live feed'
    else
      Name := ChHash + ' ' + Chans[I].Name;

    Line := UnicodeString(Name);
    if I = FChanSel then
      Line := ChCursor + ' ' + Line
    else
      Line := '  ' + Line;
    Text(S, X0, Y, Line, A, Inner);
    { An unread count is a fact, so it is shown even on the selected row. }
    if Chans[I].Unread > 0 then
      Text(S, X0 + Inner - 1, Y, UnicodeString(IntToStr(Chans[I].Unread)),
        FTheme.Warn, 1)
    else if Chans[I].Name = '' then
      Text(S, X0 + Inner - 6, Y, 'LIVE', FTheme.Muted, 4);
    Inc(Y);
  end;
end;

{ The board's counts, spelled out. One builder, because the same line is drawn
  on the Messages pane's bottom border and nothing in the status bar - two
  copies would drift. The header chips (q / d / f) are gone: three unlabelled
  letters asked the reader to learn a legend for facts that read as words. }
function TDashboard.StatsLine: UnicodeString;
var
  I, Questions, Decisions, Findings, Open: Integer;
begin
  Questions := 0;
  Decisions := 0;
  Findings := 0;
  Open := 0;
  for I := 0 to High(Board) do
  begin
    if Board[I].Kind = 'question' then
    begin
      Inc(Questions);
      if Board[I].Link = '' then
        Inc(Open);
    end
    else if Board[I].Kind = 'decision' then
      Inc(Decisions)
    else if Board[I].Kind = 'finding' then
      Inc(Findings);
  end;

  Result := ' open questions ' + UnicodeString(IntToStr(Open)) + ' ' + ChDot +
    ' decisions ' + UnicodeString(IntToStr(Decisions)) + ' ' + ChDot +
    ' findings ' + UnicodeString(IntToStr(Findings)) + ' ';
  if Open = 0 then
    Result := Result + ChDot + ' all answered ';
end;

procedure TDashboard.DrawMessages(const S: ISurface; const ARect: TRect);
var
  I, Y, X0, Inner, Shown: Integer;
  A: TAttr;
  Line: UnicodeString;
  Right, Title, Stats: UnicodeString;
  Wanted: string;
begin
  Wanted := Chans[FChanSel].Name;
  if Wanted = '' then
    Right := 'every topic'
  else
    Right := ChHash + ' ' + UnicodeString(Wanted);
  Frame(S, ARect, 'Messages', Right, FZone = zMessages);

  Inner := ARect.W - 4;
  X0 := ARect.X + 2;
  Y := ARect.Y + 1;
  Shown := 0;
  I := FMsgScroll;
  while I <= High(Board) do
  begin
    if (Wanted <> '') and (Board[I].Topic <> Wanted) then
    begin
      Inc(I);
      Continue;
    end;
    if Y > ARect.Y + ARect.H - 3 then
      Break;
    if Shown = FMsgSel then
    begin
      A := FTheme.Accent;
      { Start one column inside the border: X0 - 2 is the border itself, and
        the first render showed the selection painting over it, so row 1 had no
        left edge while every later row did. }
      S.FillRect(R(X0 - 1, Y, ARect.W - 3, 1), A);
      if FZone = zMessages then
        Include(A.Style, sfReverse);
    end
    else
      A := KindAttr(FTheme, Board[I].Kind);

    { The author is part of the row now: a feed where you cannot see who wrote
      a thing is a feed you cannot act on. }
    Title := KindChip(Board[I].Kind) + UnicodeString(Board[I].Author) +
      ' ' + ChDot + ' ' + UnicodeString(Board[I].Title);
    Line := Title;
    Text(S, X0, Y, Line, A, Inner - Length(Board[I].Meta) - 1);
    Text(S, X0 + Inner - Length(Board[I].Meta), Y,
      UnicodeString(Board[I].Meta), FTheme.Muted, Length(Board[I].Meta));
    Inc(Y);
    Inc(I);
    Inc(Shown);
  end;

  if Shown = 0 then
    Text(S, X0, Y, 'no messages in this channel', FTheme.Muted, Inner);

  { The board's counts ride the pane's own bottom border rather than taking a
    row of their own: the border was already drawing a rule there, so this
    spends nothing and puts the facts next to the messages they describe. It is
    drawn last so the message rows cannot paint over it. }
  Stats := StatsLine;
  if (ARect.H >= 2) and (ARect.W > Length(Stats) + 4) then
    Text(S, ARect.X + 2, ARect.Y + ARect.H - 1, Stats,
      OnBg(FTheme.Muted, FTheme.Bg), Length(Stats));
end;

{ The status bar carries the workspace on the left, and nothing else: the
  board's counts moved onto the Messages pane's bottom border, where they sit
  beside the messages they describe instead of in a bar of their own. }
procedure TDashboard.DrawStatus(const S: ISurface; const ARect: TRect);
var
  Left, Hints, Dir, Age: UnicodeString;
  Secs: Int64;
begin
  S.FillRect(ARect, FTheme.Panel);

  { The workspace directory, not just its name: two checkouts of the same
    project are different workspaces, and the tail of the path is what tells
    them apart. Truncated from the LEFT when it will not fit, so the leaf
    directory - the part that identifies it - survives. }
  Dir := UnicodeString(GetCurrentDir);
  Left := ' ' + Dir;
  if Length(Left) > ARect.W - 30 then
    Left := ' ' + ChDotted + Copy(Dir, Length(Dir) - (ARect.W - 34),
      Length(Dir));
  Text(S, ARect.X, ARect.Y, Left, FTheme.Muted, ARect.W - 26);

  { How old the data on screen is. A dashboard that repaints while showing a
    frozen snapshot is the failure this feature's own risk list names, so the
    age is stated rather than implied. Absent when the host does not report a
    read (the mock, which has nothing to poll). }
  if FReadAt > 0 then
  begin
    Secs := DateTimeToUnix(Now) - FReadAt;
    if Secs < 0 then
      Secs := 0;
    if Secs < 2 then
      Age := 'live'
    else
      Age := 'read ' + UnicodeString(IntToStr(Secs)) + 's ago';
    Hints := 'tab zone  arrows move  q quit';
    if ARect.W > Length(Left) + Length(Hints) + Length(Age) + 4 then
      Text(S, ARect.X + ARect.W - Length(Hints) - Length(Age) - 3, ARect.Y,
        Age, FTheme.Muted, Length(Age));
  end;

  Hints := 'tab zone  arrows move  q quit ';
  if ARect.W > Length(Left) + Length(Hints) then
    Text(S, ARect.X + ARect.W - Length(Hints), ARect.Y, Hints, FTheme.Muted,
      Length(Hints));
end;

procedure TDashboard.Render(const S: ISurface);
var
  W, H, TasksH, BoardY, BoardH: Integer;
  TasksRect, ChanRect, MsgRect, StatusRect: TRect;
begin
  W := FBounds.W;
  H := FBounds.H;
  if (W <= 0) or (H <= 0) then
    Exit;

  S.FillRect(FBounds, FTheme.Base);

  StatusRect := R(0, H - 1, W, 1);
  { Tasks take 60% of the usable height (everything above the status bar). }
  TasksH := ((H - 1) * TasksPercent) div 100;
  if TasksH < MinTasksH then
    TasksH := MinTasksH;
  if TasksH > H - 1 - MinMsgH then
    TasksH := H - 1 - MinMsgH;
  BoardY := TasksH;
  BoardH := H - 1 - TasksH;

  TasksRect := R(0, 0, W, TasksH);
  ChanRect := R(0, BoardY, ChanW, BoardH);
  MsgRect := R(ChanW, BoardY, W - ChanW, BoardH);

  DrawTasks(S, TasksRect);
  DrawChannels(S, ChanRect);
  DrawMessages(S, MsgRect);
  DrawStatus(S, StatusRect);
end;

{ Keep the selected card visible: after a move, nudge the lane's scroll so the
  selected index is within the window. The layout owns the heights, so this
  recomputes them the same way DrawTasks does. }
procedure TDashboard.EnsureVisible(ALane, AVisH, AInnerW: Integer);
var
  H, Y, I, Need: Integer;
begin
  if (ALane < 0) or (ALane >= LaneCount) then
    Exit;
  if Length(Lanes[ALane]) = 0 then
  begin
    FScroll[ALane] := 0;
    Exit;
  end;

  { Scroll up until the selection is at or after the top. }
  if FScroll[ALane] > FCard[ALane] then
    FScroll[ALane] := FCard[ALane];

  { Then walk from the scroll top and scroll down until it fits. }
  repeat
    Y := 0;
    Need := -1;
    for I := FScroll[ALane] to High(Lanes[ALane]) do
    begin
      H := CardHeight(Lanes[ALane][I], AInnerW) + CardPad;
      if I = FCard[ALane] then
      begin
        Need := Y + CardHeight(Lanes[ALane][I], AInnerW);
        Break;
      end;
      Inc(Y, H);
    end;
    if (Need >= 0) and (Need > AVisH) and (FScroll[ALane] < FCard[ALane]) then
      Inc(FScroll[ALane])
    else
      Break;
  until False;
end;

function TDashboard.LaneVisible(ALane: Integer): Boolean;
begin
  if (ALane < 0) or (ALane >= LaneCount) then
    Exit(False);
  { The three working lanes are always drawn; BLOCKED and DROPPED only when
    they hold something. }
  Result := (ALane <> 2) and (ALane <> 4) or (Length(Lanes[ALane]) > 0);
end;

{ Step FLane by ADelta over the DRAWN lanes only. Without this, arrowing right
  onto an empty DROPPED lane moved the focus to a column that is not on screen:
  no header highlight, no cursor, and the arrows then seemed dead. }
procedure TDashboard.MoveLane(ADelta: Integer);
var
  L: Integer;
begin
  L := FLane + ADelta;
  while (L >= 0) and (L < LaneCount) do
  begin
    if LaneVisible(L) then
    begin
      FLane := L;
      { Keep the card index inside the new lane, or moving lanes leaves a
        selection past the end of a shorter column. }
      if FCard[FLane] > Length(Lanes[FLane]) - 1 then
        FCard[FLane] := Length(Lanes[FLane]) - 1;
      if FCard[FLane] < 0 then
        FCard[FLane] := 0;
      FScroll[FLane] := 0;
      Exit;
    end;
    Inc(L, ADelta);
  end;
end;

function TDashboard.HandleEvent(const E: TInputEvent): Boolean;
var
  Shift: Boolean;
  LaneW, InnerW, VisH: Integer;
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
        zTasks: FZone := zMessages;
        zChannels: FZone := zTasks;
        zMessages: FZone := zChannels;
      end;
    end
    else
    begin
      case FZone of
        zTasks: FZone := zChannels;
        zChannels: FZone := zMessages;
        zMessages: FZone := zTasks;
      end;
    end;
    Exit;
  end;

  { The visible card height, recomputed the same way the layout does, so a
    keyboard move can keep the selection on screen. }
  LaneW := (FBounds.W - 2) div LaneCount;
  InnerW := LaneW - 3;
  VisH := FBounds.H - ((FBounds.H - 1) * TasksPercent) div 100 - 3;

  case E.Key.Kind of
    kkLeft:
      if FZone = zTasks then
        MoveLane(-1);
    kkRight:
      if FZone = zTasks then
        MoveLane(1);
    kkUp:
      case FZone of
        zTasks:
          if FCard[FLane] > 0 then
          begin
            Dec(FCard[FLane]);
            EnsureVisible(FLane, VisH, InnerW);
          end;
        zChannels:
          if FChanSel > 0 then
          begin
            Dec(FChanSel);
            FMsgSel := 0;
            FMsgScroll := 0;
          end;
        zMessages:
          if FMsgSel > 0 then
            Dec(FMsgSel);
      end;
    kkDown:
      case FZone of
        zTasks:
          if FCard[FLane] < Length(Lanes[FLane]) - 1 then
          begin
            Inc(FCard[FLane]);
            EnsureVisible(FLane, VisH, InnerW);
          end;
        zChannels:
          if FChanSel < High(Chans) then
          begin
            Inc(FChanSel);
            FMsgSel := 0;
            FMsgScroll := 0;
          end;
        zMessages:
          Inc(FMsgSel);
      end;
    { Escape does NOT quit. It is the universal "back out of this" key, and an
      operator reaches for it to leave a selection or a channel, not to end the
      program - quitting on it lost the whole dashboard to a reflexive press.
      Quit stays on q and Ctrl-C, which are unambiguous. }
  else
    Result := False;
  end;
end;

{ Parse a WxH terminal size. Returns False on anything malformed, so a typo
  gets a usage line rather than a zero-sized frame that renders nothing. }
function ParseSize(const ASpec: string; out AW, AH: Integer): Boolean;
var
  P: Integer;
begin
  AW := 0;
  AH := 0;
  Result := False;
  P := Pos('x', ASpec);
  if P = 0 then
    Exit;
  AW := StrToIntDef(Copy(ASpec, 1, P - 1), 0);
  AH := StrToIntDef(Copy(ASpec, P + 1, Length(ASpec)), 0);
  Result := (AW > 0) and (AH > 0);
end;

{ Headless render: drive the SAME Render path into an in-memory surface and
  print it as plain lines.

  The FEATURE records that the mock "has not been visually verified" - it
  compiles and links, but nobody has looked. This is how it gets looked at
  without a tty, and it is the cheap place to find layout bugs: the arithmetic
  is identical to the app's, so an overflow or a mis-sized zone shows up here
  first. Trailing blanks are trimmed so the frame's right edge is visible. }
procedure DumpFrame(AWidth, AHeight: Integer);
var
  Mem: TSurfaceMemory;
  Surf: ISurface;
  DashOut: TDashboard;
  ThemeOut: TTheme;
  Y, X, Last: Integer;
  Line: UnicodeString;
  Line8: string;
begin
  ThemeOut := DarkTheme;
  Mem := TSurfaceMemory.Create(AWidth, AHeight);
  Surf := Mem;
  DashOut := TDashboard.Create(ThemeOut);
  try
    DashOut.Arrange(R(0, 0, AWidth, AHeight));
    { Establish the screen background exactly as TTuiApp.RenderFrame does. The
      dump bypasses TTuiApp, so without these two lines every sfScreenBg cell
      would come out as whatever the surface was initialised with, and the
      frame would be judged against a background the app never shows. }
    Surf.SetScreenBg(ThemeOut.Bg);
    Surf.Clear(DefaultAttr);
    DashOut.Render(Surf);
    for Y := 0 to AHeight - 1 do
    begin
      { Build from CellAt rather than RowText: RowText concatenates each cell's
        Ch, and a cell that was never Put holds an EMPTY string, so it vanishes
        and every real gap in the frame collapses. That made the dump lie about
        adjacent borders. One cell must always be one character. }
      Line := '';
      for X := 0 to AWidth - 1 do
        if Mem.CellAt(X, Y).Ch = '' then
          Line := Line + ' '
        else
          Line := Line + Mem.CellAt(X, Y).Ch;
      Last := 0;
      for X := 1 to Length(Line) do
        if Line[X] <> ' ' then
          Last := X;
      { UTF8Encode explicitly: the implicit UnicodeString->string conversion is
        lossy for the box-drawing glyphs on this build. }
      Line8 := UTF8Encode(Copy(Line, 1, Last));
      WriteLn(Line8);
    end;
  finally
    DashOut.Free;
    Surf := nil;
  end;
end;
end.
