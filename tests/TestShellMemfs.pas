unit TestShellMemfs;
{ A small in-memory IShellFileSystem shared by the shell tests. Paths are
  normalized; directories are inferred from the files plus explicit AddDir. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Generics.Collections, ShellFs;

type
  TMemoryFs = class(TInterfacedObject, IShellFileSystem)
  private
    FFiles: TDictionary<string, string>;
    FDirs: TStringList;
    function Normalize(const APath: string): string;
    function ParentOf(const APath: string): string;
    function BaseNameOf(const APath: string): string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddFile(const APath, AContent: string);
    procedure AddDir(const APath: string);
    function FileText(const APath: string): string;
    function HasFile(const APath: string): Boolean;
    function Resolve(const ACwd, APath: string): string;
    function ReadFile(const APath: string; out AData, AError: string): Boolean;
    function WriteFile(const APath, AData: string; AAppend: Boolean;
      out AError: string): Boolean;
    function ListDir(const APath: string; out AEntries: TStringArray;
      out AError: string): Boolean;
    function Stat(const APath: string; out AKind: TShellFileKind;
      out AError: string): Boolean;
    function Info(const APath: string; out AInfo: TShellFileInfo;
      out AError: string): Boolean;
    { Symlinks are not modelled in memory; SetMode is a no-op. }
    function Symlink(const ATarget, ALinkPath: string;
      out AError: string): Boolean;
    function ReadLink(const APath: string; out ATarget, AError: string): Boolean;
    function SetMode(const APath: string; AMode: LongWord;
      out AError: string): Boolean;
  end;

implementation

function SplitPath(const S: string): TStringArray;
var
  P, Q, N: Integer;
begin
  Result := nil;
  N := 0;
  P := 1;
  while P <= Length(S) + 1 do
  begin
    Q := P;
    while (Q <= Length(S)) and (S[Q] <> '/') do
      Inc(Q);
    SetLength(Result, N + 1);
    Result[N] := Copy(S, P, Q - P);
    Inc(N);
    P := Q + 1;
  end;
end;

constructor TMemoryFs.Create;
begin
  inherited Create;
  FFiles := TDictionary<string, string>.Create;
  FDirs := TStringList.Create;
  FDirs.CaseSensitive := True;
  FDirs.Sorted := True;
  FDirs.Duplicates := dupIgnore;
  FDirs.Add('/');
end;

destructor TMemoryFs.Destroy;
begin
  FDirs.Free;
  FFiles.Free;
  inherited Destroy;
end;

function TMemoryFs.Normalize(const APath: string): string;
var
  Segs: TStringArray;
  Stack: TStringArray;
  I: Integer;
begin
  Segs := SplitPath(APath);
  Stack := nil;
  for I := 0 to High(Segs) do
  begin
    if (Segs[I] = '') or (Segs[I] = '.') then
      Continue;
    if Segs[I] = '..' then
    begin
      if Length(Stack) > 0 then
        SetLength(Stack, Length(Stack) - 1);
    end
    else
    begin
      SetLength(Stack, Length(Stack) + 1);
      Stack[High(Stack)] := Segs[I];
    end;
  end;
  Result := '/';
  for I := 0 to High(Stack) do
  begin
    if I > 0 then
      Result := Result + '/';
    Result := Result + Stack[I];
  end;
end;

function TMemoryFs.ParentOf(const APath: string): string;
var
  P: Integer;
begin
  P := Length(APath);
  while (P > 1) and (APath[P] <> '/') do
    Dec(P);
  if P <= 1 then
    Result := '/'
  else
    Result := Copy(APath, 1, P - 1);
end;

function TMemoryFs.BaseNameOf(const APath: string): string;
var
  P: Integer;
begin
  P := Length(APath);
  while (P > 1) and (APath[P] <> '/') do
    Dec(P);
  Result := Copy(APath, P + 1, MaxInt);
end;

procedure TMemoryFs.AddDir(const APath: string);
var
  P: string;
begin
  P := Normalize(APath);
  FDirs.Add(P);
  if P <> '/' then
    AddDir(ParentOf(P));
end;

procedure TMemoryFs.AddFile(const APath, AContent: string);
var
  P: string;
begin
  P := Normalize(APath);
  FFiles.AddOrSetValue(P, AContent);
  AddDir(ParentOf(P));
end;

function TMemoryFs.FileText(const APath: string): string;
begin
  if not FFiles.TryGetValue(Normalize(APath), Result) then
    Result := '';
end;

function TMemoryFs.HasFile(const APath: string): Boolean;
begin
  Result := FFiles.ContainsKey(Normalize(APath));
end;

function TMemoryFs.Resolve(const ACwd, APath: string): string;
begin
  if (APath <> '') and (APath[1] = '/') then
    Result := Normalize(APath)
  else if APath = '' then
    Result := Normalize(ACwd)
  else
    Result := Normalize(ACwd + '/' + APath);
end;

function TMemoryFs.ReadFile(const APath: string; out AData, AError: string): Boolean;
begin
  AData := '';
  AError := '';
  if FFiles.TryGetValue(Normalize(APath), AData) then
    Result := True
  else
  begin
    AError := 'no such file or directory';
    Result := False;
  end;
end;

function TMemoryFs.WriteFile(const APath, AData: string; AAppend: Boolean;
  out AError: string): Boolean;
var
  P, Old: string;
begin
  AError := '';
  P := Normalize(APath);
  if AAppend and FFiles.TryGetValue(P, Old) then
    FFiles.AddOrSetValue(P, Old + AData)
  else
    FFiles.AddOrSetValue(P, AData);
  AddDir(ParentOf(P));
  Result := True;
end;

function TMemoryFs.ListDir(const APath: string; out AEntries: TStringArray;
  out AError: string): Boolean;
var
  P, Key: string;
  Names: TStringList;
  I: Integer;
begin
  AEntries := nil;
  AError := '';
  P := Normalize(APath);
  if (P <> '/') and (not FDirs.IndexOf(P) >= 0) then
  begin
    AError := 'not a directory';
    Exit(False);
  end;
  Names := TStringList.Create;
  try
    Names.CaseSensitive := True;
    Names.Sorted := True;
    Names.Duplicates := dupIgnore;
    for Key in FFiles.Keys do
      if ParentOf(Key) = P then
        Names.Add(BaseNameOf(Key));
    for I := 0 to FDirs.Count - 1 do
      if (FDirs[I] <> P) and (ParentOf(FDirs[I]) = P) then
        Names.Add(BaseNameOf(FDirs[I]));
    SetLength(AEntries, Names.Count);
    for I := 0 to Names.Count - 1 do
      AEntries[I] := Names[I];
    Result := True;
  finally
    Names.Free;
  end;
end;

function TMemoryFs.Info(const APath: string; out AInfo: TShellFileInfo;
  out AError: string): Boolean;
var
  P, Data: string;
begin
  AInfo := Default(TShellFileInfo);
  if not Stat(APath, AInfo.Kind, AError) then
    Exit(False);
  P := Normalize(APath);
  if AInfo.Kind = sfkFile then
  begin
    if FFiles.TryGetValue(P, Data) then
      AInfo.Size := Length(Data);
    AInfo.Mode := $1A4;   // 0644
  end
  else
    AInfo.Mode := $1ED;   // 0755
  AInfo.Modified := 0;
  Result := True;
end;

function TMemoryFs.Symlink(const ATarget, ALinkPath: string;
  out AError: string): Boolean;
begin
  { Not modelled in memory: refusing is honest, and no test needs it. }
  AError := 'symlinks are not supported by the memory filesystem';
  Result := False;
end;

function TMemoryFs.ReadLink(const APath: string; out ATarget,
  AError: string): Boolean;
begin
  ATarget := '';
  AError := 'symlinks are not supported by the memory filesystem';
  Result := False;
end;

function TMemoryFs.SetMode(const APath: string; AMode: LongWord;
  out AError: string): Boolean;
begin
  AError := '';
  Result := True;   // in-memory entries carry no meaningful mode
end;

function TMemoryFs.Stat(const APath: string; out AKind: TShellFileKind;
  out AError: string): Boolean;
var
  P: string;
begin
  AError := '';
  P := Normalize(APath);
  if FFiles.ContainsKey(P) then
  begin
    AKind := sfkFile;
    Exit(True);
  end;
  if FDirs.IndexOf(P) >= 0 then
  begin
    AKind := sfkDirectory;
    Exit(True);
  end;
  AKind := sfkMissing;
  AError := 'no such file or directory';
  Result := False;
end;

end.
