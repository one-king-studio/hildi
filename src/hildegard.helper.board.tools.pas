unit hildegard.helper.board.tools;
{ The board's three tools: post, read, moderate.

  Posting and reading are ungated - they cannot destroy anything and gating them
  would make a solo agent's scratchpad worthless. Moderation is gated because it
  destroys or restricts knowledge another agent depends on. That is the same
  reach-based rule the shell's effect gate uses. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser,
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.approval,
  hildegard.helper.board, hildegard.helper.board.store;

type
  TBoardTools = class(TInterfacedObject, IToolProvider)
  private
    FStore: IBoardStore;
    FWorkspaceId: Integer;
    FSessionId, FLabel: string;
    FService: IApprovalService;
    function Allow(const AOp, ATitle, AReason: string;
      out AError: string): Boolean;
    function RenderEntry(const AEntry: TBoardEntry;
      const ANow: Int64): string;
  public
    constructor Create(const AStore: IBoardStore; AWorkspaceId: Integer;
      const ASessionId, ALabel: string; AService: IApprovalService);
    procedure Register(ATools: TToolRegistry);
    { IToolProvider: the board contributes no tools through the provider seam
      (Register does that), only the TOC element. Prepare and Specs are therefore
      empty deliberately - the loop already holds the registry. }
    procedure Prepare;
    function Specs: TToolSpecArray;
    function PromptFragment: string;
    function Find(const AName: string; out ATool: TRegisteredTool): Boolean;
    { Public for direct testing, matching TToolHandler. }
    function Post(const AArgumentsJson: string; out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
    function ReadEntries(const AArgumentsJson: string;
      out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
    { The tail element: counts and ages only, never bodies. '' when the board is
      empty or the store fails - a tail that cannot be built must not fail a
      turn. Capped at MaxBoardTocBytes. }
    function TocLine(out AError: string): string;
    function Moderate(const AArgumentsJson: string;
      out AResult, AError: string;
      AObserver: TToolObserver = nil): Boolean;
  end;

const
  BoardPostTool = 'board_post';
  BoardReadTool = 'board_read';
  BoardModerateTool = 'board_moderate';

implementation

{ --- helpers ----------------------------------------------------------- }

function ToolReasonOf(const AJson: string): string;
var
  D: TJSONData;
begin
  Result := '';
  D := GetJSON(AJson);
  if D = nil then
    Exit;
  try
    if D is TJSONObject then
      Result := TJSONObject(D).Get('reason', '');
  finally
    D.Free;
  end;
end;

function OneLine(const AText: string): string;
var
  P: Integer;
begin
  Result := Trim(AText);
  P := Pos(#10, Result);
  if P > 0 then
    Result := Copy(Result, 1, P - 1);
end;

constructor TBoardTools.Create(const AStore: IBoardStore; AWorkspaceId: Integer;
  const ASessionId, ALabel: string; AService: IApprovalService);
begin
  inherited Create;
  FStore := AStore;
  FWorkspaceId := AWorkspaceId;
  FSessionId := ASessionId;
  FLabel := ALabel;
  FService := AService;
end;

procedure TBoardTools.Register(ATools: TToolRegistry);
var
  Spec: TToolSpec;
begin
  Spec := Default(TToolSpec);
  Spec.Name := BoardPostTool;
  Spec.Description :=
    'Post an entry to this workspace''s board: durable knowledge shared with any '
    + 'other agent working here, and with your future self after a context '
    + 'reset. Kinds: note (scratch), question (blocked), answer (a reply), '
    + 'decision (what was settled and why), finding (a fact about the code), '
    + 'status (what you are doing). `topic` is the page identity - reuse an '
    + 'existing one. To correct an earlier entry, post again with `supersedes`; '
    + 'entries are never edited, so the history survives. Ungated.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"kind":{"type":"string","enum":["note","question","answer","decision",' +
    '"finding","status"]},' +
    '"topic":{"type":"string","description":"Page slug, e.g. retry-policy."},' +
    '"title":{"type":"string","description":"One line: what a notice shows."},' +
    '"body":{"type":"string","description":"Markdown detail; may be empty."},' +
    '"reply_to":{"type":"integer","description":"Entry id this replies to."},' +
    '"supersedes":{"type":"integer","description":"Entry id this replaces."},' +
    '"paths":{"type":"array","items":{"type":"string"},' +
    '"description":"Workspace files this is about; used to warn when stale."},' +
    '"reason":{"type":"string","description":"Short reason for this post."}' +
    '},"required":["kind","topic","title","reason"]}';
  ATools.Add(Spec, Post);

  Spec := Default(TToolSpec);
  Spec.Name := BoardReadTool;
  Spec.Description :=
    'Read board entries, newest first. Filter by topic or by kind. Each entry '
    + 'says whether it is the topic''s current truth and whether the files it '
    + 'names have changed since it was written. Ungated.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"topic":{"type":"string"},' +
    '"kind":{"type":"string","enum":["note","question","answer","decision",' +
    '"finding","status"]},' +
    '"since":{"type":"integer","description":"Only entries newer than this id."},' +
    '"query":{"type":"string","description":"Full-text search over titles, ' +
    'bodies and topics. Searching ignores the read cursor and looks at the ' +
    'whole board."},' +
    '"limit":{"type":"integer"},' +
    '"reason":{"type":"string"}' +
    '},"required":["reason"]}';
  ATools.Add(Spec, ReadEntries);

  Spec := Default(TToolSpec);
  Spec.Name := BoardModerateTool;
  Spec.Description :=
    'Moderate the board: delete or restore an entry, pin or unpin it, or lock a '
    + 'topic so it takes no new posts. These destroy or restrict knowledge '
    + 'another agent depends on, so each asks the operator for approval.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"op":{"type":"string","enum":["delete","restore","pin","unpin",' +
    '"lock","unlock"]},' +
    '"id":{"type":"integer","description":"Entry id (not needed for lock)."},' +
    '"topic":{"type":"string","description":"Topic (lock/unlock only)."},' +
    '"reason":{"type":"string"}' +
    '},"required":["op","reason"]}';
  ATools.Add(Spec, Moderate);
end;

function TBoardTools.Allow(const AOp, ATitle, AReason: string;
  out AError: string): Boolean;
var
  Ask: TApprovalAsk;
  Asks: TApprovalAskArray;
  Batch: TApprovalBatchResult;
begin
  Result := False;
  AError := '';
  if FService = nil then
    Exit(True);                    // no gate wired: a test or a bare run
  Ask := Default(TApprovalAsk);
  Ask.Summary := 'board: ' + AOp + ' ' + OneLine(ATitle);
  Ask.Reason := AReason;
  Ask.Subject.Ref := 'board:moderate';
  SetLength(Ask.Options, 1);
  Ask.Options[0] := Default(TApprovalOption);
  Ask.Options[0].Key := 'once';
  Ask.Options[0].Caption := 'allow this once';
  Ask.Options[0].Persists := False;
  Ask.Options[0].Rule := DefaultApprovalRule(aeAllow);
  Ask.Options[0].Rule.Ref := 'board:moderate';
  SetLength(Asks, 1);
  Asks[0] := Ask;
  Batch := Default(TApprovalBatchResult);
  if not FService.Resolve(Asks, Batch) then
  begin
    AError := 'approval service failed';
    Exit;
  end;
  if Batch.Denied then
  begin
    if Batch.Reason <> '' then
      AError := 'board:moderate denied: ' + Batch.Reason
    else
      AError := 'board:moderate denied';
    Exit;
  end;
  Result := True;
end;

function TBoardTools.RenderEntry(const AEntry: TBoardEntry;
  const ANow: Int64): string;
var
  Tags: string;
begin
  Tags := '#' + IntToStr(AEntry.Id) + ' ' + BoardKindToName(AEntry.Kind) +
    ' [' + AEntry.Topic + ']';
  if AEntry.Current then
    Tags := Tags + ' · current';
  if AEntry.Pinned then
    Tags := Tags + ' · pinned';
  if AEntry.DeletedAt <> 0 then
    Tags := Tags + ' · deleted';
  Result := Tags + LineEnding + '  ' + OneLine(AEntry.Title);
  if AEntry.Body <> '' then
    Result := Result + LineEnding + '  ' + AEntry.Body;
  if AEntry.StaleCount > 0 then
    Result := Result + LineEnding + '  ⚠ ' + IntToStr(AEntry.StaleCount) +
      ' change(s) to the files this names since it was written';
end;

{ --- board_post -------------------------------------------------------- }

function TBoardTools.Post(const AArgumentsJson: string;
  out AResult, AError: string; AObserver: TToolObserver): Boolean;
var
  D: TJSONData;
  Root: TJSONObject;
  E: TBoardEntry;
  Id: Integer;
  Reason, KindName, Err, LockedBy: string;
  Kind: TBoardKind;
  Paths: TJSONArray;
  I: Integer;
  Prev: TBoardEntry;
  Found: Boolean;
begin
  Result := False;
  AResult := '';
  AError := '';
  D := GetJSON(AArgumentsJson);
  if D = nil then
  begin
    AError := 'invalid arguments';
    Exit;
  end;
  try
    if not (D is TJSONObject) then
    begin
      AError := 'arguments must be an object';
      Exit;
    end;
    Root := TJSONObject(D);
    Reason := Root.Get('reason', '');
    if Trim(Reason) = '' then
    begin
      AError := 'a non-empty reason is required';
      Exit;
    end;
    KindName := Root.Get('kind', '');
    if not BoardKindFromName(KindName, Kind) then
    begin
      AError := 'unknown kind "' + KindName + '"; use one of: ' + BoardKindList;
      Exit;
    end;
    E := Default(TBoardEntry);
    E.WorkspaceId := FWorkspaceId;
    E.Kind := Kind;
    E.Topic := Trim(Root.Get('topic', ''));
    E.Title := Trim(Root.Get('title', ''));
    E.Body := Root.Get('body', '');
    E.ReplyTo := Root.Get('reply_to', 0);
    E.Supersedes := Root.Get('supersedes', 0);
    E.FromSession := FSessionId;
    E.FromLabel := FLabel;
    { Epoch seconds. A zero here would make the entry look like an empty board to
      the TOC and make every change look newer than it to the staleness check. }
    E.CreatedAt := Round((Now - EncodeDate(1970, 1, 1)) * 86400);
    if E.Topic = '' then
    begin
      AError := 'topic is required (the page this entry belongs to)';
      Exit;
    end;
    if E.Title = '' then
    begin
      AError := 'title is required (one line: what a notice shows)';
      Exit;
    end;
    if (Kind <> bkNote) and (Trim(E.Body) = '') then
    begin
      AError := 'body is required for a ' + KindName +
        ' (only a note may be empty)';
      Exit;
    end;
    if Root.Find('paths') is TJSONArray then
    begin
      Paths := TJSONArray(Root.Find('paths'));
      SetLength(E.Paths, Paths.Count);
      for I := 0 to Paths.Count - 1 do
        E.Paths[I] := Paths.Strings[I];
    end;
    { Superseding across topics would silently retire another page, so it is
      refused rather than allowed and explained later. }
    if E.Supersedes <> 0 then
    begin
      if not FStore.Get(FWorkspaceId, E.Supersedes, Prev, Found, Err) then
      begin
        AError := 'could not read entry ' + IntToStr(E.Supersedes);
        Exit;
      end;
      if not Found then
      begin
        AError := 'supersedes: no entry ' + IntToStr(E.Supersedes);
        Exit;
      end;
      if Prev.Topic <> E.Topic then
      begin
        AError := 'supersedes must name an entry in the same topic (' +
          IntToStr(E.Supersedes) + ' is in "' + Prev.Topic + '")';
        Exit;
      end;
    end;
    if not FStore.IsLocked(FWorkspaceId, E.Topic, LockedBy, Err) then
    begin
      AError := 'could not check the topic lock';
      Exit;
    end;
    if LockedBy <> '' then
    begin
      AError := 'topic "' + E.Topic + '" is locked by ' + LockedBy;
      Exit;
    end;
    if not FStore.Append(E, Id, Err) then
    begin
      AError := Err;
      Exit;
    end;
    AResult := 'posted #' + IntToStr(Id) + ' (' + KindName + ') to "' +
      E.Topic + '"';
    Result := True;
  finally
    D.Free;
  end;
end;

{ --- board_read -------------------------------------------------------- }

function TBoardTools.ReadEntries(const AArgumentsJson: string;
  out AResult, AError: string; AObserver: TToolObserver): Boolean;
var
  D: TJSONData;
  Root: TJSONObject;
  F: TBoardFilter;
  Rows: TBoardEntryArray;
  I: Integer;
  KindName: string;
  Kind: TBoardKind;
  Cur: TBoardEntry;
  Found: Boolean;
  Err: string;
  Cursor: Integer;
  Text, Query: string;
begin
  Result := False;
  AResult := '';
  AError := '';
  D := GetJSON(AArgumentsJson);
  if D = nil then
  begin
    AError := 'invalid arguments';
    Exit;
  end;
  try
    if not (D is TJSONObject) then
    begin
      AError := 'arguments must be an object';
      Exit;
    end;
    Root := TJSONObject(D);
    F := Default(TBoardFilter);
    F.Topic := Trim(Root.Get('topic', ''));
    KindName := Trim(Root.Get('kind', ''));
    if KindName <> '' then
    begin
      if not BoardKindFromName(KindName, Kind) then
      begin
        AError := 'unknown kind "' + KindName + '"; use one of: ' +
          BoardKindList;
        Exit;
      end;
      F.Kind := Kind;
      F.KindSet := True;
    end;
    F.SinceId := Root.Get('since', 0);
    F.Limit := Root.Get('limit', 0);
    { A query searches the whole board rather than advancing from the cursor:
      looking something up is not the same question as "what is new". }
    Query := Trim(Root.Get('query', ''));
    if Query <> '' then
    begin
      if not FStore.Search(FWorkspaceId, Query, F.Limit, Rows, Err) then
      begin
        AError := Err;
        Exit;
      end;
      if Length(Rows) = 0 then
      begin
        AResult := '(nothing matched "' + Query + '")';
        Result := True;
        Exit;
      end;
    end
    else
    begin
      if (F.Topic = '') and (not F.KindSet) and (F.SinceId = 0) then
      begin
        { A bare read: advance from this session's cursor so it sees what is new
          rather than the whole board every time. }
        if FStore.CursorOf(FSessionId, Cursor, Err) then
          F.SinceId := Cursor;
      end;
      if not FStore.Read(FWorkspaceId, F, Rows, Err) then
      begin
        AError := Err;
        Exit;
      end;
      if Length(Rows) = 0 then
      begin
        AResult := '(no board messages)';
        Result := True;
        Exit;
      end;
    end;
    Text := '';
    for I := 0 to High(Rows) do
    begin
      { A topic read marks its current truth. }
      if F.Topic <> '' then
        if FStore.CurrentOf(FWorkspaceId, Rows[I].Topic, Cur, Found, Err) then
          if Found then
            Rows[I].Current := (Cur.Id = Rows[I].Id);
      { Staleness: how many changes have touched the files this entry names since
        it was written. Advisory only - a stale entry is still the best record of
        what was believed, and the annotation says exactly that. }
      if Length(Rows[I].Paths) > 0 then
        if not FStore.ChangedSince(FWorkspaceId, Rows[I].CreatedAt,
          Rows[I].Paths, Rows[I].StaleCount, Err) then
          Rows[I].StaleCount := 0;
      if Text <> '' then
        Text := Text + LineEnding + LineEnding;
      Text := Text + RenderEntry(Rows[I], 0);
    end;
    AResult := Text;
    { Reading advances the cursor, so a later bare read starts after this. }
    FStore.SetCursor(FSessionId, Rows[0].Id, Err);
    Result := True;
  finally
    D.Free;
  end;
end;

{ --- board_moderate ---------------------------------------------------- }

function TBoardTools.Moderate(const AArgumentsJson: string;
  out AResult, AError: string; AObserver: TToolObserver): Boolean;
var
  D: TJSONData;
  Root: TJSONObject;
  Op, Reason, Topic, Err: string;
  Id: Integer;
  E: TBoardEntry;
  Found: Boolean;
  Verb: string;
  Locked: Boolean;
begin
  Result := False;
  AResult := '';
  AError := '';
  D := GetJSON(AArgumentsJson);
  if D = nil then
  begin
    AError := 'invalid arguments';
    Exit;
  end;
  try
    if not (D is TJSONObject) then
    begin
      AError := 'arguments must be an object';
      Exit;
    end;
    Root := TJSONObject(D);
    Reason := Root.Get('reason', '');
    if Trim(Reason) = '' then
    begin
      AError := 'a non-empty reason is required';
      Exit;
    end;
    Op := Trim(Root.Get('op', ''));
    Id := Root.Get('id', 0);
    Topic := Trim(Root.Get('topic', ''));

    { lock/unlock act on a topic; everything else on an entry. }
    if (Op = 'lock') or (Op = 'unlock') then
    begin
      if Topic = '' then
      begin
        AError := Op + ' needs a topic';
        Exit;
      end;
      Locked := Op = 'lock';
      { Approval before the change, so a denial changes nothing. }
      if not Allow(Op, Topic, Reason, Err) then
      begin
        AError := Err;
        Exit;
      end;
      if not FStore.Lock(FWorkspaceId, Topic, FLabel, Locked, Err) then
      begin
        AError := Err;
        Exit;
      end;
      AResult := Op + 'ed topic "' + Topic + '"';
      Result := True;
      Exit;
    end;

    if Op <> 'delete' then
      if (Op <> 'restore') and (Op <> 'pin') and (Op <> 'unpin') then
      begin
        AError := 'unknown op "' + Op + '"; use delete, restore, pin, unpin, ' +
          'lock or unlock';
        Exit;
      end;
    if Id <= 0 then
    begin
      AError := Op + ' needs an entry id';
      Exit;
    end;
    if not FStore.Get(FWorkspaceId, Id, E, Found, Err) then
    begin
      AError := Err;
      Exit;
    end;
    if not Found then
    begin
      AError := 'no entry ' + IntToStr(Id);
      Exit;
    end;
    if not Allow(Op, '#' + IntToStr(Id) + ' ' + E.Title, Reason, Err) then
    begin
      AError := Err;
      Exit;
    end;
    if (Op = 'pin') or (Op = 'unpin') then
    begin
      if not FStore.SetPinned(FWorkspaceId, Id, Op = 'pin', Err) then
      begin
        AError := Err;
        Exit;
      end;
    end
    else
    begin
      if not FStore.MarkDeleted(FWorkspaceId, Id, Op = 'delete', FLabel, Err)
      then
      begin
        AError := Err;
        Exit;
      end;
    end;
    if Op = 'delete' then
      Verb := 'deleted'
    else if Op = 'restore' then
      Verb := 'restored'
    else if Op = 'pin' then
      Verb := 'pinned'
    else
      Verb := 'unpinned';
    AResult := Verb + ' #' + IntToStr(Id);
    Result := True;
    { Kept for -Sew: the locals below are part of the wider signature. }
  finally
    D.Free;
  end;
end;

procedure TBoardTools.Prepare;
begin
  { Nothing to reconcile: the board's store is fixed at construction. }
end;

function TBoardTools.Specs: TToolSpecArray;
begin
  { The board's tools are registered directly (Register), not contributed per
    request, so the provider seam carries only the TOC. }
  Result := nil;
end;

function TBoardTools.PromptFragment: string;
var
  Err: string;
begin
  Result := TocLine(Err);
end;

function TBoardTools.Find(const AName: string;
  out ATool: TRegisteredTool): Boolean;
begin
  { Dispatch goes through the registry, which already holds these tools. }
  ATool := Default(TRegisteredTool);
  Result := False;
end;

function TBoardTools.TocLine(out AError: string): string;
var
  Unread, Q, D, F: Integer;
  LastAt, AgeSec: Int64;
  Cursor: Integer;
  Err, Age: string;
  Body: string;

  function Build(AWithF, AWithD, AWithQ: Boolean): string;
  var
    Fields: string;
  begin
    Fields := 'unread="' + IntToStr(Unread) + '"';
    if AWithQ then
      Fields := Fields + ' q="' + IntToStr(Q) + '"';
    if AWithD then
      Fields := Fields + ' d="' + IntToStr(D) + '"';
    if AWithF then
      Fields := Fields + ' f="' + IntToStr(F) + '"';
    Result := '<board ' + Fields + '>last ' + Age + '</board>';
  end;

begin
  Result := '';
  AError := '';
  if (FStore = nil) then
    Exit;
  Cursor := 0;
  if not FStore.CursorOf(FSessionId, Cursor, Err) then
    Cursor := 0;
  if not FStore.Toc(FWorkspaceId, Cursor, Unread, Q, D, F, LastAt, Err) then
  begin
    { A tail that cannot be built must not fail a turn. }
    AError := Err;
    Exit;
  end;
  if LastAt = 0 then
    Exit;                       // an empty board contributes nothing
  { Age, not a timestamp: "2m" is what a model can act on. LastAt is epoch
    seconds, so compare against the same clock. }
  AgeSec := Round((Now - EncodeDate(1970, 1, 1)) * 86400) - LastAt;
  if AgeSec < 0 then
    AgeSec := 0;
  if AgeSec < 3600 then
    Age := IntToStr(AgeSec div 60) + 'm'
  else
    Age := IntToStr(AgeSec div 3600) + 'h';
  { Drop whole FIELDS in a stated order - f, then d, then q - never truncating
    mid-field and never dropping unread or the age. A TOC that says only "2
    unread" is actionable; one cut mid-attribute is not. }
  Body := Build(True, True, True);
  if Length(Body) > MaxBoardTocBytes then
    Body := Build(False, True, True);
  if Length(Body) > MaxBoardTocBytes then
    Body := Build(False, False, True);
  if Length(Body) > MaxBoardTocBytes then
    Body := Build(False, False, False);
  Result := Body;
end;

end.
