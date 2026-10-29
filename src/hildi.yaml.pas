unit hildi.yaml;
{ A minimal, tolerant YAML subset, enough for the config/document files an agent
  edits - not a full YAML engine.

  Supported: block mappings (`key: value`), nested mappings by indentation,
  block sequences (`- item`), inline scalars (string, int, float, bool, null),
  and simple flow sequences (`[a, b, c]`). Parsing yields a fpjson TJSONData, so
  a parsed document is uniform with the JSON tools and the YAML emitter
  (fcl-json's json2yaml) can round-trip it.

  Deliberately NOT supported (a construct outside the subset is an ERROR with a
  line number, never a silent mis-parse): anchors/aliases, tags, multi-line
  scalars (`|`/`>`), complex flow collections, and duplicate-key merging. See
  docs/features/File_Tools/File_Tools_v2.SPEC.md. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpjson;

{ Parse AText into a TJSONData (caller frees). A construct outside the subset
  fails with AError naming the line; it never raises and never returns a
  partially-parsed document. }
function ParseYaml(const AText: string; out AError: string): TJSONData;

{ Set a dotted path (a.b[2].c) in AText to AValue and re-emit the document as
  YAML. A parse failure yields '' + AError (no write). }
function SetYamlPath(const AText, APath: string; const AValue: TJSONData;
  out AError: string): string;

{ Emit a TJSONData as YAML. }
function ToYaml(const AData: TJSONData): string;

implementation

type
  TYamlLine = record
    Indent: Integer;
    Text: string;      // trimmed content
    Number: Integer;   // 1-based source line
  end;
  TYamlLines = array of TYamlLine;

{ Split into non-blank, non-comment lines, recording each line's indent. A
  tab in the indentation is rejected (YAML forbids it and it hides errors). }
function SplitYaml(const AText: string; out ALines: TYamlLines;
  out AError: string): Boolean;
var
  P, Start, Indent, N: Integer;
  Line, Trimmed: string;

  procedure AddLine(const ALine: string; ANumber, AIndent: Integer);
  begin
    SetLength(ALines, N + 1);
    ALines[N].Indent := AIndent;
    ALines[N].Text := ALine;
    ALines[N].Number := ANumber;
    Inc(N);
  end;

begin
  ALines := nil;
  AError := '';
  N := 0;
  P := 1;
  while P <= Length(AText) + 1 do
  begin
    Start := P;
    while (P <= Length(AText)) and (AText[P] <> #10) do
      Inc(P);
    Line := Copy(AText, Start, P - Start);
    if (Line <> '') and (Line[Length(Line)] = #13) then
      SetLength(Line, Length(Line) - 1);
    Inc(P);   { past the #10 }
    { Indent: count leading spaces; a tab is an error. }
    Indent := 0;
    while (Indent < Length(Line)) and (Line[Indent + 1] = ' ') do
      Inc(Indent);
    if (Indent < Length(Line)) and (Line[Indent + 1] = #9) then
    begin
      AError := 'tab in indentation at line ' + IntToStr(N + 1);
      Exit(False);
    end;
    Trimmed := Trim(Copy(Line, Indent + 1, MaxInt));
    if (Trimmed = '') or (Trimmed[1] = '#') then
      Continue;
    AddLine(Trimmed, N + 1, Indent);
  end;
  Result := True;
end;

function ParseScalar(const S: string): TJSONData;
var
  T: string;
  I64: Int64;
  F: Double;
begin
  T := Trim(S);
  if (T = '') or (T = '~') or (T = 'null') then
    Exit(CreateJSON);
  if (T = 'true') or (T = 'yes') then
    Exit(CreateJSON(True));
  if (T = 'false') or (T = 'no') then
    Exit(CreateJSON(False));
  if (Length(T) >= 2) and
    (((T[1] = '"') and (T[Length(T)] = '"')) or
     ((T[1] = '''') and (T[Length(T)] = ''''))) then
    Exit(TJSONString.Create(Copy(T, 2, Length(T) - 2)));
  { A number: try int then float; fall back to a string. }
  if (T <> '') and (T[1] in ['-', '+', '0'..'9']) then
  begin
    if TryStrToInt64(T, I64) then
      Exit(TJSONInt64Number.Create(I64));
    if TryStrToFloat(T, F) then
      Exit(TJSONFloatNumber.Create(F));
  end;
  Result := TJSONString.Create(T);
end;

{ A simple flow sequence `[a, b, c]` or a scalar. Returns nil for a nested
  block (the caller handles that). }
function ParseInline(const S: string; out AError: string): TJSONData;
var
  Inner: string;
  Parts: TStringArray;
  I, Start, Depth: Integer;
  Cur: string;
begin
  Result := nil;
  AError := '';
  if (Length(S) >= 2) and (S[1] = '[') and (S[Length(S)] = ']') then
  begin
    Inner := Copy(S, 2, Length(S) - 2);
    Result := TJSONArray.Create;
    Cur := '';
    Depth := 0;
    for I := 1 to Length(Inner) do
    begin
      if Inner[I] = ',' then
      begin
        TJSONArray(Result).Add(ParseScalar(Cur));
        Cur := '';
      end
      else
        Cur := Cur + Inner[I];
    end;
    if Trim(Cur) <> '' then
      TJSONArray(Result).Add(ParseScalar(Cur));
    Exit;
  end;
  Result := ParseScalar(S);
end;

{ Parse lines[I..] as a mapping or sequence at AIndent; returns the index past
  the consumed block. }
function ParseBlock(const ALines: TYamlLines; AStart, AIndent: Integer;
  out AError: string): TJSONData;
var
  I, J, KeyColon, ChildIndent: Integer;
  Line, Key, Value: string;
  IsSeq: Boolean;
begin
  Result := nil;
  AError := '';
  if AStart > High(ALines) then
    Exit(CreateJSON);
  IsSeq := (ALines[AStart].Text = '-') or
    (Copy(ALines[AStart].Text, 1, 2) = '- ');
  if IsSeq then
    Result := TJSONArray.Create
  else
    Result := TJSONObject.Create;
  I := AStart;
  while (I <= High(ALines)) and (ALines[I].Indent >= AIndent) do
  begin
    Line := ALines[I].Text;
    if ALines[I].Indent > AIndent then
    begin
      AError := 'unexpected indent at line ' + IntToStr(ALines[I].Number);
      FreeAndNil(Result);
      Exit;
    end;
    if IsSeq then
    begin
      if (Line <> '-') and (Copy(Line, 1, 2) <> '- ') then
      begin
        AError := 'expected a sequence item at line ' +
          IntToStr(ALines[I].Number);
        FreeAndNil(Result);
        Exit;
      end;
      Value := Trim(Copy(Line, 2, MaxInt));
      if Value = '' then
      begin
        { A nested block for this item. }
        if (I + 1 <= High(ALines)) and (ALines[I + 1].Indent > AIndent) then
        begin
          ChildIndent := ALines[I + 1].Indent;
          TJSONArray(Result).Add(ParseBlock(ALines, I + 1, ChildIndent, AError));
          if AError <> '' then
          begin
            FreeAndNil(Result);
            Exit;
          end;
          while (I + 1 <= High(ALines)) and (ALines[I + 1].Indent > AIndent) do
            Inc(I);
        end
        else
          TJSONArray(Result).Add(CreateJSON);
      end
      else if Pos(': ', Value) > 0 then
      begin
        { An inline mapping item: `- key: value` - parse the rest as a mapping. }
        AError := 'inline mapping in a sequence item is not supported at line ' +
          IntToStr(ALines[I].Number);
        FreeAndNil(Result);
        Exit;
      end
      else
        TJSONArray(Result).Add(ParseInline(Value, AError));
    end
    else
    begin
      KeyColon := Pos(':', Line);
      if KeyColon <= 0 then
      begin
        AError := 'expected "key: value" at line ' + IntToStr(ALines[I].Number);
        FreeAndNil(Result);
        Exit;
      end;
      Key := Trim(Copy(Line, 1, KeyColon - 1));
      Value := Trim(Copy(Line, KeyColon + 1, MaxInt));
      if Value = '' then
      begin
        { A nested block (indented), OR a sequence at the SAME indent (YAML
          allows `key:` followed by `- item` at the key's own level). }
        if (I + 1 <= High(ALines)) and (ALines[I + 1].Indent > AIndent) then
        begin
          ChildIndent := ALines[I + 1].Indent;
          TJSONObject(Result).Add(Key,
            ParseBlock(ALines, I + 1, ChildIndent, AError));
          if AError <> '' then
          begin
            FreeAndNil(Result);
            Exit;
          end;
          while (I + 1 <= High(ALines)) and (ALines[I + 1].Indent > AIndent) do
            Inc(I);
        end
        else if (I + 1 <= High(ALines)) and (ALines[I + 1].Indent = AIndent) and
          ((ALines[I + 1].Text = '-') or
           (Copy(ALines[I + 1].Text, 1, 2) = '- ')) then
        begin
          TJSONObject(Result).Add(Key,
            ParseBlock(ALines, I + 1, AIndent, AError));
          if AError <> '' then
          begin
            FreeAndNil(Result);
            Exit;
          end;
          while (I + 1 <= High(ALines)) and (ALines[I + 1].Indent = AIndent) and
            ((ALines[I + 1].Text = '-') or
             (Copy(ALines[I + 1].Text, 1, 2) = '- ')) do
            Inc(I);
        end
        else
          TJSONObject(Result).Add(Key, CreateJSON);
      end
      else
        TJSONObject(Result).Add(Key, ParseInline(Value, AError));
    end;
    if AError <> '' then
    begin
      FreeAndNil(Result);
      Exit;
    end;
    Inc(I);
  end;
end;

function ParseYaml(const AText: string; out AError: string): TJSONData;
var
  Lines: TYamlLines;
begin
  AError := '';
  Result := nil;
  if not SplitYaml(AText, Lines, AError) then
    Exit;
  if Length(Lines) = 0 then
    Exit(CreateJSON);
  Result := ParseBlock(Lines, 0, Lines[0].Indent, AError);
  if AError <> '' then
    FreeAndNil(Result);
end;

{ --- emit --------------------------------------------------------------- }

{ Escape a scalar for a YAML value: quote when it contains a character that would
  change its meaning. }
function YamlScalar(const V: TJSONData): string;
var
  S: string;
begin
  case V.JSONType of
    jtNull: Exit('null');
    jtBoolean: if V.AsBoolean then Exit('true') else Exit('false');
    jtNumber: Exit(V.AsJSON);
    jtString:
      begin
        S := V.AsString;
        if (S = '') or (Pos(': ', S) > 0) or (Pos('#', S) > 0) or
          (S[1] = '-') or (S[1] = '[') or (S[1] = '{') or (S[1] = '*') or
          (S[1] = '&') or (S[1] = '!') or (S[1] = '>') or (S[1] = '|') or
          (S[1] = '@') or (S[1] = '`') or (S[1] = ' ') or
          (S[Length(S)] = ' ') then
          Exit('"' + StringReplace(S, '"', '\"', [rfReplaceAll]) + '"');
        Exit(S);
      end;
  else
    Exit(V.AsJSON);
  end;
end;

procedure EmitBlock(AData: TJSONData; AIndent: Integer; AOut: TStringList);
var
  I: Integer;
  Pad, ItemPad: string;
  E: TJSONObject;
  A: TJSONArray;
  V: TJSONData;
begin
  Pad := StringOfChar(' ', AIndent);
  ItemPad := StringOfChar(' ', AIndent);
  if AData is TJSONObject then
  begin
    E := TJSONObject(AData);
    for I := 0 to E.Count - 1 do
    begin
      V := E.Items[I];
      if V is TJSONObject then
      begin
        AOut.Add(Pad + E.Names[I] + ':');
        EmitBlock(V, AIndent + 2, AOut);
      end
      else if V is TJSONArray then
      begin
        AOut.Add(Pad + E.Names[I] + ':');
        EmitBlock(V, AIndent + 2, AOut);
      end
      else
        AOut.Add(Pad + E.Names[I] + ': ' + YamlScalar(V));
    end;
  end
  else if AData is TJSONArray then
  begin
    A := TJSONArray(AData);
    for I := 0 to A.Count - 1 do
    begin
      V := A.Items[I];
      if V is TJSONObject then
      begin
        AOut.Add(Pad + '-');
        EmitBlock(V, AIndent + 2, AOut);
      end
      else if V is TJSONArray then
      begin
        AOut.Add(Pad + '-');
        EmitBlock(V, AIndent + 2, AOut);
      end
      else
        AOut.Add(Pad + '- ' + YamlScalar(V));
    end;
  end
  else
    AOut.Add(Pad + YamlScalar(AData));
end;

function ToYaml(const AData: TJSONData): string;
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    EmitBlock(AData, 0, SL);
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

{ --- set a path --------------------------------------------------------- }

{ Split a dotted path with [n] indices into components. }
type
  TPathPart = record
    Name: string;
    Index: Integer;    // -1 when not an index
  end;
  TPathParts = array of TPathPart;

function SplitPath(const APath: string; out AParts: TPathParts;
  out AError: string): Boolean;
var
  I, Bracket: Integer;
  Seg, Name: string;
  P: TPathPart;
begin
  AParts := nil;
  AError := '';
  Seg := '';
  for I := 1 to Length(APath) + 1 do
  begin
    if (I > Length(APath)) or (APath[I] = '.') then
    begin
      if Seg = '' then
        Continue;
      { A segment may be `name` or `name[3]`. }
      Bracket := Pos('[', Seg);
      if Bracket > 0 then
      begin
        Name := Copy(Seg, 1, Bracket - 1);
        P.Name := Name;
        P.Index := StrToIntDef(Copy(Seg, Bracket + 1,
          Pos(']', Seg) - Bracket - 1), -1);
      end
      else
      begin
        P.Name := Seg;
        P.Index := -1;
      end;
      SetLength(AParts, Length(AParts) + 1);
      AParts[High(AParts)] := P;
      Seg := '';
    end
    else
      Seg := Seg + APath[I];
  end;
  Result := True;
end;

function SetYamlPath(const AText, APath: string; const AValue: TJSONData;
  out AError: string): string;
var
  Doc: TJSONData;
  Parts: TPathParts;
  Cur: TJSONData;
  I: Integer;
  Obj: TJSONObject;
  Arr: TJSONArray;
begin
  Result := '';
  AError := '';
  Doc := ParseYaml(AText, AError);
  if Doc = nil then
    Exit;
  try
    if not SplitPath(APath, Parts, AError) then
      Exit;
    if Length(Parts) = 0 then
    begin
      AError := 'empty path';
      Exit;
    end;
    { Walk to the parent of the final component. }
    Cur := Doc;
    for I := 0 to High(Parts) - 1 do
    begin
      if Parts[I].Index >= 0 then
      begin
        if not (Cur is TJSONArray) then
        begin
          AError := 'path expects an array at ' + Parts[I].Name;
          Exit;
        end;
        Arr := TJSONArray(Cur);
        if Parts[I].Index >= Arr.Count then
        begin
          AError := 'index out of range: ' + Parts[I].Name;
          Exit;
        end;
        Cur := Arr.Items[Parts[I].Index];
      end
      else
      begin
        if not (Cur is TJSONObject) then
        begin
          AError := 'path expects an object at ' + Parts[I].Name;
          Exit;
        end;
        Obj := TJSONObject(Cur);
        Cur := Obj.Find(Parts[I].Name);
        if Cur = nil then
        begin
          AError := 'no such key: ' + Parts[I].Name;
          Exit;
        end;
      end;
    end;
    { Set the final component. }
    if Parts[High(Parts)].Index >= 0 then
    begin
      if not (Cur is TJSONArray) then
      begin
        AError := 'path expects an array at ' + Parts[High(Parts)].Name;
        Exit;
      end;
      Arr := TJSONArray(Cur);
      if Parts[High(Parts)].Index >= Arr.Count then
      begin
        AError := 'index out of range: ' + Parts[High(Parts)].Name;
        Exit;
      end;
      Arr.Items[Parts[High(Parts)].Index] := AValue.Clone;
    end
    else
    begin
      if not (Cur is TJSONObject) then
      begin
        AError := 'path expects an object';
        Exit;
      end;
      TJSONObject(Cur).Elements[Parts[High(Parts)].Name] := AValue.Clone;
    end;
    Result := ToYaml(Doc);
  finally
    Doc.Free;
  end;
end;

end.
