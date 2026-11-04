unit HildiEnv;
{ Application environment policy.

  THE PRIMITIVES MOVED TO THE LIBRARY. Parsing a .env, applying it, and reading
  a variable with the pre-rename fallback are provider-library concerns and now
  live in src/llm/LLMEnv.pas. This unit re-exports them so every existing caller
  and test is unchanged, and adds the policy that is genuinely application-level:
  where the store file lives.

  That split is what keeps src/llm/ free of the application's filesystem layout,
  which is the whole point of the library. Kept as a re-export rather than a
  copy: two implementations of "never override the shell" would drift. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, LLMEnv;

type
  { Re-exported so a caller that already names these types keeps compiling
    against the same declarations the library uses. }
  TEnvPair = LLMEnv.TEnvPair;
  TEnvPairArray = LLMEnv.TEnvPairArray;

function ParseDotEnv(const AText: string): TEnvPairArray;
function ApplyEnv(const APairs: TEnvPairArray): Integer;
function LoadDotEnvFile(const APath: string): Integer;

{ Read AName, falling back to the pre-rename spelling when it is unset. }
function GetEnvLegacy(const AName: string): string;

{ Read a variable through the layer this unit writes through. }
function GetProcessEnv(const AName: string): string;

{ The default store path: HILDI_STORE_PATH when set, else the user's data
  directory (XDG_DATA_HOME, defaulting to ~/.local/share/hildi). Falls back to
  the two older locations -- ~/.hildi and the pre-rename ~/.hildegard-helper --
  while the new one holds no database, so a move never presents an empty store
  as a lost history. }
function DefaultStorePath: string;

{ The XDG data directory, with a trailing delimiter: AXdgDataHome when it is an
  absolute path (the spec requires absolute; a relative value is ignored), else
  AHome + '/.local/share/'. A pure function so the policy is testable. }
function DataHome(const AXdgDataHome, AHome: string): string;

{ The store-path decision with every input explicit, so it is testable without
  touching $HOME or the filesystem. The three booleans say whether the new, the
  ~/.hildi, and the pre-rename store already exist. }
function ResolveStorePath(const AEnvValue, AXdgDataHome, AHome: string;
  ANewExists, AHildiExists, ALegacyExists: Boolean): string;

implementation

function ParseDotEnv(const AText: string): TEnvPairArray;
begin
  Result := LLMEnv.ParseDotEnv(AText);
end;

function ApplyEnv(const APairs: TEnvPairArray): Integer;
begin
  Result := LLMEnv.ApplyEnv(APairs);
end;

function LoadDotEnvFile(const APath: string): Integer;
begin
  Result := LLMEnv.LoadDotEnvFile(APath);
end;

function GetEnvLegacy(const AName: string): string;
begin
  Result := LLMEnv.GetEnvLegacy(AName);
end;

function GetProcessEnv(const AName: string): string;
begin
  Result := LLMEnv.GetProcessEnv(AName);
end;

function DataHome(const AXdgDataHome, AHome: string): string;
begin
  { XDG requires an absolute path; a relative value is ignored per the spec,
    which is what stops `XDG_DATA_HOME=foo` scattering stores per-cwd. }
  if (AXdgDataHome <> '') and (AXdgDataHome[1] = PathDelim) then
    Exit(IncludeTrailingPathDelimiter(AXdgDataHome));
  Result := IncludeTrailingPathDelimiter(AHome) + '.local' + PathDelim +
    'share' + PathDelim;
end;

function ResolveStorePath(const AEnvValue, AXdgDataHome, AHome: string;
  ANewExists, AHildiExists, ALegacyExists: Boolean): string;
var
  NewPath, HildiPath, LegacyPath: string;
begin
  if AEnvValue <> '' then
    Exit(AEnvValue);
  NewPath := DataHome(AXdgDataHome, AHome) + 'hildi' + PathDelim + 'store.db';
  HildiPath := IncludeTrailingPathDelimiter(AHome) + '.hildi' + PathDelim +
    'store.db';
  LegacyPath := IncludeTrailingPathDelimiter(AHome) + '.hildegard-helper' +
    PathDelim + 'store.db';
  { Newest first, then each older home in turn, so moving the store is always
    "copy the file" and never "discover your history is gone". }
  if ANewExists then
    Exit(NewPath);
  if AHildiExists then
    Exit(HildiPath);
  if ALegacyExists then
    Exit(LegacyPath);
  Result := NewPath;
end;

function DefaultStorePath: string;
var
  Home, HildiPath, LegacyPath: string;
begin
  Home := GetUserDir;
  HildiPath := IncludeTrailingPathDelimiter(Home) + '.hildi' + PathDelim +
    'store.db';
  LegacyPath := IncludeTrailingPathDelimiter(Home) + '.hildegard-helper' +
    PathDelim + 'store.db';
  Result := ResolveStorePath(GetEnvLegacy('HILDI_STORE_PATH'),
    GetEnvLegacy('XDG_DATA_HOME'), Home,
    FileExists(DataHome(GetEnvLegacy('XDG_DATA_HOME'), Home) + 'hildi' +
      PathDelim + 'store.db'),
    FileExists(HildiPath), FileExists(LegacyPath));
end;

end.
