unit hildi.harness.subagent;
{ The subagent roster: the parent session's view of its active children, fed
  from the runtime's ekSubagent events. The TUI sidebar renders it and lets the
  operator spy on an entry.

  Not thread-safe: the TUI thread owns it and applies events as it drains them. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TSubagentStatus = (ssSpawned, ssRunning, ssCompleted, ssFailed, ssAborted,
    ssReleased, ssGone);

  TSubagentEntry = record
    SessionId: string;
    LabelText: string;
    Status: TSubagentStatus;
    UpdatedMs: Int64;
  end;

  TSubagentEntryArray = array of TSubagentEntry;

  TSubagentRoster = class
  private
    FEntries: TSubagentEntryArray;
  public
    { Apply a roster update for a child. A new id appends; an existing id
      updates in place (status + time). A terminal status keeps the entry
      visible so a result is not lost from view. }
    procedure Apply(const ASessionId, ALabel, AStatus: string; ANowMs: Int64);
    function Entries: TSubagentEntryArray;
    function Count: Integer;
    { The index of a child, or -1 when absent. }
    function Find(const ASessionId: string): Integer;
    { Drop terminal entries older than the grace window; non-terminal entries
      are never pruned. }
    procedure Prune(ANowMs, AGraceMs: Int64);
  end;

function SubagentStatusFromWire(const AValue: string): TSubagentStatus;
function SubagentStatusIsTerminal(AStatus: TSubagentStatus): Boolean;

implementation

function SubagentStatusFromWire(const AValue: string): TSubagentStatus;
begin
  if AValue = 'spawned' then
    Result := ssSpawned
  else if AValue = 'running' then
    Result := ssRunning
  else if AValue = 'completed' then
    Result := ssCompleted
  else if AValue = 'failed' then
    Result := ssFailed
  else if AValue = 'aborted' then
    Result := ssAborted
  else if AValue = 'released' then
    Result := ssReleased
  else
    Result := ssGone;
end;

function SubagentStatusIsTerminal(AStatus: TSubagentStatus): Boolean;
begin
  Result := AStatus in [ssCompleted, ssFailed, ssAborted, ssReleased, ssGone];
end;

procedure TSubagentRoster.Apply(const ASessionId, ALabel, AStatus: string;
  ANowMs: Int64);
var
  I: Integer;
begin
  if ASessionId = '' then
    Exit;
  I := Find(ASessionId);
  if I < 0 then
  begin
    SetLength(FEntries, Length(FEntries) + 1);
    I := High(FEntries);
    FEntries[I].SessionId := ASessionId;
  end;
  FEntries[I].LabelText := ALabel;
  FEntries[I].Status := SubagentStatusFromWire(AStatus);
  FEntries[I].UpdatedMs := ANowMs;
end;

function TSubagentRoster.Entries: TSubagentEntryArray;
begin
  Result := Copy(FEntries, 0, Length(FEntries));
end;

function TSubagentRoster.Count: Integer;
begin
  Result := Length(FEntries);
end;

function TSubagentRoster.Find(const ASessionId: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FEntries) do
    if FEntries[I].SessionId = ASessionId then
      Exit(I);
  Result := -1;
end;

procedure TSubagentRoster.Prune(ANowMs, AGraceMs: Int64);
var
  Kept: TSubagentEntryArray;
  I: Integer;
begin
  Kept := nil;
  for I := 0 to High(FEntries) do
    if (not SubagentStatusIsTerminal(FEntries[I].Status)) or
      (ANowMs - FEntries[I].UpdatedMs < AGraceMs) then
    begin
      SetLength(Kept, Length(Kept) + 1);
      Kept[High(Kept)] := FEntries[I];
    end;
  FEntries := Kept;
end;

end.
