unit hildegard.helper.files;
{ Approval-gated file tools for the agent: read_file, write_file, edit_file,
  list_dir, glob, and grep. Mirrors TCommandTool: parse the JSON arguments,
  resolve approval, act, and report text (or False + error). Every path is
  resolved against the workspace root; escapes are refused.

  Containment is a guardrail, not a sandbox - the same stance as the command
  policy. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpjson,
  hildegard.helper.llm, hildegard.helper.agent, hildegard.helper.approval,
  hildegard.helper.workspace;

type
  TFileToolConfig = record
    Root: string;             // workspace root; '' => process cwd
    MaxReadBytes: Integer;    // 0 => DefaultMaxReadBytes
    MaxOutputBytes: Integer;  // 0 => DefaultMaxOutputBytes (list/glob/grep)
  end;

  TFileTool = class(TInterfacedObject)
  private
    FConfig: TFileToolConfig;
    FService: IApprovalService;
    FWorkspace: TWorkspace;
    function RelOf(const AAbs: string): string;
    function ResolveChecked(const ARel: string; out AAbs, AErr: string): Boolean;
    function Approve(const ARef, ASummary, AReason: string;
      const AParams: TApprovalParams; out AError: string): Boolean;
    function ParseArgs(const AJson: string; out AData: TJSONData;
      out ARoot: TJSONObject; out AError: string): Boolean;
    function CapText(const AText: string; ALimit: Integer): string;
    function MaxRead: Integer;
    function MaxOutput: Integer;
  public
    constructor Create(const AConfig: TFileToolConfig;
      AService: IApprovalService);
    destructor Destroy; override;

    { Registers all six tools. }
    procedure Register(ATools: TToolRegistry);

    { Handlers (public for direct testing). Each resolves approval first. }
    function ReadFile(const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;
    function WriteFile(const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;
    function EditFile(const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;
    function ListDir(const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;
    function Glob(const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;
    function Grep(const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;
  end;

const
  DefaultMaxReadBytes = 262144;    // 256 KiB
  DefaultMaxOutputBytes = 65536;   // 64 KiB
  DefaultGrepMaxResults = 200;
  DefaultCollectLimit = 20000;

{ Glob matcher: '*' within a segment, '?' one character, '**' across segments. }
function GlobMatch(const APattern, APath: string): Boolean;

implementation

{ --- helpers ------------------------------------------------------------ }

function JsonString(ARoot: TJSONObject; const AName: string;
  out AValue: string): Boolean;
var
  V: TJSONData;
begin
  AValue := '';
  V := ARoot.Find(AName);
  Result := (V <> nil) and (V.JSONType = jtString);
  if Result then
    AValue := V.AsString;
end;

function JsonBool(ARoot: TJSONObject; const AName: string;
  ADefault: Boolean): Boolean;
var
  V: TJSONData;
begin
  Result := ADefault;
  V := ARoot.Find(AName);
  if (V <> nil) and (V.JSONType = jtBoolean) then
    Result := V.AsBoolean;
end;

function JsonInt(ARoot: TJSONObject; const AName: string;
  ADefault: Integer): Integer;
var
  V: TJSONData;
begin
  Result := ADefault;
  V := ARoot.Find(AName);
  if (V <> nil) and (V.JSONType = jtNumber) then
    Result := V.AsInteger;
end;

function SplitLines(const AText: string): TStringList;
begin
  Result := TStringList.Create;
  Result.Text := AText;
end;

function FileBytes(const APath: string): Int64;
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    Result := FS.Size;
  finally
    FS.Free;
  end;
end;

{ Reads up to AMaxBytes of a text file. ABinary is set when a NUL appears. }
function ReadTextFile(const APath: string; AMaxBytes: Integer;
  out AText: string; out ATruncated, ABinary: Boolean;
  out AError: string): Boolean;
var
  FS: TFileStream;
  Size, N: Integer;
  Buf: RawByteString;
begin
  AText := '';
  ATruncated := False;
  ABinary := False;
  AError := '';
  try
    FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  except
    on E: Exception do
    begin
      AError := 'could not read ' + APath + ': ' + E.Message;
      Exit(False);
    end;
  end;
  try
    Size := FS.Size;
    N := Size;
    if N > AMaxBytes then
      N := AMaxBytes;
    SetLength(Buf, N);
    if N > 0 then
      FS.ReadBuffer(Buf[1], N);
    ATruncated := Size > AMaxBytes;
    ABinary := Pos(#0, Buf) > 0;
    AText := string(Buf);
    Result := True;
  finally
    FS.Free;
  end;
end;

{ Writes via a temporary sibling then renames, so a failure does not truncate
  an existing file. }
function WriteAtomic(const APath, AContent: string; out AError: string): Boolean;
var
  Tmp: string;
  FS: TFileStream;
begin
  AError := '';
  Tmp := APath + '.hh-tmp';
  try
    FS := TFileStream.Create(Tmp, fmCreate);
    try
      if AContent <> '' then
        FS.WriteBuffer(AContent[1], Length(AContent));
    finally
      FS.Free;
    end;
    if not RenameFile(Tmp, APath) then
    begin
      DeleteFile(Tmp);
      AError := 'could not write: ' + APath;
      Exit(False);
    end;
  except
    on E: Exception do
    begin
      DeleteFile(Tmp);
      AError := E.Message;
      Exit(False);
    end;
  end;
  Result := True;
end;

procedure CollectInto(AList: TStringList; const ADir: string;
  ARecursive, AIncludeDirs: Boolean; ALimit: Integer);
var
  SR: TSearchRec;
  Full: string;
begin
  if AList.Count >= ALimit then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, SR) <> 0 then
    Exit;
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then
        Continue;
      Full := IncludeTrailingPathDelimiter(ADir) + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
      begin
        if AIncludeDirs then
          AList.Add(Full + PathDelim);
        if ARecursive then
          CollectInto(AList, Full, ARecursive, AIncludeDirs, ALimit);
      end
      else
        AList.Add(Full);
      if AList.Count >= ALimit then
        Break;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

{ --- glob matcher ------------------------------------------------------- }

function MatchFrom(const P: string; PI: Integer;
  const T: string; TI: Integer): Boolean; forward;

function MatchStar(const P: string; PI: Integer;
  const T: string; TI: Integer): Boolean;
var
  K: Integer;
begin
  { '**' (optionally followed by '/') crosses segments; '*' does not. }
  if (PI < Length(P)) and (P[PI + 1] = '*') then
  begin
    Inc(PI, 2);
    if (PI <= Length(P)) and (P[PI] = '/') then
      Inc(PI);
    for K := TI to Length(T) + 1 do
      if MatchFrom(P, PI, T, K) then
        Exit(True);
    Exit(False);
  end;
  for K := TI to Length(T) do
  begin
    if (K > TI) and (T[K] = '/') then
      Break;
    if MatchFrom(P, PI + 1, T, K) then
      Exit(True);
  end;
  Result := False;
end;

function MatchFrom(const P: string; PI: Integer;
  const T: string; TI: Integer): Boolean;
begin
  while PI <= Length(P) do
  begin
    if P[PI] = '*' then
      Exit(MatchStar(P, PI, T, TI));
    if TI > Length(T) then
      Exit(False);
    if (P[PI] = '?') or (P[PI] = T[TI]) then
    begin
      Inc(PI);
      Inc(TI);
    end
    else
      Exit(False);
  end;
  Result := TI > Length(T);
end;

function GlobMatch(const APattern, APath: string): Boolean;
begin
  Result := MatchFrom(APattern, 1, APath, 1);
end;

{ --- TFileTool ---------------------------------------------------------- }

constructor TFileTool.Create(const AConfig: TFileToolConfig;
  AService: IApprovalService);
var
  Err: string;
begin
  inherited Create;
  FConfig := AConfig;
  FService := AService;
  FWorkspace := TWorkspace.Open(AConfig.Root, Err);
end;

destructor TFileTool.Destroy;
begin
  FWorkspace.Free;
  inherited Destroy;
end;

function TFileTool.MaxRead: Integer;
begin
  if FConfig.MaxReadBytes > 0 then
    Result := FConfig.MaxReadBytes
  else
    Result := DefaultMaxReadBytes;
end;

function TFileTool.MaxOutput: Integer;
begin
  if FConfig.MaxOutputBytes > 0 then
    Result := FConfig.MaxOutputBytes
  else
    Result := DefaultMaxOutputBytes;
end;

function TFileTool.RelOf(const AAbs: string): string;
begin
  if FWorkspace = nil then
    Exit(AAbs);
  if AAbs = FWorkspace.Root then
    Exit('.');
  Result := Copy(AAbs, Length(FWorkspace.Root) + 2, MaxInt);
end;

function TFileTool.ResolveChecked(const ARel: string;
  out AAbs, AErr: string): Boolean;
var
  P: string;
begin
  AAbs := '';
  AErr := '';
  P := Trim(ARel);
  if P = '' then
  begin
    AErr := 'missing required "path"';
    Exit(False);
  end;
  if FWorkspace = nil then
  begin
    AErr := 'workspace is not available';
    Exit(False);
  end;
  if not FWorkspace.Contains(P) then
  begin
    AErr := 'path escapes the workspace: ' + P;
    Exit(False);
  end;
  AAbs := FWorkspace.Resolve(P);
  Result := True;
end;

function TFileTool.ParseArgs(const AJson: string; out AData: TJSONData;
  out ARoot: TJSONObject; out AError: string): Boolean;
begin
  AData := nil;
  ARoot := nil;
  AError := '';
  try
    AData := GetJSON(AJson);
  except
    on E: Exception do
    begin
      AError := 'invalid arguments JSON';
      Exit(False);
    end;
  end;
  if not (AData is TJSONObject) then
  begin
    FreeAndNil(AData);
    AError := 'arguments must be a JSON object';
    Exit(False);
  end;
  ARoot := TJSONObject(AData);
  Result := True;
end;

{ The model's stated reason for the call, read from its arguments. '' when the
  tool cannot read one; the dialog then shows a placeholder. }
function ToolReasonOf(const AJson: string): string;
var
  Err: string;
begin
  Result := '';
  ExtractToolReason(AJson, Result, Err);
end;

function TFileTool.Approve(const ARef, ASummary, AReason: string;
  const AParams: TApprovalParams; out AError: string): Boolean;
var
  Ask: TApprovalAsk;
  Asks: TApprovalAskArray;
  Batch: TApprovalBatchResult;

  procedure AddOption(const AKey, ACaption: string; APersists: Boolean;
    const AOptionParams: TApprovalParams; AAny: Boolean);
  var
    Opt: TApprovalOption;
  begin
    Opt := Default(TApprovalOption);
    Opt.Key := AKey;
    Opt.Caption := ACaption;
    Opt.Persists := APersists;
    Opt.Rule := DefaultApprovalRule(aeAllow);
    Opt.Rule.Ref := ARef;
    Opt.Rule.Params := AOptionParams;
    Opt.Rule.AnyParams := AAny;
    SetLength(Ask.Options, Length(Ask.Options) + 1);
    Ask.Options[High(Ask.Options)] := Opt;
  end;

begin
  AError := '';
  if FService = nil then
  begin
    AError := 'no approval service configured';
    Exit(False);
  end;
  Ask := Default(TApprovalAsk);
  Ask.Summary := ASummary;
  Ask.Reason := AReason;
  Ask.Subject.Ref := ARef;
  Ask.Subject.Params := AParams;
  AddOption('once', 'allow once', False, nil, False);
  AddOption('exact', 'always this exact operation', True, AParams, False);
  AddOption('any', 'always ' + ARef, True, nil, True);
  SetLength(Asks, 1);
  Asks[0] := Ask;
  if not FService.Resolve(Asks, Batch) then
  begin
    AError := 'approval error: ' + Batch.Reason;
    Exit(False);
  end;
  if Batch.Denied then
  begin
    AError := Batch.Reason;
    Exit(False);
  end;
  Result := True;
end;

function TFileTool.CapText(const AText: string; ALimit: Integer): string;
begin
  if (ALimit > 0) and (Length(AText) > ALimit) then
    Result := Copy(AText, 1, ALimit) + LineEnding + '[truncated]'
  else
    Result := AText;
end;

{ --- read_file ---------------------------------------------------------- }

function TFileTool.ReadFile(const AArgumentsJson: string;
  out AResult: string; out AError: string): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, PathArg, Text: string;
  Offset, Limit: Integer;
  Truncated, Binary: Boolean;
  Lines, OutLines: TStringList;
  I: Integer;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  Lines := nil;
  OutLines := nil;
  try
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
    begin
      AError := 'missing required "path"';
      Exit(False);
    end;
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:read', 'read ' + Rel, ToolReasonOf(AArgumentsJson),
      [Rel], AError) then
      Exit(False);
    if DirectoryExists(Abs) then
    begin
      AError := 'not a file: ' + Rel;
      Exit(False);
    end;
    if not FileExists(Abs) then
    begin
      AError := 'no such file: ' + Rel;
      Exit(False);
    end;
    if not ReadTextFile(Abs, MaxRead, Text, Truncated, Binary, AError) then
      Exit(False);
    if Binary then
    begin
      AResult := 'read ' + Rel + LineEnding + LineEnding +
        '[binary file: ' + IntToStr(FileBytes(Abs)) + ' bytes]';
      Exit(True);
    end;
    Offset := JsonInt(Root, 'offset', 1);
    if Offset < 1 then
      Offset := 1;
    Limit := JsonInt(Root, 'limit', 0);

    Lines := SplitLines(Text);
    OutLines := TStringList.Create;
    for I := Offset - 1 to Lines.Count - 1 do
    begin
      if (Limit > 0) and (OutLines.Count >= Limit) then
        Break;
      OutLines.Add(Lines[I]);
    end;
    { A header naming the file and its size, then the content, so the panel
      reads without the tool needing a separate call-details line. }
    AResult := 'read ' + Rel + ' (' + IntToStr(FileBytes(Abs)) + ' bytes)' +
      LineEnding + LineEnding + CapText(OutLines.Text, MaxOutput);
    if Truncated then
      AResult := AResult + LineEnding + '[truncated: file larger than ' +
        IntToStr(MaxRead) + ' bytes]';
    Result := True;
  finally
    OutLines.Free;
    Lines.Free;
    Data.Free;
  end;
end;

{ --- write_file --------------------------------------------------------- }

function TFileTool.WriteFile(const AArgumentsJson: string;
  out AResult: string; out AError: string): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, PathArg, Content: string;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  try
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
    begin
      AError := 'missing required "path"';
      Exit(False);
    end;
    if not JsonString(Root, 'content', Content) then
    begin
      AError := 'missing required "content"';
      Exit(False);
    end;
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:write', 'write ' + Rel, ToolReasonOf(AArgumentsJson),
      [Rel], AError) then
      Exit(False);
    ForceDirectories(ExtractFileDir(Abs));
    if not WriteAtomic(Abs, Content, AError) then
      Exit(False);
    AResult := 'wrote ' + IntToStr(Length(Content)) + ' bytes to ' + Rel;
    Result := True;
  finally
    Data.Free;
  end;
end;

{ --- edit_file ---------------------------------------------------------- }

function TFileTool.EditFile(const AArgumentsJson: string;
  out AResult: string; out AError: string): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, PathArg, OldS, NewS, Text, Updated: string;
  ReplaceAll: Boolean;
  Truncated, Binary: Boolean;
  Count, P: Integer;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  try
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
    begin
      AError := 'missing required "path"';
      Exit(False);
    end;
    if not JsonString(Root, 'old_string', OldS) or (OldS = '') then
    begin
      AError := 'missing required "old_string"';
      Exit(False);
    end;
    if not JsonString(Root, 'new_string', NewS) then
    begin
      AError := 'missing required "new_string"';
      Exit(False);
    end;
    ReplaceAll := JsonBool(Root, 'replace_all', False);
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:edit', 'edit ' + Rel, ToolReasonOf(AArgumentsJson),
      [Rel], AError) then
      Exit(False);
    if not FileExists(Abs) then
    begin
      AError := 'no such file: ' + Rel;
      Exit(False);
    end;
    if not ReadTextFile(Abs, MaxRead, Text, Truncated, Binary, AError) then
      Exit(False);
    if Binary then
    begin
      AError := 'not a text file: ' + Rel;
      Exit(False);
    end;
    if Truncated then
    begin
      AError := 'file too large to edit: ' + Rel;
      Exit(False);
    end;

    Count := 0;
    P := 1;
    while True do
    begin
      P := Pos(OldS, Text, P);
      if P = 0 then
        Break;
      Inc(Count);
      Inc(P, Length(OldS));
    end;
    if Count = 0 then
    begin
      AError := 'old_string not found in ' + Rel;
      Exit(False);
    end;
    if (Count > 1) and not ReplaceAll then
    begin
      AError := 'old_string is not unique in ' + Rel + '; use replace_all';
      Exit(False);
    end;
    if ReplaceAll then
      Updated := StringReplace(Text, OldS, NewS, [rfReplaceAll])
    else
    begin
      P := Pos(OldS, Text);
      Updated := Copy(Text, 1, P - 1) + NewS +
        Copy(Text, P + Length(OldS), MaxInt);
    end;
    if not WriteAtomic(Abs, Updated, AError) then
      Exit(False);
    AResult := 'replaced ' + IntToStr(Count) + ' occurrence(s) in ' + Rel;
    Result := True;
  finally
    Data.Free;
  end;
end;

{ --- list_dir ----------------------------------------------------------- }

function TFileTool.ListDir(const AArgumentsJson: string;
  out AResult: string; out AError: string): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, PathArg: string;
  Recursive: Boolean;
  Entries: TStringList;
  I: Integer;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  Entries := nil;
  try
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
      PathArg := '.';
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    Recursive := JsonBool(Root, 'recursive', False);
    if not Approve('file:list', 'list ' + Rel, ToolReasonOf(AArgumentsJson),
      [Rel], AError) then
      Exit(False);
    if not DirectoryExists(Abs) then
    begin
      AError := 'not a directory: ' + Rel;
      Exit(False);
    end;
    Entries := TStringList.Create;
    CollectInto(Entries, Abs, Recursive, True, DefaultCollectLimit);
    for I := 0 to Entries.Count - 1 do
      Entries[I] := RelOf(Entries[I]);
    Entries.Sort;
    AResult := CapText(Entries.Text, MaxOutput);
    Result := True;
  finally
    Entries.Free;
    Data.Free;
  end;
end;

{ --- glob --------------------------------------------------------------- }

function TFileTool.Glob(const AArgumentsJson: string;
  out AResult: string; out AError: string): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, Pattern, PathArg: string;
  Files, Hits: TStringList;
  I: Integer;
  Sub: string;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  Files := nil;
  Hits := nil;
  try
    if not JsonString(Root, 'pattern', Pattern) or (Trim(Pattern) = '') then
    begin
      AError := 'missing required "pattern"';
      Exit(False);
    end;
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
      PathArg := '.';
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:glob', 'glob ' + Pattern + ' in ' + Rel,
      ToolReasonOf(AArgumentsJson), [Pattern, Rel], AError) then
      Exit(False);
    if not DirectoryExists(Abs) then
    begin
      AError := 'not a directory: ' + Rel;
      Exit(False);
    end;
    Files := TStringList.Create;
    Hits := TStringList.Create;
    CollectInto(Files, Abs, True, False, DefaultCollectLimit);
    for I := 0 to Files.Count - 1 do
    begin
      Sub := Copy(Files[I], Length(Abs) + 2, MaxInt);
      if GlobMatch(Pattern, Sub) then
        Hits.Add(RelOf(Files[I]));
    end;
    Hits.Sort;
    AResult := CapText(Hits.Text, MaxOutput);
    Result := True;
  finally
    Hits.Free;
    Files.Free;
    Data.Free;
  end;
end;

{ --- grep --------------------------------------------------------------- }

function TFileTool.Grep(const AArgumentsJson: string;
  out AResult: string; out AError: string): Boolean;
var
  Data: TJSONData;
  Root: TJSONObject;
  Rel, Abs, Pattern, PathArg, Text, Needle, Line: string;
  IgnoreCase: Boolean;
  MaxResults, I, J, Found: Integer;
  Files, Hits, Lines: TStringList;
  Truncated, Binary: Boolean;
  SearchIn: string;
begin
  AResult := '';
  AError := '';
  Data := nil;
  if not ParseArgs(AArgumentsJson, Data, Root, AError) then
    Exit(False);
  Files := nil;
  Hits := nil;
  try
    if not JsonString(Root, 'pattern', Pattern) or (Trim(Pattern) = '') then
    begin
      AError := 'missing required "pattern"';
      Exit(False);
    end;
    if not JsonString(Root, 'path', PathArg) or (Trim(PathArg) = '') then
      PathArg := '.';
    IgnoreCase := JsonBool(Root, 'ignore_case', False);
    MaxResults := JsonInt(Root, 'max_results', 0);
    if MaxResults <= 0 then
      MaxResults := DefaultGrepMaxResults;
    if not ResolveChecked(PathArg, Abs, AError) then
      Exit(False);
    Rel := RelOf(Abs);
    if not Approve('file:grep', 'grep ' + Pattern + ' in ' + Rel,
      ToolReasonOf(AArgumentsJson), [Pattern, Rel], AError) then
      Exit(False);

    Files := TStringList.Create;
    Hits := TStringList.Create;
    if DirectoryExists(Abs) then
      CollectInto(Files, Abs, True, False, DefaultCollectLimit)
    else if FileExists(Abs) then
      Files.Add(Abs)
    else
    begin
      AError := 'no such file or directory: ' + Rel;
      Exit(False);
    end;

    Needle := Pattern;
    if IgnoreCase then
      Needle := UpperCase(Needle);
    Found := 0;
    for I := 0 to Files.Count - 1 do
    begin
      if Found >= MaxResults then
        Break;
      if not ReadTextFile(Files[I], MaxRead, Text, Truncated, Binary, AError)
      then
      begin
        AError := '';
        Continue;
      end;
      if Binary then
        Continue;
      Lines := SplitLines(Text);
      try
        for J := 0 to Lines.Count - 1 do
        begin
          Line := Lines[J];
          SearchIn := Line;
          if IgnoreCase then
            SearchIn := UpperCase(SearchIn);
          if Pos(Needle, SearchIn) > 0 then
          begin
            Hits.Add(RelOf(Files[I]) + ':' + IntToStr(J + 1) + ': ' + Line);
            Inc(Found);
            if Found >= MaxResults then
              Break;
          end;
        end;
      finally
        Lines.Free;
      end;
    end;
    AResult := CapText(Hits.Text, MaxOutput);
    if Found >= MaxResults then
      AResult := AResult + LineEnding + '[truncated: ' + IntToStr(MaxResults) +
        ' results]';
    Result := True;
  finally
    Hits.Free;
    Files.Free;
    Data.Free;
  end;
end;

{ --- registration ------------------------------------------------------- }

procedure TFileTool.Register(ATools: TToolRegistry);
var
  Spec: TToolSpec;
begin
  Spec.Name := 'read_file';
  Spec.Description := 'Read a text file inside the workspace. ' +
    'Requires a short reason. Gated by approval.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"File path relative to the workspace."},' +
    '"offset":{"type":"integer","description":"First line to return (1-based)."},' +
    '"limit":{"type":"integer","description":"Maximum lines to return (0 = all)."},' +
    '"reason":{"type":"string","description":"Short reason this read is needed."}' +
    '},"required":["path","reason"]}';
  ATools.Add(Spec, ReadFile);

  Spec.Name := 'write_file';
  Spec.Description := 'Create or overwrite a file inside the workspace. ' +
    'Requires a short reason. Gated by approval.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"File path relative to the workspace."},' +
    '"content":{"type":"string","description":"Full file content to write."},' +
    '"reason":{"type":"string","description":"Short reason this write is needed."}' +
    '},"required":["path","content","reason"]}';
  ATools.Add(Spec, WriteFile);

  Spec.Name := 'edit_file';
  Spec.Description := 'Replace an exact string in a file inside the workspace. ' +
    'Fails if the string is absent or ambiguous (unless replace_all). ' +
    'Requires a short reason. Gated by approval.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"File path relative to the workspace."},' +
    '"old_string":{"type":"string","description":"Exact text to replace."},' +
    '"new_string":{"type":"string","description":"Replacement text."},' +
    '"replace_all":{"type":"boolean","description":"Replace every occurrence."},' +
    '"reason":{"type":"string","description":"Short reason this edit is needed."}' +
    '},"required":["path","old_string","new_string","reason"]}';
  ATools.Add(Spec, EditFile);

  Spec.Name := 'list_dir';
  Spec.Description := 'List directory entries inside the workspace. ' +
    'Requires a short reason. Gated by approval.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"Directory relative to the workspace."},' +
    '"recursive":{"type":"boolean","description":"Descend into subdirectories."},' +
    '"reason":{"type":"string","description":"Short reason this listing is needed."}' +
    '},"required":["reason"]}';
  ATools.Add(Spec, ListDir);

  Spec.Name := 'glob';
  Spec.Description := 'Find files by path pattern (*, ?, **) inside the ' +
    'workspace. Requires a short reason. Gated by approval.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"pattern":{"type":"string","description":"Glob pattern, e.g. src/**/*.pas."},' +
    '"path":{"type":"string","description":"Directory to search (default .)."},' +
    '"reason":{"type":"string","description":"Short reason this search is needed."}' +
    '},"required":["pattern","reason"]}';
  ATools.Add(Spec, Glob);

  Spec.Name := 'grep';
  Spec.Description := 'Search file contents for a substring inside the ' +
    'workspace. Requires a short reason. Gated by approval.';
  Spec.ParametersJson :=
    '{"type":"object","properties":{' +
    '"pattern":{"type":"string","description":"Substring to find."},' +
    '"path":{"type":"string","description":"File or directory (default .)."},' +
    '"ignore_case":{"type":"boolean","description":"Case-insensitive match."},' +
    '"max_results":{"type":"integer","description":"Maximum matches (default 200)."},' +
    '"reason":{"type":"string","description":"Short reason this search is needed."}' +
    '},"required":["pattern","reason"]}';
  ATools.Add(Spec, Grep);
end;

end.
