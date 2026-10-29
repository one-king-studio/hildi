unit hildi.env;
{ Minimal .env loader. Parses NAME=VALUE lines and applies them to the process
  environment without overriding variables that are already set (the safe
  precedence for secrets). Parsing is a pure function; applying is separate. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TEnvPair = record
    Name: string;
    Value: string;
  end;

  TEnvPairArray = array of TEnvPair;

function ParseDotEnv(const AText: string): TEnvPairArray;
function ApplyEnv(const APairs: TEnvPairArray): Integer;
function LoadDotEnvFile(const APath: string): Integer;

{ Read AName, falling back to the pre-rename spelling when it is unset, so an
  operator's existing .env or shell profile keeps working across the rename.
  HILDI_LLM_MODEL falls back to HILDEGARD_LLM_MODEL. The new name always wins,
  which lets a setting be migrated one variable at a time. }
function GetEnvLegacy(const AName: string): string;

implementation

uses
  Classes, ctypes;

{$ifdef unix}
function c_setenv(Name, Value: PAnsiChar; Overwrite: cint): cint; cdecl;
  external 'c' name 'setenv';
{$endif}

function SetProcessEnv(const AName, AValue: string): Boolean;
begin
  {$ifdef unix}
  Result := c_setenv(PAnsiChar(AnsiString(AName)),
    PAnsiChar(AnsiString(AValue)), 1) = 0;
  {$else}
  Result := False;
  {$endif}
end;

function ParseDotEnv(const AText: string): TEnvPairArray;
const
  SingleQuote = #39;
  DoubleQuote = #34;
var
  Lines: TStringList;
  I, P: Integer;
  Line, Name, Value: string;
begin
  Result := nil;
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if (Line = '') or (Line[1] = '#') then
        Continue;
      if Copy(Line, 1, 7) = 'export ' then
        Line := Trim(Copy(Line, 8, MaxInt));
      P := Pos('=', Line);
      if P <= 0 then
        Continue;
      Name := Trim(Copy(Line, 1, P - 1));
      Value := Trim(Copy(Line, P + 1, MaxInt));
      if Name = '' then
        Continue;
      if (Length(Value) >= 2) and
        (((Value[1] = SingleQuote) and (Value[Length(Value)] = SingleQuote)) or
         ((Value[1] = DoubleQuote) and (Value[Length(Value)] = DoubleQuote))) then
        Value := Copy(Value, 2, Length(Value) - 2);
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)].Name := Name;
      Result[High(Result)].Value := Value;
    end;
  finally
    Lines.Free;
  end;
end;

function ApplyEnv(const APairs: TEnvPairArray): Integer;
var
  I: Integer;
  Alias: string;
begin
  Result := 0;
  for I := 0 to High(APairs) do
  begin
    if APairs[I].Name = '' then
      Continue;
    if GetEnvironmentVariable(APairs[I].Name) <> '' then
      Continue;                       // never override the shell
    if not SetProcessEnv(APairs[I].Name, APairs[I].Value) then
      Continue;
    Inc(Result);
    { A .env written before the Hildi rename still says HILDEGARD_*. Alias each
      such name to its HILDI_ spelling so an existing file keeps working, and a
      file may mix old and new freely. The new spelling always wins: an alias is
      only written when the target is still unset. }
    if Copy(APairs[I].Name, 1, 10) = 'HILDEGARD_' then
    begin
      Alias := 'HILDI_' + Copy(APairs[I].Name, 11, MaxInt);
      if GetEnvironmentVariable(Alias) = '' then
        SetProcessEnv(Alias, APairs[I].Value);
    end;
  end;
end;

function LoadDotEnvFile(const APath: string): Integer;
var
  Content: TStringList;
begin
  Result := 0;
  if (APath = '') or not FileExists(APath) then
    Exit;
  Content := TStringList.Create;
  try
    try
      Content.LoadFromFile(APath);
      Result := ApplyEnv(ParseDotEnv(Content.Text));
    except
      on E: Exception do
        Result := 0;               // a bad .env must never crash startup
    end;
  finally
    Content.Free;
  end;
end;

function GetEnvLegacy(const AName: string): string;
var
  Legacy: string;
begin
  Result := GetEnvironmentVariable(AName);
  if Result <> '' then
    Exit;                          // the new spelling always wins
  { HILDI_<REST> -> HILDEGARD_<REST>. Only names carrying the prefix are
    candidates, so a stray call cannot accidentally read an unrelated var. }
  if Copy(AName, 1, 6) <> 'HILDI_' then
    Exit;
  Legacy := 'HILDEGARD_' + Copy(AName, 7, MaxInt);
  Result := GetEnvironmentVariable(Legacy);
end;

end.
