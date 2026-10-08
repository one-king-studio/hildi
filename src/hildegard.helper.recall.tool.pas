unit hildegard.helper.recall.tool;
{ recall_tool_result: read a window of a large tool result that the prompt view
  truncated. The full result is the session artifact (its messages row); this
  tool caps its own output and never spills, so inspecting an artifact cannot
  create more artifacts.

  The cap and the truncation marker live here because the adapter (which caps
  the prompt view) and the tool (which reads the artifact) must agree on the
  tool name and the marker shape. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpjson, jsonparser, hildegard.helper.store,
  hildegard.helper.session, hildegard.helper.llm, hildegard.helper.agent;

const
  RecallToolName = 'recall_tool_result';
  DefaultToolResultCap = 8192;

{ Resolves a configured cap: >0 uses it, <0 disables, 0 falls back to
  HILDEGARD_TOOL_RESULT_CAP, else DefaultToolResultCap. A resolved value <= 0
  means capping is off. }
function ResolveToolResultCap(AValue: Integer): Integer;

{ The marker appended to a truncated prompt tool result; it names the stored
  message id and the tool that can read more. }
function ToolResultTruncationMarker(AId: Int64; ATotalBytes: Integer): string;

type
  { Bound to a store and a session; registered like any other tool. }
  TRecallTool = class
  private
    FStore: TSqliteStore;
    FSessionId: string;
    FCap: Integer;
  public
    constructor Create(AStore: TSqliteStore; const ASessionId: string;
      ACap: Integer);
    function Recall(const AArgumentsJson: string;
      out AResult: string; out AError: string;
      AObserver: TToolObserver = nil): Boolean;
    { Full-text search of the whole session (archived included). }
    function Search(ARoot: TJSONObject; out AResult: string;
      out AError: string): Boolean;
    procedure Register(ATools: TToolRegistry);
  end;

implementation

function ResolveToolResultCap(AValue: Integer): Integer;
var
  V: string;
begin
  if AValue <> 0 then
    Exit(AValue);
  V := GetEnvironmentVariable('HILDEGARD_TOOL_RESULT_CAP');
  if V <> '' then
    Exit(StrToIntDef(Trim(V), 0));
  Result := DefaultToolResultCap;
end;

function ToolResultTruncationMarker(AId: Int64; ATotalBytes: Integer): string;
begin
  Result := Format('[output truncated: %d bytes total; message_id=%d; use %s ' +
    'with offset/limit to read more]', [ATotalBytes, AId, RecallToolName]);
end;

constructor TRecallTool.Create(AStore: TSqliteStore; const ASessionId: string;
  ACap: Integer);
begin
  inherited Create;
  FStore := AStore;
  FSessionId := ASessionId;
  FCap := ACap;
end;

procedure TRecallTool.Register(ATools: TToolRegistry);
var
  Spec: TToolSpec;
begin
  Spec.Name := RecallToolName;
  Spec.Description :=
    'Recall from this session. Either read a window of a truncated tool ' +
    'result (pass message_id from a truncation marker, plus optional ' +
    'offset/limit), or full-text search the whole session including archived ' +
    'messages (pass query, plus an optional scope: content, tool_reason, ' +
    'tool_name, or tool_arguments).';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"message_id":{"type":"integer","description":"from the truncation marker"},' +
    '"offset":{"type":"integer","description":"0-based byte offset"},' +
    '"limit":{"type":"integer","description":"maximum bytes to return"},' +
    '"query":{"type":"string","description":"full-text search term"},' +
    '"scope":{"type":"string","enum":["content","tool_reason","tool_name",' +
    '"tool_arguments"],"description":"restrict the search to one column"}},' +
    '"required":[]}';
  ATools.Add(Spec, Recall);
end;

function TRecallTool.Search(ARoot: TJSONObject; out AResult: string;
  out AError: string): Boolean;
var
  Query, Scope: string;
  V: TJSONData;
  Cols: array of string;
  Msgs: TMessageRecordArray;
  StoreErr: TStoreError;
  I: Integer;
  Line: string;
begin
  AResult := '';
  AError := '';
  V := ARoot.Find('query');
  Query := V.AsString;
  Scope := '';
  V := ARoot.Find('scope');
  if (V <> nil) and (V.JSONType = jtString) then
    Scope := V.AsString;
  SetLength(Cols, 0);
  if Scope <> '' then
  begin
    SetLength(Cols, 1);
    Cols[0] := Scope;
  end;
  if not FStore.SearchMessages(FSessionId, Query, Cols, 20, Msgs, StoreErr) then
  begin
    AError := 'search failed: ' + StoreErr.Message;
    Exit(False);
  end;
  if Length(Msgs) = 0 then
  begin
    AResult := '(no matches)';
    Exit(True);
  end;
  for I := 0 to High(Msgs) do
  begin
    Line := Format('[seq %d, role %d] %s',
      [Msgs[I].Seq, Ord(Msgs[I].Role),
       Copy(Msgs[I].Content, 1, 200)]);
    if Msgs[I].ToolReason <> '' then
      Line := Line + ' (reason: ' + Copy(Msgs[I].ToolReason, 1, 100) + ')';
    if AResult <> '' then
      AResult := AResult + LineEnding;
    AResult := AResult + Line;
  end;
  Result := True;
end;

function TRecallTool.Recall(const AArgumentsJson: string;
  out AResult: string; out AError: string;
  AObserver: TToolObserver = nil): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  V: TJSONData;
  Rec: TMessageRecord;
  StoreErr: TStoreError;
  Id: Int64;
  Offset, Limit, Len: Integer;
begin
  AResult := '';
  AError := '';
  Data := nil;
  try
    try
      Data := GetJSON(AArgumentsJson);
    except
      AError := 'invalid arguments JSON';
      Exit(False);
    end;
    if not (Data is TJSONObject) then
    begin
      AError := 'arguments must be an object';
      Exit(False);
    end;
    Root := TJSONObject(Data);

    { Search mode: a `query` searches the whole session (archived included). }
    V := Root.Find('query');
    if (V <> nil) and (V.JSONType = jtString) and (V.AsString <> '') then
    begin
      Exit(Search(Root, AResult, AError));
    end;

    V := Root.Find('message_id');
    if (V = nil) or (V.JSONType <> jtNumber) then
    begin
      AError := 'message_id must be an integer';
      Exit(False);
    end;
    Id := V.AsInt64;

    Offset := 0;
    V := Root.Find('offset');
    if (V <> nil) and (V.JSONType = jtNumber) then
      Offset := V.AsInteger;
    Limit := 0;
    V := Root.Find('limit');
    if (V <> nil) and (V.JSONType = jtNumber) then
      Limit := V.AsInteger;

    if Offset < 0 then
    begin
      AError := 'offset must be zero or greater';
      Exit(False);
    end;

    if not FStore.QueryMessage(FSessionId, Id, Rec, StoreErr) then
    begin
      AError := 'no tool result with message_id=' + IntToStr(Id);
      Exit(False);
    end;
    if Rec.Role <> mrTool then
    begin
      AError := 'message_id=' + IntToStr(Id) + ' is not a tool result';
      Exit(False);
    end;

    { Cap the window; with no cap, default to the whole artifact. }
    if FCap > 0 then
    begin
      if (Limit <= 0) or (Limit > FCap) then
        Limit := FCap;
    end
    else if Limit <= 0 then
      Limit := Length(Rec.Content);

    Len := Length(Rec.Content);
    if Offset >= Len then
      Exit(True);                     // nothing at or past the end
    if Limit > Len - Offset then
      Limit := Len - Offset;

    AResult := Copy(Rec.Content, Offset + 1, Limit);
    Result := True;
  finally
    Data.Free;
  end;
end;

end.
