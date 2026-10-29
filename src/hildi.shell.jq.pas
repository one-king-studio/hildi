unit hildi.shell.jq;
{ A path-oriented jq subset for the builtin shell tier.

  Supported filters: `.`, `.name`, `.name.name`, `.[N]` (negative too), `.[]`,
  `.["key"]` / `."key"`, and chains of those. `-r` prints strings raw, `-c`
  prints compact JSON; the default is jq's two-space pretty output.

  Pipes, `select`, `map`, variables, functions and arithmetic are not
  supported: a filter outside the subset is a filter error, never an
  approximation. fpjson does the parsing; this unit owns only the path walk
  and the writer (fpjson's AsJSON is spaced, jq's is not). }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, fpjson;

{ Evaluate AFilter over one JSON document. False + AError on a filter error or
  malformed input. }
function RunJq(const AFilter, AInput: string; ARaw, ACompact: Boolean;
  out AOutput, AError: string): Boolean;

implementation

uses
  jsonparser;

type
  TSegKind = (skKey, skIndex, skIterate);

  TSegment = record
    Kind: TSegKind;
    Name: string;
    Index: Integer;
  end;

  TSegments = array of TSegment;

function ParseFilter(const AFilter: string; out ASegs: TSegments;
  out AError: string): Boolean;
var
  I, Start: Integer;
  Name: string;

  function ParseQuoted(const S: string; var P: Integer; out AValue: string): Boolean;
  begin
    AValue := '';
    Result := False;
    if (P > Length(S)) or (S[P] <> '"') then
      Exit;
    Inc(P);
    while (P <= Length(S)) and (S[P] <> '"') do
    begin
      if S[P] = '\' then
      begin
        Inc(P);
        if P > Length(S) then
          Exit;
        AValue := AValue + S[P];
        Inc(P);
      end
      else
      begin
        AValue := AValue + S[P];
        Inc(P);
      end;
    end;
    if P > Length(S) then
      Exit;
    Inc(P);
    Result := True;
  end;

  procedure AddKey(const AName: string);
  begin
    SetLength(ASegs, Length(ASegs) + 1);
    ASegs[High(ASegs)].Kind := skKey;
    ASegs[High(ASegs)].Name := AName;
  end;

begin
  ASegs := nil;
  AError := '';
  Result := False;
  if (AFilter = '') or (AFilter[1] <> '.') then
  begin
    AError := 'only path filters are supported (start with ".")';
    Exit;
  end;
  I := 2;
  if (I <= Length(AFilter)) and ((AFilter[I] = '"') or
    (AFilter[I] in ['a'..'z', 'A'..'Z', '_'])) then
  begin
    if AFilter[I] = '"' then
    begin
      if not ParseQuoted(AFilter, I, Name) then
      begin
        AError := 'unterminated key';
        Exit;
      end;
    end
    else
    begin
      Start := I;
      while (I <= Length(AFilter)) and
        (AFilter[I] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) do
        Inc(I);
      Name := Copy(AFilter, Start, I - Start);
    end;
    AddKey(Name);
  end;
  while I <= Length(AFilter) do
  begin
    if AFilter[I] = '.' then
    begin
      Inc(I);
      if (I <= Length(AFilter)) and (AFilter[I] = '"') then
      begin
        if not ParseQuoted(AFilter, I, Name) then
        begin
          AError := 'unterminated key';
          Exit;
        end;
        AddKey(Name);
      end
      else
      begin
        Start := I;
        while (I <= Length(AFilter)) and
          (AFilter[I] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) do
          Inc(I);
        if I = Start then
        begin
          AError := 'empty key in filter';
          Exit;
        end;
        AddKey(Copy(AFilter, Start, I - Start));
      end;
    end
    else if AFilter[I] = '[' then
    begin
      Inc(I);
      if (I <= Length(AFilter)) and (AFilter[I] = ']') then
      begin
        Inc(I);
        SetLength(ASegs, Length(ASegs) + 1);
        ASegs[High(ASegs)].Kind := skIterate;
      end
      else if (I <= Length(AFilter)) and (AFilter[I] = '"') then
      begin
        if not ParseQuoted(AFilter, I, Name) then
        begin
          AError := 'unterminated key';
          Exit;
        end;
        if (I > Length(AFilter)) or (AFilter[I] <> ']') then
        begin
          AError := 'expected "]"';
          Exit;
        end;
        Inc(I);
        AddKey(Name);
      end
      else
      begin
        Start := I;
        if (I <= Length(AFilter)) and (AFilter[I] = '-') then
          Inc(I);
        while (I <= Length(AFilter)) and (AFilter[I] in ['0'..'9']) do
          Inc(I);
        if (I = Start) or ((I = Start + 1) and (AFilter[Start] = '-')) then
        begin
          AError := 'expected an array index';
          Exit;
        end;
        if (I > Length(AFilter)) or (AFilter[I] <> ']') then
        begin
          AError := 'expected "]"';
          Exit;
        end;
        SetLength(ASegs, Length(ASegs) + 1);
        ASegs[High(ASegs)].Kind := skIndex;
        ASegs[High(ASegs)].Index :=
          StrToIntDef(Copy(AFilter, Start, I - Start), 0);
        Inc(I);
      end;
    end
    else
    begin
      AError := 'unsupported filter: ' + AFilter;
      Exit;
    end;
  end;
  Result := True;
end;

function JsonQuote(const S: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '"';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    case C of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      if C < ' ' then
        Result := Result + '\u' + IntToHex(Ord(C), 4)
      else
        Result := Result + C;
    end;
  end;
  Result := Result + '"';
end;

function Pad(AIndent: Integer): string;
begin
  Result := StringOfChar(' ', AIndent);
end;

function WriteValue(D: TJSONData; APretty: Boolean; AIndent: Integer): string;
var
  I: Integer;
begin
  if D = nil then
    Exit('null');
  case D.JSONType of
    jtNull: Result := 'null';
    jtBoolean:
      if D.AsBoolean then
        Result := 'true'
      else
        Result := 'false';
    jtNumber: Result := D.AsJSON;
    jtString: Result := JsonQuote(D.AsString);
    jtArray:
      begin
        if TJSONArray(D).Count = 0 then
          Exit('[]');
        Result := '[';
        for I := 0 to TJSONArray(D).Count - 1 do
        begin
          if I > 0 then
            Result := Result + ',';
          if APretty then
            Result := Result + #10 + Pad(AIndent + 2);
          Result := Result + WriteValue(TJSONArray(D).Items[I], APretty,
            AIndent + 2);
        end;
        if APretty then
          Result := Result + #10 + Pad(AIndent);
        Result := Result + ']';
      end;
    jtObject:
      begin
        if TJSONObject(D).Count = 0 then
          Exit('{}');
        Result := '{';
        for I := 0 to TJSONObject(D).Count - 1 do
        begin
          if I > 0 then
            Result := Result + ',';
          if APretty then
            Result := Result + #10 + Pad(AIndent + 2);
          Result := Result + JsonQuote(TJSONObject(D).Names[I]) + ':';
          if APretty then
            Result := Result + ' ';
          Result := Result + WriteValue(TJSONObject(D).Items[I], APretty,
            AIndent + 2);
        end;
        if APretty then
          Result := Result + #10 + Pad(AIndent);
        Result := Result + '}';
      end;
  else
    Result := 'null';
  end;
end;

function RunJq(const AFilter, AInput: string; ARaw, ACompact: Boolean;
  out AOutput, AError: string): Boolean;
var
  Segs: TSegments;
  Data: TJSONData;
  Candidates, Next: array of TJSONData;
  I, J, K: Integer;
  V, Found: TJSONData;
begin
  AOutput := '';
  AError := '';
  Result := False;
  if not ParseFilter(AFilter, Segs, AError) then
    Exit;
  Data := nil;
  try
    try
      Data := GetJSON(AInput);
    except
      on E: Exception do
      begin
        AError := 'parse error: ' + E.Message;
        Exit;
      end;
    end;
    SetLength(Candidates, 1);
    Candidates[0] := Data;
    for I := 0 to High(Segs) do
    begin
      Next := nil;
      for J := 0 to High(Candidates) do
      begin
        V := Candidates[J];
        case Segs[I].Kind of
          skKey:
            begin
              Found := nil;
              if (V <> nil) and (V.JSONType = jtObject) then
                TJSONObject(V).Find(Segs[I].Name, Found);
              SetLength(Next, Length(Next) + 1);
              Next[High(Next)] := Found;
            end;
          skIndex:
            begin
              Found := nil;
              if (V <> nil) and (V.JSONType = jtArray) then
              begin
                K := Segs[I].Index;
                if K < 0 then
                  K := TJSONArray(V).Count + K;
                if (K >= 0) and (K < TJSONArray(V).Count) then
                  Found := TJSONArray(V).Items[K];
              end;
              SetLength(Next, Length(Next) + 1);
              Next[High(Next)] := Found;
            end;
          skIterate:
            begin
              if (V <> nil) and (V.JSONType = jtArray) then
              begin
                for K := 0 to TJSONArray(V).Count - 1 do
                begin
                  SetLength(Next, Length(Next) + 1);
                  Next[High(Next)] := TJSONArray(V).Items[K];
                end;
              end
              else if (V <> nil) and (V.JSONType = jtObject) then
              begin
                for K := 0 to TJSONObject(V).Count - 1 do
                begin
                  SetLength(Next, Length(Next) + 1);
                  Next[High(Next)] := TJSONObject(V).Items[K];
                end;
              end
              else
              begin
                AError := 'cannot iterate over a non-array, non-object value';
                Exit;
              end;
            end;
        end;
      end;
      Candidates := Next;
    end;
    for J := 0 to High(Candidates) do
    begin
      V := Candidates[J];
      if ARaw and (V <> nil) and (V.JSONType = jtString) then
        AOutput := AOutput + V.AsString + #10
      else
        AOutput := AOutput + WriteValue(V, not ACompact, 0) + #10;
    end;
    Result := True;
  finally
    Data.Free;
  end;
end;

end.
