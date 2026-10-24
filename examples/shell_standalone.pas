program shell_standalone;
{ The isolation and behaviour smoke for the shell library. It uses ONLY
  src/shell plus the RTL: the build puts no harness unit on the search path, so
  a dependency on one fails here.

  It implements the two seams a consumer must supply (a file system and a
  handler registry with a gate), then parses and runs a handful of scripts. }

{$mode delphi}{$H+}

uses
  SysUtils, Classes,
  shell.types, shell.ast, shell.parser, shell.fs, shell.registry, shell.interpreter;

type
  THostFs = class(TInterfacedObject, IShellFileSystem)
  public
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
  end;

function THostFs.Resolve(const ACwd, APath: string): string;
begin
  if (APath <> '') and (APath[1] = '/') then
    Result := APath
  else
    Result := IncludeTrailingPathDelimiter(ACwd) + APath;
  Result := ExpandFileName(Result);
end;

function THostFs.ReadFile(const APath: string; out AData, AError: string): Boolean;
var
  Fs: TFileStream;
  Size: Integer;
begin
  AData := '';
  AError := '';
  try
    try
      Fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
      try
        Size := Fs.Size;
        SetLength(AData, Size);
        if Size > 0 then
          Fs.ReadBuffer(AData[1], Size);
      finally
        Fs.Free;
      end;
      Result := True;
    except
      on E: Exception do
      begin
        AError := E.Message;
        Result := False;
      end;
    end;
  except
    AError := 'read failed';
    Result := False;
  end;
end;

function THostFs.WriteFile(const APath, AData: string; AAppend: Boolean;
  out AError: string): Boolean;
var
  Fs: TFileStream;
  Mode: Word;
begin
  AError := '';
  try
    try
      if AAppend then
        Mode := fmOpenWrite or fmShareDenyNone
      else
        Mode := fmCreate;
      Fs := TFileStream.Create(APath, Mode);
      try
        if AAppend then
          Fs.Seek(0, soEnd);
        if AData <> '' then
          Fs.WriteBuffer(AData[1], Length(AData));
      finally
        Fs.Free;
      end;
      Result := True;
    except
      on E: Exception do
      begin
        AError := E.Message;
        Result := False;
      end;
    end;
  except
    AError := 'write failed';
    Result := False;
  end;
end;

function THostFs.ListDir(const APath: string; out AEntries: TStringArray;
  out AError: string): Boolean;
var
  R: TSearchRec;
  List: TStringList;
  I: Integer;
begin
  AEntries := nil;
  AError := '';
  List := TStringList.Create;
  try
    try
      if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, R) = 0 then
      try
        repeat
          if (R.Name <> '.') and (R.Name <> '..') then
            List.Add(R.Name);
        until FindNext(R) <> 0;
      finally
        FindClose(R);
      end;
      List.Sort;
      SetLength(AEntries, List.Count);
      for I := 0 to List.Count - 1 do
        AEntries[I] := List[I];
      Result := True;
    except
      on E: Exception do
      begin
        AError := E.Message;
        Result := False;
      end;
    end;
  finally
    List.Free;
  end;
end;

function THostFs.Info(const APath: string; out AInfo: TShellFileInfo;
  out AError: string): Boolean;
begin
  AInfo := Default(TShellFileInfo);
  if not Stat(APath, AInfo.Kind, AError) then
    Exit(False);
  AInfo.Mode := $1A4;
  AInfo.Size := 0;
  AInfo.Modified := 0;
  Result := True;
end;

function THostFs.Symlink(const ATarget, ALinkPath: string;
  out AError: string): Boolean;
begin
  { The demo host is a real filesystem, so this works where the platform allows
    it. Unix only - Windows needs privilege, and the demo does not model that. }
  {$ifdef unix}
  AError := '';
  if fpSymlink(PChar(ATarget), PChar(ALinkPath)) = 0 then
    Exit(True);
  AError := 'symlink failed';
  Result := False;
  {$else}
  AError := 'symlinks are not supported here';
  Result := False;
  {$endif}
end;

function THostFs.ReadLink(const APath: string; out ATarget,
  AError: string): Boolean;
var
  Buf: array[0..4095] of Char;
  N: Integer;
begin
  ATarget := '';
  AError := '';
  {$ifdef unix}
  N := fpReadlink(PChar(APath), @Buf[0], SizeOf(Buf) - 1);
  if N < 0 then
  begin
    AError := 'not a symlink';
    Exit(False);
  end;
  Buf[N] := #0;
  ATarget := string(PChar(@Buf[0]));
  Result := True;
  {$else}
  AError := 'symlinks are not supported here';
  Result := False;
  {$endif}
end;

function THostFs.SetMode(const APath: string; AMode: LongWord;
  out AError: string): Boolean;
begin
  AError := '';
  {$ifdef unix}
  Result := fpChmod(PChar(APath), AMode) = 0;
  if not Result then
    AError := 'chmod failed';
  {$else}
  Result := True;
  {$endif}
end;

function THostFs.Stat(const APath: string; out AKind: TShellFileKind;
  out AError: string): Boolean;
begin
  AError := '';
  if DirectoryExists(APath) then
    AKind := sfkDirectory
  else if FileExists(APath) then
    AKind := sfkFile
  else
  begin
    AKind := sfkMissing;
    AError := 'no such file or directory';
    Exit(False);
  end;
  Result := True;
end;

type
  TStandalone = class
  public
    Fs: IShellFileSystem;
    Registry: TShellRegistry;
    Shell: TShell;
    Allowed: Boolean;
    constructor Create(const ACwd: string);
    destructor Destroy; override;
    function Echo(const ACall: TShellCall): TShellResult;
    function Cat(const ACall: TShellCall): TShellResult;
    function Upper(const ACall: TShellCall): TShellResult;
    function Boom(const ACall: TShellCall): TShellResult;
    function Gate(const ACall: TShellCall): Boolean;
    procedure Run(const ASource: string);
  end;

constructor TStandalone.Create(const ACwd: string);
var
  Env: TShellEnv;
begin
  inherited Create;
  Fs := THostFs.Create;
  Registry := TShellRegistry.Create;
  Registry.Register('echo', Echo);
  Registry.Register('cat', Cat);
  Registry.Register('upper', Upper);
  Registry.Register('fail', Boom);
  Env := TShellEnv.Create;
  Env.SetValue('HOME', ACwd);
  Allowed := True;
  Shell := TShell.Create(Registry, Fs, ACwd, Gate, DefaultShellLimits, Env);
end;

destructor TStandalone.Destroy;
begin
  Shell.Free;
  Registry.Free;
  inherited Destroy;
end;

function TStandalone.Gate(const ACall: TShellCall): Boolean;
begin
  Result := Allowed;
end;

function TStandalone.Echo(const ACall: TShellCall): TShellResult;
var
  I: Integer;
  S: string;
begin
  S := '';
  for I := 0 to High(ACall.Args) do
  begin
    if S <> '' then
      S := S + ' ';
    S := S + ACall.Args[I];
  end;
  Result := ShellResultOk(S + #10);
end;

function TStandalone.Cat(const ACall: TShellCall): TShellResult;
var
  I: Integer;
  Data, E: string;
begin
  if Length(ACall.Args) = 0 then
    Exit(ShellResultOk(ACall.Stdin));
  Result := ShellResultOk('');
  for I := 0 to High(ACall.Args) do
  begin
    if not Fs.ReadFile(Fs.Resolve(ACall.Cwd, ACall.Args[I]), Data, E) then
      Exit(ShellResultErr('cat: ' + ACall.Args[I] + ': ' + E + #10, 1));
    Result.Stdout := Result.Stdout + Data;
  end;
end;

function TStandalone.Upper(const ACall: TShellCall): TShellResult;
begin
  Result := ShellResultOk(UpperCase(ACall.Stdin));
end;

function TStandalone.Boom(const ACall: TShellCall): TShellResult;
begin
  Result := ShellResultErr('fail: boom' + #10, 7);
end;

procedure TStandalone.Run(const ASource: string);
var
  OutText, ErrText: string;
  Status: Integer;
begin
  Status := Shell.RunSource(ASource, OutText, ErrText);
  WriteLn('$ ', StringReplace(ASource, #10, ' ', [rfReplaceAll]));
  if OutText <> '' then
    Write(OutText);
  if ErrText <> '' then
    Write(ErrText);
  WriteLn('[exit ', Status, ']');
  WriteLn;
end;

function MakeTempWorkspace: string;
var
  Dir: string;
begin
  Dir := GetTempDir(False) + 'shell-standalone-' + IntToStr(Random(1000000));
  ForceDirectories(Dir);
  Result := Dir;
end;

var
  App: TStandalone;
  Dir: string;
  F: TStringList;
begin
  Dir := MakeTempWorkspace;
  try
    F := TStringList.Create;
    try
      F.Text := 'alpha';
      F.SaveToFile(Dir + '/one.txt');
      F.Text := 'beta';
      F.SaveToFile(Dir + '/two.txt');
    finally
      F.Free;
    end;
    App := TStandalone.Create(Dir);
    try
      App.Run('echo hello world');
      App.Run('for f in *.txt; do echo $f; done');
      App.Run('cat one.txt | upper');
      App.Run('if cat one.txt; then echo yes; else echo no; fi');
      App.Run('f() { echo $1; }; f x');
      App.Run('echo written > out.txt; cat out.txt');
      App.Run('echo a && echo b || echo c');
      App.Run('fail || echo recovered');
      App.Run('while false; do echo never; done; echo done');
      App.Run('case two.txt in *.md) echo md;; *.txt) echo txt;; esac');
      App.Run('cat missing.txt; echo after');
      App.Allowed := False;
      App.Run('echo denied');
      App.Allowed := True;
      App.Run('echo $(date)');
    finally
      App.Free;
    end;
  finally
    DeleteFile(Dir + '/one.txt');
    DeleteFile(Dir + '/two.txt');
    DeleteFile(Dir + '/out.txt');
    RemoveDir(Dir);
  end;
end.
