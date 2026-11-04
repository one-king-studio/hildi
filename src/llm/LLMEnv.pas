unit LLMEnv;
{ Process-environment primitives for the provider library.

  WHY THIS EXISTS SEPARATELY FROM HildiEnv: HildiEnv carries application policy —
  the default store path, the XDG data directory, the whole store-location
  fallback chain. None of that is a provider concern, and a library that reached
  for it would drag the application's filesystem layout into every consumer.

  What a provider library genuinely needs is four things: parse a .env, apply it,
  read a variable through the same layer that wrote it, and read a variable with
  the pre-rename spelling as a fallback.

  THIS IS A MOVE, NOT A FORK. HildiEnv keeps its policy functions and re-exports
  these from here, so there is one implementation and the application does not
  change. }

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

{ Parse NAME=VALUE lines. Pure: nothing is applied, so a caller can inspect or
  test a .env without touching the process environment. }
function ParseDotEnv(const AText: string): TEnvPairArray;

{ Apply parsed pairs WITHOUT overriding a variable that is already set - the safe
  precedence for secrets, because a shell export must beat a checked-out file. }
function ApplyEnv(const APairs: TEnvPairArray): Integer;

{ Parse and apply a .env file. Returns the number applied; 0 when absent. }
function LoadDotEnvFile(const APath: string): Integer;

{ Read AName, falling back to the pre-rename spelling when it is unset, so an
  operator's existing .env or shell profile keeps working across the rename.
  HILDI_LLM_MODEL falls back to HILDEGARD_LLM_MODEL. The new name always wins. }
function GetEnvLegacy(const AName: string): string;

{ Read a variable through the same layer this unit writes through (libc getenv
  on unix). The RTL's GetEnvironmentVariable reads the envp snapshot from process
  start, which on FPC/aarch64-linux does not see a value set later by setenv. }
function GetProcessEnv(const AName: string): string;

{ Set a variable through the same layer GetProcessEnv reads. }
function SetProcessEnv(const AName, AValue: string): Boolean;

implementation

uses
  Classes, ctypes;

{$ifdef unix}
function c_setenv(Name, Value: PAnsiChar; Overwrite: cint): cint; cdecl;
  external 'c' name 'setenv';
function c_getenv(Name: PAnsiChar): PAnsiChar; cdecl; external 'c' name 'getenv';
{$endif}

function GetProcessEnv(const AName: string): string;
{$ifdef unix}
var
  P: PAnsiChar;
begin
  P := c_getenv(PAnsiChar(AnsiString(AName)));
  if P = nil then
    Result := ''
  else
    Result := string(AnsiString(P));
end;
{$else}
begin
  Result := GetEnvironmentVariable(AName);
end;
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
  I, Eq: Integer;
  Line, Name, Value: string;
  N: Integer;

  { Strip surrounding quotes of either kind and any UTF-8 BOM on the first line. }
  function Unquote(const S: string): string;
  begin
    Result := S;
    if (Length(Result) >= 2) and
      (((Result[1] = SingleQuote) and (Result[Length(Result)] = SingleQuote)) or
       ((Result[1] = DoubleQuote) and (Result[Length(Result)] = DoubleQuote))) then
      Result := Copy(Result, 2, Length(Result) - 2);
  end;

begin
  Result := nil;
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    N := 0;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if I = 0 then
        Line := StringReplace(Line, #$EF#$BB#$BF, '', []);
      if (Line = '') or (Line[1] = '#') then
        Continue;
      if Copy(Line, 1, 7) = 'export ' then
        Line := Trim(Copy(Line, 8, MaxInt));
      Eq := Pos('=', Line);
      if Eq <= 1 then
        Continue;
      Name := Trim(Copy(Line, 1, Eq - 1));
      Value := Unquote(Trim(Copy(Line, Eq + 1, MaxInt)));
      if Name = '' then
        Continue;
      SetLength(Result, N + 1);
      Result[N].Name := Name;
      Result[N].Value := Value;
      Inc(N);
    end;
  finally
    Lines.Free;
  end;
end;

function ApplyEnv(const APairs: TEnvPairArray): Integer;
var
  I: Integer;
  Alias: string;
  Applied: Integer;
begin
  Applied := 0;
  for I := 0 to High(APairs) do
  begin
    { Never override: a shell export beats a checked-out file. }
    if GetProcessEnv(APairs[I].Name) <> '' then
      Continue;
    { An old spelling in the file applies to the NEW name when it is unset, so a
      pre-rename .env keeps working. }
    Alias := APairs[I].Name;
    if Copy(Alias, 1, 10) = 'HILDEGARD_' then
      Alias := 'HILDI_' + Copy(Alias, 11, MaxInt);
    if (Alias <> APairs[I].Name) and (GetProcessEnv(Alias) <> '') then
      Continue;
    if SetProcessEnv(Alias, APairs[I].Value) then
      Inc(Applied);
  end;
  Result := Applied;
end;

function LoadDotEnvFile(const APath: string): Integer;
var
  Lines: TStringList;
begin
  Result := 0;
  if not FileExists(APath) then
    Exit;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(APath);
    except
      Exit;
    end;
    Result := ApplyEnv(ParseDotEnv(Lines.Text));
  finally
    Lines.Free;
  end;
end;

function GetEnvLegacy(const AName: string): string;
var
  Legacy: string;
begin
  Result := GetProcessEnv(AName);
  if Result <> '' then
    Exit;                          // the new spelling always wins
  { HILDI_<REST> -> HILDEGARD_<REST>. Only names carrying the prefix are
    candidates, so a stray call cannot accidentally read an unrelated var. }
  if Copy(AName, 1, 6) <> 'HILDI_' then
    Exit;
  Legacy := 'HILDEGARD_' + Copy(AName, 7, MaxInt);
  Result := GetProcessEnv(Legacy);
end;

end.
