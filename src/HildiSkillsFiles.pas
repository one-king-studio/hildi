unit HildiSkillsFiles;
{ Third-party Agent Skills: discovery of SKILL.md directories, and parsing them
  into something TSkillRegistry can serve.

  The format is the open standard at https://agentskills.io/specification.md - a
  directory containing SKILL.md: YAML frontmatter (name + description required)
  followed by a Markdown body, plus optional scripts/, references/ and assets/.

  This unit is PURE: it reads files and produces records. It does not know about
  the registry, the approval system, or the agent loop. Import lives in
  HildiSkills, so the parsing rules here can be tested without a store, a
  session, or a prompt.

  A malformed skill never raises and never aborts a scan: it comes back with
  Problem set, so one bad directory in a cloned repo cannot take out the rest. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpjson, HildiYAML, HildiSkills;

type
  { Where a skill was found. Project scope wins a name collision. }
  TSkillScope = (skProject, skUser);

  TSkillResourceKind = (rkScript, rkReference, rkAsset);

  { One discovered skill directory. Every frontmatter field the spec defines is
    carried; we interpret only what the registry needs. }
  TSkillFile = record
    Name: string;           // spec `name`
    Description: string;    // spec `description`
    License: string;
    Compatibility: string;
    { Parsed and DISPLAYED only. The spec marks this experimental, and honouring
      it would let a downloaded skill widen its own permissions - the opposite of
      what the approval gate exists for. }
    AllowedTools: string;
    MetadataKeys: TStringArray;
    MetadataValues: TStringArray;
    Body: string;           // Markdown after the closing ---, trimmed
    Dir: string;            // absolute directory holding SKILL.md
    SkillMDPath: string;    // absolute path to SKILL.md
    Scope: TSkillScope;
    Resources: TStringArray;  // paths relative to Dir, sorted, capped
    ResourcesTruncated: Boolean;
    { '' when the skill is valid. Otherwise the reason, already phrased for the
      operator, naming the problem rather than the rule. }
    Problem: string;
  end;
  TSkillFileArray = array of TSkillFile;

const
  SkillFileName = 'SKILL.md';
  MaxSkillNameLen = 64;
  MaxSkillDescriptionLen = 1024;
  MaxSkillCompatibilityLen = 500;
  { A skills root is scanned two levels down, and never more than this many
    directories, so a large tree cannot stall startup. }
  DefaultSkillScanDepth = 2;
  DefaultSkillScanDirs = 2000;
  { How many bundled files are listed on activation. The listing is a hint, not
    an inventory. }
  DefaultMaxListedResources = 50;
  { A SKILL.md is instructions, not a dataset; the spec recommends under 500
    lines. A file past this is refused rather than pulled into memory. }
  MaxSkillFileBytes = 512 * 1024;

{ Split a SKILL.md into its frontmatter fields and body.

  Returns False + AError when there is no frontmatter or it is unterminated. An
  unclosed block is an error rather than a body: silently treating the rest of
  the file as a body would hide a truncated skill. }
function SplitFrontmatter(const AText: string; out AFrontmatter, ABody,
  AError: string): Boolean;

{ Parse one SKILL.md's text into a record. ADir names the directory (for the
  parent-name check and the resource walk); ASkillMDPath is recorded as-is.
  Never raises: failures land in Problem. }
function ParseSkillFile(const AText, ADir, ASkillMDPath: string;
  AScope: TSkillScope): TSkillFile;

{ The validation rules the spec states, as one function so a caller can check a
  record without a filesystem. '' when valid. }
function ValidateSkillFile(const ASkill: TSkillFile): string;

{ Scan a skills root for subdirectories containing SKILL.md. Bounded by depth and
  directory count; both bounds, when hit, truncate the scan rather than fail it. }
function ScanSkillsDir(const ARoot: string; AScope: TSkillScope;
  AMaxDepth: Integer = DefaultSkillScanDepth;
  AMaxDirs: Integer = DefaultSkillScanDirs): TSkillFileArray;

{ Scan the four conventional skill locations: <workspace>/.hildi/skills,
  <workspace>/.agents/skills, then the same two under AUserHome. Project entries
  come first, and a later user skill with the same name does NOT override an
  earlier project one - the caller decides, but the order makes that natural. }
function ScanSkills(const AWorkspaceRoot, AUserHome: string): TSkillFileArray;

{ A skill's registry key, derived from its spec name: snake_case, so it is safe
  in an approval ref and a tool namespace. 'pdf-processing' becomes
  'pdf_processing'. Deterministic, so a rescan produces the same key. }
function SkillKeyOf(const AName: string): string;

{ Import the VALID skills into ARegistry. Invalid ones (Problem <> '') are
  skipped and named in AShadowed, so a caller can report them without stopping.

  On a name collision the EARLIER entry wins - ScanSkills returns project scope
  first, so a project skill shadows a user skill of the same name. The shadowed
  skill's qualified name is added to AShadowed. }
function ImportSkills(const ARegistry: TSkillRegistry;
  const ASkills: TSkillFileArray; out AShadowed: TStringArray): Integer;

{ True when AName satisfies the spec's naming rules. AReason names the failure
  in the operator's terms. }
function IsValidSkillName(const AName: string; out AReason: string): Boolean;

implementation

function StrOf(AObj: TJSONObject; const AKey: string): string; forward;
function QuoteColonValues(AFront: string): string; forward;

{ Read a text file, refusing anything past the cap rather than reading a
  truncated prefix - a partially-read skill would parse as a differently-shaped
  one, which is worse than a clear refusal. }
function ReadTextBounded(const APath: string; AMaxBytes: Integer;
  out AText, AError: string): Boolean;
var
  Fs: TFileStream;
begin
  Result := False;
  AText := '';
  AError := '';
  try
    Fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      if Fs.Size > AMaxBytes then
      begin
        AError := 'SKILL.md is larger than ' + IntToStr(AMaxBytes) + ' bytes';
        Exit;
      end;
      SetLength(AText, Fs.Size);
      if Fs.Size > 0 then
        Fs.ReadBuffer(AText[1], Fs.Size);
    finally
      Fs.Free;
    end;
  except
    on E: Exception do
    begin
      AError := 'could not read SKILL.md: ' + E.Message;
      Exit;
    end;
  end;
  Result := True;
end;

{ Directories that never hold a skill and can be arbitrarily large. }
function IsSkippedDirName(const AName: string): Boolean;
begin
  Result := SameText(AName, '.git') or SameText(AName, 'node_modules') or
    SameText(AName, '.svn') or SameText(AName, '.hg');
end;

{ In-place insertion sort. Listings are small (a skill's own files), so O(n^2)
  is cheaper than the ceremony of anything smarter. }
procedure InsertionSortStrings(var AItems: TStringArray);
var
  I, J: Integer;
  Tmp: string;
begin
  for I := 1 to High(AItems) do
  begin
    J := I;
    while (J > 0) and (AItems[J] < AItems[J - 1]) do
    begin
      Tmp := AItems[J];
      AItems[J] := AItems[J - 1];
      AItems[J - 1] := Tmp;
      Dec(J);
    end;
  end;
end;

{ Fill the record's resource list from the skill's own directory. Listed, never
  read: the model fetches one on demand, so a large skill costs nothing until it
  asks for a file. }
procedure ListResources(var ASkill: TSkillFile; AMax: Integer);
var
  S: TSearchRec;
  Sub, Found: TStringArray;
  I, N: Integer;
begin
  Found := nil;
  { One level deep: scripts/, references/, assets/ and any other top-level entry.
    The spec recommends keeping references one hop from SKILL.md anyway. }
  if FindFirst(IncludeTrailingPathDelimiter(ASkill.Dir) + '*', faAnyFile,
    S) = 0 then
  try
    repeat
      if (S.Name = '.') or (S.Name = '..') then
        Continue;
      if SameText(S.Name, SkillFileName) then
        Continue;
      SetLength(Found, Length(Found) + 1);
      if (S.Attr and faDirectory) <> 0 then
        Found[High(Found)] := S.Name + '/'
      else
        Found[High(Found)] := S.Name;
    until FindNext(S) <> 0;
  finally
    FindClose(S);
  end;

  { Sorted so the listing is stable across scans - an unstable listing would make
    the prompt fragment churn and defeat prompt caching. }
  InsertionSortStrings(Found);

  if AMax <= 0 then
    AMax := Length(Found);
  N := Length(Found);
  if N > AMax then
  begin
    ASkill.ResourcesTruncated := True;
    N := AMax;
  end;
  SetLength(ASkill.Resources, N);
  for I := 0 to N - 1 do
    ASkill.Resources[I] := Found[I];
end;

function IsValidSkillName(const AName: string; out AReason: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := False;
  AReason := '';
  if AName = '' then
  begin
    AReason := 'the name is empty';
    Exit;
  end;
  if Length(AName) > MaxSkillNameLen then
  begin
    AReason := 'the name is longer than ' + IntToStr(MaxSkillNameLen) + ' characters';
    Exit;
  end;
  if AName[1] = '-' then
  begin
    AReason := 'the name starts with a hyphen';
    Exit;
  end;
  if AName[Length(AName)] = '-' then
  begin
    AReason := 'the name ends with a hyphen';
    Exit;
  end;
  for I := 1 to Length(AName) do
  begin
    C := AName[I];
    if (C >= 'a') and (C <= 'z') then
      Continue;
    if (C >= '0') and (C <= '9') then
      Continue;
    if C = '-' then
    begin
      if (I > 1) and (AName[I - 1] = '-') then
      begin
        AReason := 'the name contains consecutive hyphens';
        Exit;
      end;
      Continue;
    end;
    AReason := 'the name contains a character that is not a-z, 0-9 or a hyphen';
    Exit;
  end;
  Result := True;
end;

function SplitFrontmatter(const AText: string; out AFrontmatter, ABody,
  AError: string): Boolean;
var
  Lines: TStringArray;
  I, StartIdx, EndIdx, FirstLine: Integer;
  Normalised: string;
begin
  { Normalise CRLF once so line handling below is uniform. }
  Result := False;
  AFrontmatter := '';
  ABody := '';
  AError := '';
  Normalised := StringReplace(AText, #13#10, #10, [rfReplaceAll]);
  Normalised := StringReplace(Normalised, #13, #10, [rfReplaceAll]);

  { The opening fence must be the first non-blank line, and must be exactly ---.
    A leading blank line is tolerated because hand-edited files accumulate them. }
  StartIdx := 1;
  while (StartIdx <= Length(Normalised)) and (Normalised[StartIdx] = #10) do
    Inc(StartIdx);
  if StartIdx > Length(Normalised) then
  begin
    AError := 'the file is empty';
    Exit;
  end;
  if Copy(Normalised, StartIdx, 4) <> '---'#10 then
  begin
    if Copy(Normalised, StartIdx, 3) = '---' then
      AError := 'the frontmatter is not closed with ---'
    else
      AError := 'the file does not start with a --- frontmatter block';
    Exit;
  end;

  { Split from the opening fence onward, so the blank-line prefix does not shift
    the indices the fence search relies on. }
  Lines := Copy(Normalised, StartIdx, MaxInt).Split([#10]);
  FirstLine := 0;   { Lines[0] is the opening fence itself }
  EndIdx := -1;
  for I := FirstLine + 1 to High(Lines) do
    if Trim(Lines[I]) = '---' then
    begin
      EndIdx := I;
      Break;
    end;
  if EndIdx < 0 then
  begin
    AError := 'the frontmatter is not closed with ---';
    Exit;
  end;

  AFrontmatter := '';
  for I := FirstLine + 1 to EndIdx - 1 do
  begin
    if AFrontmatter <> '' then
      AFrontmatter := AFrontmatter + #10;
    AFrontmatter := AFrontmatter + Lines[I];
  end;
  ABody := '';
  for I := EndIdx + 1 to High(Lines) do
  begin
    if ABody <> '' then
      ABody := ABody + #10;
    ABody := ABody + Lines[I];
  end;
  ABody := Trim(ABody);
  Result := True;
end;

function ParseSkillFile(const AText, ADir, ASkillMDPath: string;
  AScope: TSkillScope): TSkillFile;
var
  Front, Body, Err, YamlErr, Quoted: string;
  Data: TJSONData;
  Obj: TJSONObject;
  Meta: TJSONData;
  I: Integer;
begin
  Result := Default(TSkillFile);
  Result.Dir := ADir;
  Result.SkillMDPath := ASkillMDPath;
  Result.Scope := AScope;

  if not SplitFrontmatter(AText, Front, Body, Err) then
  begin
    Result.Problem := Err;
    Exit;
  end;
  Result.Body := Body;

  Data := nil;
  YamlErr := '';
  Data := ParseYaml(Front, YamlErr);
  if (Data = nil) or (YamlErr <> '') then
  begin
    { COMPATIBILITY FALLBACK. The client guide is explicit that skills authored
      for other clients routinely contain technically invalid YAML - most often
      an unquoted value containing a colon (`description: Use when: the user
      asks`). Rejecting those would defeat the point of adopting a shared
      standard, so retry with such values quoted before giving up. }
    Quoted := QuoteColonValues(Front);
    if Quoted <> Front then
    begin
      YamlErr := '';
      Data := ParseYaml(Quoted, YamlErr);
    end;
    if (Data = nil) or (YamlErr <> '') then
    begin
      Result.Problem := 'the frontmatter is not valid YAML: ' + YamlErr;
      Exit;
    end;
  end;

  try
    if not (Data is TJSONObject) then
    begin
      Result.Problem := 'the frontmatter is not a mapping of fields';
      Exit;
    end;
    Obj := TJSONObject(Data);
    Result.Name := StrOf(Obj, 'name');
    Result.Description := StrOf(Obj, 'description');
    Result.License := StrOf(Obj, 'license');
    Result.Compatibility := StrOf(Obj, 'compatibility');
    Result.AllowedTools := StrOf(Obj, 'allowed-tools');

    Meta := Obj.Find('metadata');
    if Meta is TJSONObject then
    begin
      SetLength(Result.MetadataKeys, TJSONObject(Meta).Count);
      SetLength(Result.MetadataValues, TJSONObject(Meta).Count);
      for I := 0 to TJSONObject(Meta).Count - 1 do
      begin
        Result.MetadataKeys[I] := TJSONObject(Meta).Names[I];
        Result.MetadataValues[I] := TJSONObject(Meta).Items[I].AsString;
      end;
    end;
  finally
    Data.Free;
  end;

  Result.Problem := ValidateSkillFile(Result);
end;

function StrOf(AObj: TJSONObject; const AKey: string): string;
var
  D: TJSONData;
begin
  Result := '';
  D := AObj.Find(AKey);
  if D = nil then
    Exit;
  { A scalar is what the spec defines for these fields; a non-scalar is coerced
    to its JSON text rather than dropped, so the operator sees what they wrote. }
  if D.JSONType in [jtString, jtNumber, jtBoolean, jtNull] then
    Result := D.AsString
  else
    Result := D.AsJSON;
end;

function QuoteColonValues(AFront: string): string;
var
  Lines: TStringArray;
  I, P: Integer;
  Line, Key, Value: string;
  Changed: Boolean;
begin
  { Quote a top-level value that contains a colon and is not already quoted.
    Deliberately narrow: only `key: value` lines, only when the value has a ':'
    and no surrounding quotes, so ordinary frontmatter is untouched. }
  Changed := False;
  Lines := AFront.Split([#10]);
  for I := 0 to High(Lines) do
  begin
    Line := Lines[I];
    P := Pos(':', Line);
    if P <= 1 then
      Continue;
    { A line indented under `metadata:` is not a top-level field; leave it. }
    if (Line[1] = ' ') or (Line[1] = #9) then
      Continue;
    Key := Copy(Line, 1, P);
    Value := Trim(Copy(Line, P + 1, MaxInt));
    if Value = '' then
      Continue;
    if (Value[1] = '"') or (Value[1] = '''') then
      Continue;
    if Pos(':', Value) = 0 then
      Continue;
    Lines[I] := Key + ' "' + StringReplace(Value, '"', '''', [rfReplaceAll]) + '"';
    Changed := True;
  end;
  if not Changed then
    Exit(AFront);
  Result := '';
  for I := 0 to High(Lines) do
  begin
    if I > 0 then
      Result := Result + #10;
    Result := Result + Lines[I];
  end;
end;

function ValidateSkillFile(const ASkill: TSkillFile): string;
var
  Why: string;
  ParentName: string;
begin
  { The spec's rules, in the order an author would fix them. Each message names
    the problem in the operator's terms rather than quoting the rule number. }
  Result := '';
  if not IsValidSkillName(ASkill.Name, Why) then
  begin
    Result := 'the skill name is invalid: ' + Why;
    Exit;
  end;

  { The name must match the directory it lives in. The spec requires it, and a
    mismatch means a renamed folder or a copy-paste, both of which produce a
    skill that answers to a name the operator will not find. }
  if ASkill.Dir <> '' then
  begin
    ParentName := ExtractFileName(ExcludeTrailingPathDelimiter(ASkill.Dir));
    if (ParentName <> '') and (ParentName <> ASkill.Name) then
    begin
      Result := 'the name "' + ASkill.Name + '" does not match its directory ("' +
        ParentName + '")';
      Exit;
    end;
  end;

  if ASkill.Description = '' then
  begin
    Result := 'the description is empty';
    Exit;
  end;
  if Length(ASkill.Description) > MaxSkillDescriptionLen then
  begin
    Result := 'the description is longer than ' +
      IntToStr(MaxSkillDescriptionLen) + ' characters';
    Exit;
  end;

  if Length(ASkill.Compatibility) > MaxSkillCompatibilityLen then
    Result := 'the compatibility note is longer than ' +
      IntToStr(MaxSkillCompatibilityLen) + ' characters';
end;

function ScanSkillsDir(const ARoot: string; AScope: TSkillScope;
  AMaxDepth: Integer; AMaxDirs: Integer): TSkillFileArray;
var
  Visited: Integer;

  { A candidate is a subdirectory holding a file named exactly SKILL.md. Loose
    files in a skills root (a README, a lockfile) are ignored rather than
    reported: they are normal, not mistakes. }
  procedure Consider(const ADir: string);
  var
    MD, Text, Err: string;
    Fs: TFileStream;
    Skill: TSkillFile;
  begin
    Inc(Visited);
    if Visited > AMaxDirs then
      Exit;
    MD := IncludeTrailingPathDelimiter(ADir) + SkillFileName;
    if not FileExists(MD) then
      Exit;
    { A skill body is small by design; refuse to read a pathological file rather
      than pull megabytes into memory. The spec recommends <500 lines. }
    Text := '';
    Err := '';
    if not ReadTextBounded(MD, MaxSkillFileBytes, Text, Err) then
    begin
      Skill := Default(TSkillFile);
      Skill.Dir := ADir;
      Skill.SkillMDPath := MD;
      Skill.Scope := AScope;
      Skill.Problem := Err;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Skill;
      Exit;
    end;
    Skill := ParseSkillFile(Text, ADir, MD, AScope);
    if Skill.Problem = '' then
      ListResources(Skill, DefaultMaxListedResources);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Skill;
  end;

  { Walk breadth-first and bounded. Skipping .git and node_modules is not an
    optimisation: a node_modules tree can hold thousands of directories and none
    of them is a skill. }
  procedure Walk(const ADir: string; ADepth: Integer);
  var
    S: TSearchRec;
    Sub: TStringArray;
    I: Integer;
  begin
    if (ADepth > AMaxDepth) or (Visited > AMaxDirs) then
      Exit;
    Consider(ADir);
    Sub := nil;
    if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faDirectory, S) = 0 then
    try
      repeat
        if (S.Name = '.') or (S.Name = '..') then
          Continue;
        if (S.Attr and faDirectory) = 0 then
          Continue;
        if IsSkippedDirName(S.Name) then
          Continue;
        SetLength(Sub, Length(Sub) + 1);
        Sub[High(Sub)] := S.Name;
      until FindNext(S) <> 0;
    finally
      FindClose(S);
    end;
    for I := 0 to High(Sub) do
      Walk(IncludeTrailingPathDelimiter(ADir) + Sub[I], ADepth + 1);
  end;

begin
  Result := nil;
  Visited := 0;
  if (ARoot = '') or (not DirectoryExists(ARoot)) then
    Exit;
  Walk(ExcludeTrailingPathDelimiter(ARoot), 1);
end;

function ScanSkills(const AWorkspaceRoot, AUserHome: string): TSkillFileArray;
var
  Project, User, Dirs: TSkillFileArray;
  I, N: Integer;

  procedure Append(var AInto: TSkillFileArray; const AFrom: TSkillFileArray);
  var
    K: Integer;
  begin
    for K := 0 to High(AFrom) do
    begin
      SetLength(AInto, Length(AInto) + 1);
      AInto[High(AInto)] := AFrom[K];
    end;
  end;

begin
  { PROJECT FIRST, then user. ImportSkills keeps the earlier entry on a
    collision, so returning project scope first is what makes project beat user
    without a second pass. }
  Result := nil;
  Project := nil;
  User := nil;
  if AWorkspaceRoot <> '' then
  begin
    Append(Project, ScanSkillsDir(IncludeTrailingPathDelimiter(AWorkspaceRoot) +
      '.hildi' + PathDelim + 'skills', skProject));
    Append(Project, ScanSkillsDir(IncludeTrailingPathDelimiter(AWorkspaceRoot) +
      '.agents' + PathDelim + 'skills', skProject));
  end;
  if AUserHome <> '' then
  begin
    Append(User, ScanSkillsDir(IncludeTrailingPathDelimiter(AUserHome) +
      '.hildi' + PathDelim + 'skills', skUser));
    Append(User, ScanSkillsDir(IncludeTrailingPathDelimiter(AUserHome) +
      '.agents' + PathDelim + 'skills', skUser));
  end;
  N := 0;
  SetLength(Result, Length(Project) + Length(User));
  for I := 0 to High(Project) do
  begin
    Result[N] := Project[I];
    Inc(N);
  end;
  for I := 0 to High(User) do
  begin
    Result[N] := User[I];
    Inc(N);
  end;
end;

function SkillKeyOf(const AName: string): string;
var
  I: Integer;
begin
  { The key is an approval-ref and tool-namespace token, so it must be a plain
    identifier: hyphens become underscores, and anything else that is not
    alphanumeric is dropped. Deterministic, so a rescan yields the same key and
    an approval granted once keeps applying. }
  Result := '';
  for I := 1 to Length(AName) do
    case AName[I] of
      'a'..'z', 'A'..'Z', '0'..'9': Result := Result + LowerCase(AName[I]);
      '-', '_': Result := Result + '_';
    else
      ;   // dropped
    end;
  { A key must not be empty or it cannot be referenced. }
  if Result = '' then
    Result := 'skill';
end;

function ImportSkills(const ARegistry: TSkillRegistry;
  const ASkills: TSkillFileArray; out AShadowed: TStringArray): Integer;
var
  I, J, K: Integer;
  S: TSkill;
  Seen: TStringArray;
  Duplicate: Boolean;
begin
  Result := 0;
  AShadowed := nil;
  Seen := nil;
  for I := 0 to High(ASkills) do
  begin
    { An invalid skill never reaches the registry. Its Problem is the caller's to
      report; importing it would offer the model a skill whose body may be
      truncated or whose name is unusable. }
    if (ASkills[I].Problem <> '') or (ASkills[I].Name = '') then
      Continue;

    Duplicate := False;
    for K := 0 to High(Seen) do
      if Seen[K] = ASkills[I].Name then
        Duplicate := True;

    if Duplicate then
    begin
      { EARLIER WINS. ScanSkills returns project scope first, so the arriving
        duplicate is the user-scope one being shadowed. Named, not silent: an
        operator who loses an hour to silent shadowing will not trust the
        feature again. }
      SetLength(AShadowed, Length(AShadowed) + 1);
      AShadowed[High(AShadowed)] := ASkills[I].Name + ' (' +
        ASkills[I].SkillMDPath + ')';
      Continue;
    end;

    SetLength(Seen, Length(Seen) + 1);
    Seen[High(Seen)] := ASkills[I].Name;

    S := Default(TSkill);
    S.Key := SkillKeyOf(ASkills[I].Name);
    S.Name := ASkills[I].Name;
    { The spec folds "what it does" and "when to use it" into one description. }
    S.Description := ASkills[I].Description;
    S.Instructions := ASkills[I].Body;
    S.Location := ASkills[I].Dir;
    S.AllowedTools := ASkills[I].AllowedTools;
    S.License := ASkills[I].License;
    S.Compatibility := ASkills[I].Compatibility;
    S.ResourcesTruncated := ASkills[I].ResourcesTruncated;
    SetLength(S.Resources, Length(ASkills[I].Resources));
    for J := 0 to High(ASkills[I].Resources) do
      S.Resources[J] := ASkills[I].Resources[J];
    ARegistry.Add(S);
    Inc(Result);
  end;
end;

end.
