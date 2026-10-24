unit test_split;
{ Asserts the process split's unit boundary: the transitive `uses` closure of the
  client roots (the TUI app, the remote driver, the session view) reaches none of
  the agent/server units, and the headless runtime reaches no TUI unit. FPC links
  every unit in a `uses` closure, so this source-level walk is what keeps the two
  binaries apart when no symbol happens to be referenced. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry;

type
  TSplitBoundaryTest = class(TTestCase)
  published
    procedure TestClientClosureExcludesAgent;
    procedure TestHeadlessClosureExcludesTui;
    procedure TestAsyncClosureIsStandalone;
    procedure TestEveryLibraryUnitIsResolvable;
  end;

implementation

type
  TScanState = (csCode, csBrace, csParen, csLine);

const
  SrcDir = 'src';
  TuiPrefix = 'tui.';
  HeadlessRoot = 'hildegard.helper.session.runtime';
  { Units a client (the TUI) must never link. }
  ForbiddenForClient: array[0..7] of string = (
    'hildegard.helper.agent',
    'hildegard.helper.harness.session',
    'hildegard.helper.harness.turn.worker',
    'hildegard.helper.command.tool',
    'hildegard.helper.files',
    'hildegard.helper.recall.tool',
    'hildegard.helper.session.store',
    'hildegard.helper.session.runtime');
  ClientRoots: array[0..2] of string = (
    'hildegard.helper.harness.app',
    'hildegard.helper.harness.driver',
    'hildegard.helper.harness.view');

{ Strip brace, paren-star, and line comments so `uses` scanning sees code. }
function StripComments(const AText: string): string;
var
  I, N: Integer;
  State: TScanState;
begin
  Result := '';
  I := 1;
  N := Length(AText);
  State := csCode;
  while I <= N do
  begin
    case State of
      csCode:
        if AText[I] = '{' then
          State := csBrace
        else if (AText[I] = '(') and (I < N) and (AText[I + 1] = '*') then
        begin
          State := csParen;
          Inc(I);
        end
        else if (AText[I] = '/') and (I < N) and (AText[I + 1] = '/') then
        begin
          State := csLine;
          Inc(I);
        end
        else
          Result := Result + AText[I];
      csBrace:
        if AText[I] = '}' then
          State := csCode;
      csParen:
        if (AText[I] = '*') and (I < N) and (AText[I + 1] = ')') then
        begin
          State := csCode;
          Inc(I);
        end;
      csLine:
        if AText[I] = #10 then
        begin
          State := csCode;
          Result := Result + #10;
        end;
    end;
    Inc(I);
  end;
end;

function IsNameChar(C: Char): Boolean;
begin
  Result := C in ['A'..'Z', 'a'..'z', '0'..'9', '_', '.'];
end;

{ The unit names in every `uses` clause of APath. }
function ExtractUses(const APath: string): TStringList;
var
  F: TFileStream;
  Raw, Text, Tok: string;
  I, N: Integer;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  F := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Raw, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Raw[1], F.Size);
  finally
    F.Free;
  end;
  Text := StripComments(Raw);
  N := Length(Text);
  I := 1;
  while I <= N do
  begin
    if (UpCase(Text[I]) = 'U') and (I + 3 <= N) and
      (UpperCase(Copy(Text, I, 4)) = 'USES') and
      ((I = 1) or (not IsNameChar(Text[I - 1]))) and
      ((I + 4 > N) or (not IsNameChar(Text[I + 4]))) then
    begin
      Inc(I, 4);
      Tok := '';
      while (I <= N) and (Text[I] <> ';') do
      begin
        if IsNameChar(Text[I]) then
          Tok := Tok + Text[I]
        else
        begin
          if (Tok <> '') and (Pos('.', Tok) > 0) then
            Result.Add(LowerCase(Tok));
          Tok := '';
        end;
        Inc(I);
      end;
      if (Tok <> '') and (Pos('.', Tok) > 0) then
        Result.Add(LowerCase(Tok));
    end;
    Inc(I);
  end;
end;

{ The source path of a project unit: `src/<unit>.pas`, or one of the library
  subdirectories, whose unit names carry the directory as a namespace
  (`async.*`, `shell.*`, `changes.*`, `fileignore.*`, `tui.*`, `tui.widgets.*`).

  A missing path here is SILENT: the closure walk simply stops, and the
  boundary assertion passes vacuously. So if this list drifts from the tree the
  test keeps reporting green while checking nothing. `TestEveryLibraryUnitIs
  Resolvable` pins that. }
function UnitPath(const AUnitName: string): string;
const
  LibDirs: array[0..4] of string = (
    'async', 'shell', 'changes', 'fileignore', 'tui/core');
  WidgetDir = 'tui/widgets';
var
  I: Integer;
begin
  Result := IncludeTrailingPathDelimiter(SrcDir) + AUnitName + '.pas';
  if FileExists(Result) then
    Exit;
  for I := Low(LibDirs) to High(LibDirs) do
  begin
    Result := IncludeTrailingPathDelimiter(SrcDir) +
      IncludeTrailingPathDelimiter(LibDirs[I]) + AUnitName + '.pas';
    if FileExists(Result) then
      Exit;
  end;
  Result := IncludeTrailingPathDelimiter(SrcDir) +
    IncludeTrailingPathDelimiter(WidgetDir) + AUnitName + '.pas';
end;

{ Every unit reachable from ARoot through `uses`, following only project units. }
function CollectClosure(const ARoot: string): TStringList;
var
  Queue: TStringList;
  U, Path: string;
  I: Integer;
  Deps: TStringList;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  Queue := TStringList.Create;
  try
    Queue.Add(ARoot);
    while Queue.Count > 0 do
    begin
      U := Queue[0];
      Queue.Delete(0);
      if Result.IndexOf(U) >= 0 then
        Continue;
      Result.Add(U);
      Path := UnitPath(U);
      if not FileExists(Path) then
        Continue;
      Deps := ExtractUses(Path);
      try
        for I := 0 to Deps.Count - 1 do
          Queue.Add(Deps[I]);
      finally
        Deps.Free;
      end;
    end;
  finally
    Queue.Free;
  end;
end;

procedure TSplitBoundaryTest.TestClientClosureExcludesAgent;
var
  I, J: Integer;
  Closure: TStringList;
begin
  AssertTrue('src/ is readable from ' + GetCurrentDir, DirectoryExists(SrcDir));
  for I := Low(ClientRoots) to High(ClientRoots) do
  begin
    Closure := CollectClosure(ClientRoots[I]);
    try
      AssertTrue('closure is non-trivial for ' + ClientRoots[I],
        Closure.Count > 5);
      for J := Low(ForbiddenForClient) to High(ForbiddenForClient) do
        AssertTrue(ForbiddenForClient[J] + ' reachable from ' + ClientRoots[I],
          Closure.IndexOf(ForbiddenForClient[J]) < 0);
    finally
      Closure.Free;
    end;
  end;
end;

procedure TSplitBoundaryTest.TestHeadlessClosureExcludesTui;
var
  I: Integer;
  Closure: TStringList;
begin
  AssertTrue('src/ is readable from ' + GetCurrentDir, DirectoryExists(SrcDir));
  Closure := CollectClosure(HeadlessRoot);
  try
    AssertTrue('closure is non-trivial', Closure.Count > 5);
    for I := 0 to Closure.Count - 1 do
      AssertFalse('TUI unit reachable from the headless agent: ' + Closure[I],
        Copy(Closure[I], 1, Length(TuiPrefix)) = TuiPrefix);
  finally
    Closure.Free;
  end;
end;

procedure TSplitBoundaryTest.TestEveryLibraryUnitIsResolvable;
const
  Dirs: array[0..5] of string = (
    'async', 'shell', 'changes', 'fileignore', 'tui/core', 'tui/widgets');
var
  I: Integer;
  SR: TSearchRec;
  Dir, UnitName, Actual: string;
begin
  { A unit UnitPath cannot resolve makes CollectClosure stop early, and every
    boundary assertion then passes on a truncated closure. That failure is
    SILENT - it reports green while checking less. So pin the mapping directly:
    every file in every library directory must resolve to itself. }
  for I := Low(Dirs) to High(Dirs) do
  begin
    Dir := IncludeTrailingPathDelimiter(SrcDir) +
      IncludeTrailingPathDelimiter(Dirs[I]);
    AssertTrue(Dir + ' is readable from ' + GetCurrentDir, DirectoryExists(Dir));
    if FindFirst(Dir + '*.pas', faAnyFile, SR) <> 0 then
    begin
      AssertTrue('no .pas files in ' + Dir, False);
      Continue;
    end;
    try
      repeat
        UnitName := ChangeFileExt(SR.Name, '');
        Actual := UnitPath(UnitName);
        AssertEquals('UnitPath must resolve ' + UnitName + ' to its own file',
          Dir + SR.Name, Actual);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
end;

procedure TSplitBoundaryTest.TestAsyncClosureIsStandalone;
var
  I, J: Integer;
  Closure: TStringList;
  Roots: array[0..6] of string;
  IsHarness: Boolean;
begin
  Roots[0] := 'async.base';
  Roots[1] := 'async.scheduler';
  Roots[2] := 'async.queue';
  Roots[3] := 'async.future';
  Roots[4] := 'async.timers';
  Roots[5] := 'async.observable';
  Roots[6] := 'async.subject';
  AssertTrue('src/async is readable', DirectoryExists(SrcDir));
  for I := Low(Roots) to High(Roots) do
  begin
    Closure := CollectClosure(Roots[I]);
    try
      AssertTrue('async unit exists: ' + Roots[I], Closure.Count > 0);
      for J := 0 to Closure.Count - 1 do
      begin
        IsHarness := Copy(Closure[J], 1, Length('hildegard')) = 'hildegard';
        AssertFalse('the async library reached a harness unit: ' + Closure[J] +
          ' (from ' + Roots[I] + ')', IsHarness);
      end;
    finally
      Closure.Free;
    end;
  end;
end;

initialization
  RegisterTest(TSplitBoundaryTest);
end.