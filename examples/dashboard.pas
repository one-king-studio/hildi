program dashboard;
{ The Board Dashboard: a separate binary that shows one workspace's
  coordination state - the task list as a kanban, and the board as a Slack-style
  channel list with a live feed.

  A VIEWER. It reads the store and draws; it posts nothing yet. The panel itself
  lives in hildegard.helper.dashboard.panel, so the layout can be exercised by
  the mock (examples/dashboard_mock.pas) without a store.

  It links no agent-loop unit: the same closure discipline the TUI client is
  held to. That is why it opens the store and the board/task stores directly
  rather than borrowing the harness's session bootstrap.

  Run: make dashboard }

{$mode delphi}{$H+}{$codepage utf8}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}   // cthreads first; cwstring for Unicode
  SysUtils, DateUtils,
  hildegard.helper.store, hildegard.helper.board, hildegard.helper.board.store,
  hildegard.helper.tasks, hildegard.helper.tasks.store,
  hildegard.helper.workspace,
  hildegard.helper.dashboard.panel,
  tui.base, tui.theme, tui.app, tui.surface, tui.surface.video,
  tui.input, tui.input.terminal, tui.widget;

var
  { Set by the panel's quit keys via the app's stop condition. }
  DashQuit: Boolean;

function ShouldStop: Boolean;
begin
  Result := DashQuit;
end;

{ The middot separator as UTF-8 bytes. Holder is an AnsiString, so a
  UnicodeString literal cannot be concatenated into it without an implicit
  (and lossy) conversion that -Sew rejects. }
const
  Dot8 = ' ' + #$C2#$B7 + ' ';

{ A session id is 32 hex chars. A card has no room for that, and none of it is
  meaningful to a reader - shorten to a prefix that is still distinguishable on
  screen, since the full id is in the store for anyone who needs it. }
function ShortId(const AId: string): string;
begin
  if Length(AId) <= 12 then
    Result := AId
  else
    Result := Copy(AId, 1, 8);
end;

{ A relative age: "3m", "2h", "4d". The dashboard answers "how stale is this",
  and a wall-clock timestamp makes the reader do the subtraction. }
function AgeOf(ATime: Int64): string;
var
  Secs: Int64;
begin
  if ATime <= 0 then
    Exit('-');
  Secs := DateTimeToUnix(Now) - ATime;
  if Secs < 0 then
    Secs := 0;
  if Secs < 60 then
    Result := IntToStr(Secs) + 's'
  else if Secs < 3600 then
    Result := IntToStr(Secs div 60) + 'm'
  else if Secs < 86400 then
    Result := IntToStr(Secs div 3600) + 'h'
  else
    Result := IntToStr(Secs div 86400) + 'd';
end;

function KindName(AKind: TBoardKind): string;
begin
  case AKind of
    bkNote: Result := 'note';
    bkQuestion: Result := 'question';
    bkDecision: Result := 'decision';
    bkFinding: Result := 'finding';
    bkAnswer: Result := 'answer';
  else
    Result := 'status';
  end;
end;

{ Fill the panel's globals from the store. The panel owns the layout; this owns
  the reading, so the mock can swap in static data and nothing else changes. }
procedure LoadWorkspace(ABoard: IBoardStore; ATasks: ITaskStore;
  AWorkspaceId: Integer);
var
  Filter: TBoardFilter;
  Entries: TBoardEntryArray;
  TFilter: TTaskFilter;
  Cards: TTaskCardArray;
  Topics: TStringArray;
  Err: string;
  I, K: Integer;
  Status: TTaskStatus;
begin
  { Tasks, one query per lane. The lanes are the statuses, in kanban order. }
  for I := 0 to LaneCount - 1 do
    SetLength(Lanes[I], 0);
  LaneTitles[0] := 'OPEN';
  LaneTitles[1] := 'CLAIMED';
  LaneTitles[2] := 'BLOCKED';
  LaneTitles[3] := 'DONE';
  LaneTitles[4] := 'DROPPED';

  for I := 0 to LaneCount - 1 do
  begin
    Status := TTaskStatus(I);
    TFilter := Default(TTaskFilter);
    TFilter.Status := Status;
    TFilter.StatusSet := True;
    if not ATasks.List(AWorkspaceId, TFilter, Cards, Err) then
      Continue;
    SetLength(Lanes[I], Length(Cards));
    for K := 0 to High(Cards) do
    begin
      Lanes[I][K].Id := '#' + IntToStr(Cards[K].Id);
      Lanes[I][K].Title := Cards[K].Title;
      { The holder line is who + how long, never the id twice. The separator is
        prepared as UTF-8 bytes: Holder is an AnsiString, and concatenating a
        UnicodeString literal into it silently converts (and -Sew rejects it). }
      if Cards[K].ClaimedBy <> '' then
        Lanes[I][K].Holder := ShortId(Cards[K].ClaimedBy) + Dot8 +
          AgeOf(Cards[K].StatusAt)
      else if Cards[K].Status = tsDone then
        Lanes[I][K].Holder := 'done' + Dot8 + AgeOf(Cards[K].StatusAt)
      else
        Lanes[I][K].Holder := 'unclaimed' + Dot8 + AgeOf(Cards[K].CreatedAt);
    end;
  end;

  { The live feed: every live entry, newest first. }
  Filter := Default(TBoardFilter);
  Filter.Limit := 200;
  SetLength(Board, 0);
  if ABoard.Read(AWorkspaceId, Filter, Entries, Err) then
    for I := 0 to High(Entries) do
    begin
      SetLength(Board, Length(Board) + 1);
      Board[High(Board)].Kind := KindName(Entries[I].Kind);
      Board[High(Board)].Author := Entries[I].FromLabel;
      Board[High(Board)].Topic := Entries[I].Topic;
      Board[High(Board)].Title := Entries[I].Title;
      Board[High(Board)].Meta := AgeOf(Entries[I].CreatedAt);
      if Entries[I].ReplyTo <> 0 then
        Board[High(Board)].Link := '-> #' + IntToStr(Entries[I].ReplyTo)
      else
        Board[High(Board)].Link := '';
    end;

  { Channels: the live feed first, then one row per live topic. }
  SetLength(Chans, 0);
  SetLength(Chans, 1);
  Chans[0].Name := '';
  Chans[0].Unread := 0;
  if ABoard.ListTopics(AWorkspaceId, Topics, Err) then
    for I := 0 to High(Topics) do
    begin
      SetLength(Chans, Length(Chans) + 1);
      Chans[High(Chans)].Name := Topics[I];
      Chans[High(Chans)].Unread := 0;
    end;
end;

var
  StorePath: string;
  Cfg: TStoreConfig;
  Store: TSqliteStore;
  StoreErr: TStoreError;
  Ws: TWorkspace;
  WsErr: string;
  WorkspaceId: Integer;
  BoardStore: IBoardStore;
  TaskStore: ITaskStore;
  Panel: TDashboard;
  Theme: TTheme;
  Surface: ISurface;
  InputTerm: TInputSourceTerminal;
  Input: IInputSource;
  App: TTuiApp;
  DumpW, DumpH: Integer;

begin
  DashQuit := False;

  StorePath := GetEnvironmentVariable('HILDEGARD_STORE_PATH');
  if StorePath = '' then
    StorePath := IncludeTrailingPathDelimiter(GetUserDir) +
      '.hildegard-helper' + PathDelim + 'store.db';
  ForceDirectories(ExtractFileDir(StorePath));
  Cfg := Default(TStoreConfig);
  Cfg.DatabasePath := StorePath;
  Cfg.BusyTimeoutMs := 5000;

  Store := TSqliteStore.Create(Cfg);
  try
    if not Store.Open(StoreErr) then
    begin
      WriteLn('error: could not open store ', StorePath, ': ', StoreErr.Message);
      Halt(1);
    end;

    WorkspaceId := 0;
    Ws := TWorkspace.Open('', WsErr);
    if Ws = nil then
    begin
      WriteLn('error: workspace: ', WsErr);
      Halt(1);
    end;
    try
      if not Store.EnsureWorkspace(Ws.Root, WorkspaceId, StoreErr) then
      begin
        WriteLn('error: workspace row: ', StoreErr.Message);
        Halt(1);
      end;
    finally
      Ws.Free;
    end;

    BoardStore := TSqliteBoardStore.Create(Store);
    TaskStore := TSqliteTaskStore.Create(Store);
    LoadWorkspace(BoardStore, TaskStore, WorkspaceId);

    { `--dump [WxH]` renders one frame and exits. No terminal is opened, so the
      binary can be verified over a pipe - the only way to check what it
      actually reads from the store without a tty. }
    if (ParamCount >= 1) and (ParamStr(1) = '--dump') then
    begin
      DumpW := 100;
      DumpH := 34;
      if ParamCount >= 2 then
      begin
        DumpW := StrToIntDef(Copy(ParamStr(2), 1, Pos('x', ParamStr(2)) - 1), 0);
        DumpH := StrToIntDef(Copy(ParamStr(2), Pos('x', ParamStr(2)) + 1,
          Length(ParamStr(2))), 0);
        if (DumpW <= 0) or (DumpH <= 0) then
        begin
          WriteLn('usage: dashboard --dump [WxH]');
          Halt(2);
        end;
      end;
      DumpFrame(DumpW, DumpH);
      Halt(0);
    end;

    Theme := DarkTheme;
    Panel := TDashboard.Create(Theme);
    try
      Surface := TSurfaceVideo.Create;
      InputTerm := TInputSourceTerminal.Create;
      Input := InputTerm;
      { Same wiring as the other examples: TTuiApp defaults ScreenBg to 0, so
        without this every sfScreenBg cell paints palette 0. }
      App := TTuiApp.Create(Surface, Input, Panel);
      try
        App.ScreenBg := Theme.Bg;
        App.Run(@ShouldStop);
      finally
        App.Free;
        Input := nil;
        Surface := nil;
      end;
    finally
      Panel.Free;
      BoardStore := nil;
      TaskStore := nil;
    end;
  finally
    Store.Close;
    Store.Free;
  end;
end.
