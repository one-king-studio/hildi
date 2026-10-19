unit hildegard.helper.shell.commands;
{ The closed command set of the builtin shell tier.

  Every command is a TShellHandler over the workspace filesystem. The tier's
  pre-flight uses the option table here to decline a script whose literal flags
  a command does not support, so an unsupported flag never produces a silent
  semantic difference: the whole script goes to the process tier instead.

  `tool` and `mcp` call back into the harness's normal tool resolution; the
  tier refuses shell-entry tools, and the dispatched tool still passes its own
  approval gate. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, shell.types, shell.fs, hildegard.helper.shell.fs;

type
  { The harness's normal tool resolution: (name, args JSON, inherited reason)
    -> the tool's result text or its error. }
  TShellToolInvoke = function(const AName, AArgumentsJson, AReason: string;
    out AResult, AError: string): Boolean of object;

  TBuiltinCommands = class
  private
    FFs: TWorkspaceShellFs;
    FInvoke: TShellToolInvoke;
    FAllowed: TStringArray;
    FReason: string;
    function Usage(const AMsg: string): TShellResult;
    function Failure(const AMsg: string; AStatus: Integer): TShellResult;
    function ToolAllowed(const AName: string): Boolean;
    function InvokeTool(const AName, AJson: string): TShellResult;
  public
    constructor Create(AFs: TWorkspaceShellFs; AInvoke: TShellToolInvoke;
      const AAllowedTools: TStringArray);
    { The reason the current run inherited; injected into tool arguments. }
    property Reason: string read FReason write FReason;
    { The command set. }
    function Echo(const ACall: TShellCall): TShellResult;
    function Cat(const ACall: TShellCall): TShellResult;
    function Head(const ACall: TShellCall): TShellResult;
    function Tail(const ACall: TShellCall): TShellResult;
    function Wc(const ACall: TShellCall): TShellResult;
    function Grep(const ACall: TShellCall): TShellResult;
    function Ls(const ACall: TShellCall): TShellResult;
    function Mkdir(const ACall: TShellCall): TShellResult;
    function Rm(const ACall: TShellCall): TShellResult;
    function Mv(const ACall: TShellCall): TShellResult;
    function Cp(const ACall: TShellCall): TShellResult;
    function Touch(const ACall: TShellCall): TShellResult;
    function SortCmd(const ACall: TShellCall): TShellResult;
    function Uniq(const ACall: TShellCall): TShellResult;
    function Basename(const ACall: TShellCall): TShellResult;
    function Dirname(const ACall: TShellCall): TShellResult;
    function TestCmd(const ACall: TShellCall): TShellResult;
    function Bracket(const ACall: TShellCall): TShellResult;
    function TrueCmd(const ACall: TShellCall): TShellResult;
    function FalseCmd(const ACall: TShellCall): TShellResult;
    function Tool(const ACall: TShellCall): TShellResult;
    function Mcp(const ACall: TShellCall): TShellResult;
  end;

{ The option flags a command supports (e.g. '-n'), or '' when it takes none.
  False when AName is not a builtin command. }
function BuiltinCommandOptions(const AName: string; out AOptions: string): Boolean;

{ True when the name is one of the tier's commands. }
function IsBuiltinCommand(const AName: string): Boolean;

{ True when the pattern contains a regular-expression metacharacter. }
function HasRegexMeta(const APattern: string): Boolean;

{ True when a literal argument is an option the command does not support.
  A combined short flag is decomposed (-rf -> r, f); '--' is always allowed;
  a long option is unsupported. An empty AOptions means "no options at all". }
function IsUnsupportedOption(const AArg, AOptions: string): Boolean;

implementation

uses
  BaseUnix, fpjson, jsonparser,
  shell.interpreter, hildegard.helper.mcp.client;

const
  DefaultLines = 10;
  RegexMeta = '.[]*^$\+?(){}|';

type
  TCommandSpec = record
    Name: string;
    Options: string;
  end;

const
  CommandSpecs: array[0..21] of TCommandSpec = (
    (Name: 'echo'; Options: '-n'),
    (Name: 'head'; Options: '-n'),
    (Name: 'tail'; Options: '-n'),
    (Name: 'wc'; Options: '-lwc'),
    (Name: 'grep'; Options: '-nivlcF'),
    (Name: 'ls'; Options: '-ad'),
    (Name: 'mkdir'; Options: '-p'),
    (Name: 'rm'; Options: '-rf'),
    (Name: 'sort'; Options: '-ru'),
    (Name: 'uniq'; Options: '-cdu'),
    (Name: 'cat'; Options: ''),
    (Name: 'mv'; Options: ''),
    (Name: 'cp'; Options: ''),
    (Name: 'touch'; Options: ''),
    (Name: 'basename'; Options: ''),
    (Name: 'dirname'; Options: ''),
    (Name: 'test'; Options: ''),
    (Name: '['; Options: ''),
    (Name: 'true'; Options: ''),
    (Name: 'false'; Options: ''),
    (Name: 'tool'; Options: ''),
    (Name: 'mcp'; Options: ''));

function BuiltinCommandOptions(const AName: string; out AOptions: string): Boolean;
var
  I: Integer;
begin
  AOptions := '';
  for I := 0 to High(CommandSpecs) do
    if CommandSpecs[I].Name = AName then
    begin
      AOptions := CommandSpecs[I].Options;
      Exit(True);
    end;
  Result := False;
end;

function IsBuiltinCommand(const AName: string): Boolean;
var
  Dummy: string;
begin
  Result := BuiltinCommandOptions(AName, Dummy);
end;

function IsUnsupportedOption(const AArg, AOptions: string): Boolean;
var
  I: Integer;
  Ch: Char;
begin
  if (AArg = '') or (AArg[1] <> '-') or (AArg = '-') or (AArg = '--') then
    Exit(False);
  if AOptions = '' then
    Exit(True);
  if (Length(AArg) > 2) and (AArg[2] = '-') then
    Exit(True);   // long options are not supported anywhere
  for I := 2 to Length(AArg) do
  begin
    Ch := AArg[I];
    if Pos(Ch, AOptions) = 0 then
      Exit(True);
  end;
  Result := False;
end;

function LinesOf(const S: string): TStringArray;
var
  I, N, K: Integer;
begin
  Result := nil;
  K := 0;
  I := 1;
  while I <= Length(S) do
  begin
    N := I;
    while (N <= Length(S)) and (S[N] <> #10) do
      Inc(N);
    SetLength(Result, K + 1);
    Result[K] := Copy(S, I, N - I);
    Inc(K);
    I := N + 1;
  end;
end;

function JoinLines(const ALines: TStringArray; AStart, ACount: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := AStart to AStart + ACount - 1 do
    if (I >= 0) and (I <= High(ALines)) then
      Result := Result + ALines[I] + #10;
end;

function JoinArgs(const AArgs: TStringArray; AStart: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := AStart to High(AArgs) do
  begin
    if I > AStart then
      Result := Result + ' ';
    Result := Result + AArgs[I];
  end;
end;

function EnsureTrailingNewline(const S: string): string;
begin
  if (S <> '') and (S[Length(S)] <> #10) then
    Result := S + #10
  else
    Result := S;
end;

function HasRegexMeta(const APattern: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to Length(APattern) do
    if Pos(APattern[I], RegexMeta) > 0 then
      Exit(True);
  Result := False;
end;

function IsWordChar(C: Char): Boolean;
begin
  Result := not (C in [' ', #9, #10, #13]);
end;

procedure CountText(const S: string; out ALines, AWords, ABytes: Integer);
var
  I: Integer;
begin
  ALines := 0;
  AWords := 0;
  ABytes := Length(S);
  I := 1;
  while I <= Length(S) do
  begin
    if S[I] = #10 then
      Inc(ALines);
    Inc(I);
  end;
  I := 1;
  while I <= Length(S) do
  begin
    while (I <= Length(S)) and (not IsWordChar(S[I])) do
      Inc(I);
    if I <= Length(S) then
      Inc(AWords);
    while (I <= Length(S)) and IsWordChar(S[I]) do
      Inc(I);
  end;
end;

constructor TBuiltinCommands.Create(AFs: TWorkspaceShellFs;
  AInvoke: TShellToolInvoke; const AAllowedTools: TStringArray);
begin
  inherited Create;
  FFs := AFs;
  FInvoke := AInvoke;
  FAllowed := AAllowedTools;
end;

function TBuiltinCommands.Usage(const AMsg: string): TShellResult;
begin
  Result := ShellResultErr(AMsg + #10, 2);
end;

function TBuiltinCommands.Failure(const AMsg: string; AStatus: Integer): TShellResult;
begin
  Result := ShellResultErr(AMsg + #10, AStatus);
end;

function TBuiltinCommands.Echo(const ACall: TShellCall): TShellResult;
var
  I, Start: Integer;
  S: string;
  Newline: Boolean;
begin
  Newline := True;
  Start := 0;
  if (Length(ACall.Args) > 0) and (ACall.Args[0] = '-n') then
  begin
    Newline := False;
    Start := 1;
  end;
  S := '';
  for I := Start to High(ACall.Args) do
  begin
    if I > Start then
      S := S + ' ';
    S := S + ACall.Args[I];
  end;
  if Newline then
    S := S + #10;
  Result := ShellResultOk(S);
end;

function TBuiltinCommands.Cat(const ACall: TShellCall): TShellResult;
var
  I: Integer;
  Data, E: string;
begin
  Result := Default(TShellResult);
  if Length(ACall.Args) = 0 then
    Exit(ShellResultOk(ACall.Stdin));
  for I := 0 to High(ACall.Args) do
  begin
    if ACall.Args[I] = '-' then
      Result.Stdout := Result.Stdout + ACall.Stdin
    else if not FFs.ReadFile(FFs.Resolve(ACall.Cwd, ACall.Args[I]), Data, E) then
    begin
      Result.Stderr := Result.Stderr + 'cat: ' + ACall.Args[I] + ': ' + E + #10;
      Result.ExitCode := 1;
    end
    else
      Result.Stdout := Result.Stdout + Data;
  end;
end;

function TBuiltinCommands.Head(const ACall: TShellCall): TShellResult;
var
  I, N, Start: Integer;
  Args: TStringArray;
  Data, E, Text: string;
  Lines: TStringArray;
begin
  N := DefaultLines;
  I := 0;
  while I <= High(ACall.Args) do
  begin
    if ACall.Args[I] = '-n' then
    begin
      if I = High(ACall.Args) then
        Exit(Usage('head: option requires an argument -- n'));
      N := StrToIntDef(ACall.Args[I + 1], -1);
      if N < 0 then
        Exit(Usage('head: invalid number of lines: ' + ACall.Args[I + 1]));
      Inc(I, 2);
    end
    else
      Break;
  end;
  SetLength(Args, Length(ACall.Args) - I);
  Start := I;
  while I <= High(ACall.Args) do
  begin
    Args[I - Start] := ACall.Args[I];
    Inc(I);
  end;
  if Length(Args) > 1 then
    Exit(Usage('head: only one file is supported'));
  if Length(Args) = 0 then
    Text := ACall.Stdin
  else if not FFs.ReadFile(FFs.Resolve(ACall.Cwd, Args[0]), Data, E) then
    Exit(Failure('head: ' + Args[0] + ': ' + E, 1))
  else
    Text := Data;
  Lines := LinesOf(Text);
  if N > Length(Lines) then
    N := Length(Lines);
  Result := ShellResultOk(JoinLines(Lines, 0, N));
end;

function TBuiltinCommands.Tail(const ACall: TShellCall): TShellResult;
var
  I, N, Start: Integer;
  Args: TStringArray;
  Data, E, Text: string;
  Lines: TStringArray;
begin
  N := DefaultLines;
  I := 0;
  while I <= High(ACall.Args) do
  begin
    if ACall.Args[I] = '-n' then
    begin
      if I = High(ACall.Args) then
        Exit(Usage('tail: option requires an argument -- n'));
      N := StrToIntDef(ACall.Args[I + 1], -1);
      if N < 0 then
        Exit(Usage('tail: invalid number of lines: ' + ACall.Args[I + 1]));
      Inc(I, 2);
    end
    else
      Break;
  end;
  SetLength(Args, Length(ACall.Args) - I);
  Start := I;
  while I <= High(ACall.Args) do
  begin
    Args[I - Start] := ACall.Args[I];
    Inc(I);
  end;
  if Length(Args) > 1 then
    Exit(Usage('tail: only one file is supported'));
  if Length(Args) = 0 then
    Text := ACall.Stdin
  else if not FFs.ReadFile(FFs.Resolve(ACall.Cwd, Args[0]), Data, E) then
    Exit(Failure('tail: ' + Args[0] + ': ' + E, 1))
  else
    Text := Data;
  Lines := LinesOf(Text);
  if N > Length(Lines) then
    N := Length(Lines);
  Start := Length(Lines) - N;
  if Start < 0 then
    Start := 0;
  Result := ShellResultOk(JoinLines(Lines, Start, N));
end;

function TBuiltinCommands.Wc(const ACall: TShellCall): TShellResult;
var
  I, J, P, L, W, C, TL, TW, TC: Integer;
  ShowL, ShowW, ShowC: Boolean;
  Args, Fields: TStringArray;
  Data, E, Text, Line: string;
  PerFile: TStringList;
  AnyFlag: Boolean;

  function Format(const AL, AW, AC: Integer; const AName: string): string;
  var
    S: string;
  begin
    S := '';
    if ShowL then
      S := S + IntToStr(AL);
    if ShowW then
    begin
      if S <> '' then S := S + ' ';
      S := S + IntToStr(AW);
    end;
    if ShowC then
    begin
      if S <> '' then S := S + ' ';
      S := S + IntToStr(AC);
    end;
    if AName <> '' then
      S := S + ' ' + AName;
    Result := S;
  end;

begin
  ShowL := False;
  ShowW := False;
  ShowC := False;
  AnyFlag := False;
  I := 0;
  while I <= High(ACall.Args) do
  begin
    if (ACall.Args[I] <> '') and (ACall.Args[I][1] = '-') and
      (ACall.Args[I] <> '-') then
    begin
      AnyFlag := True;
      for J := 2 to Length(ACall.Args[I]) do
        case ACall.Args[I][J] of
          'l': ShowL := True;
          'w': ShowW := True;
          'c': ShowC := True;
        end;
      Inc(I);
    end
    else
      Break;
  end;
  if not AnyFlag then
  begin
    ShowL := True;
    ShowW := True;
    ShowC := True;
  end;
  SetLength(Args, Length(ACall.Args) - I);
  P := I;
  while I <= High(ACall.Args) do
  begin
    Args[I - P] := ACall.Args[I];
    Inc(I);
  end;
  PerFile := TStringList.Create;
  try
    TL := 0;
    TW := 0;
    TC := 0;
    if Length(Args) = 0 then
    begin
      CountText(ACall.Stdin, L, W, C);
      Result := ShellResultOk(Format(L, W, C, '') + #10);
      Exit;
    end;
    for I := 0 to High(Args) do
    begin
      if not FFs.ReadFile(FFs.Resolve(ACall.Cwd, Args[I]), Data, E) then
      begin
        Result := Failure('wc: ' + Args[I] + ': ' + E, 1);
        Exit;
      end;
      CountText(Data, L, W, C);
      Inc(TL, L);
      Inc(TW, W);
      Inc(TC, C);
      PerFile.Add(Format(L, W, C, Args[I]));
    end;
    if Length(Args) > 1 then
      PerFile.Add(Format(TL, TW, TC, 'total'));
    Line := '';
    for I := 0 to PerFile.Count - 1 do
      Line := Line + PerFile[I] + #10;
    Result := ShellResultOk(Line);
  finally
    PerFile.Free;
  end;
end;

function TBuiltinCommands.Grep(const ACall: TShellCall): TShellResult;
var
  I, J, P, LineNo, MatchCount: Integer;
  ShowN, IgnoreCase, Invert, ListOnly, CountOnly, Fixed: Boolean;
  Args: TStringArray;
  Pattern, Data, E, Text: string;
  Lines: TStringArray;
  OutText, ErrText: string;
  Status: Integer;
  Multiple: Boolean;

  function Matches(const ALine: string): Boolean;
  var
    Hay, Needle: string;
  begin
    Hay := ALine;
    Needle := Pattern;
    if IgnoreCase then
    begin
      Hay := LowerCase(Hay);
      Needle := LowerCase(Needle);
    end;
    if Pos(Needle, Hay) > 0 then
      Result := not Invert
    else
      Result := Invert;
  end;

  procedure ScanStream(const AText, AName: string; AShowName: Boolean);
  var
    K, Count: Integer;
    Ls: TStringArray;
  begin
    Ls := LinesOf(AText);
    Count := 0;
    for K := 0 to High(Ls) do
      if Matches(Ls[K]) then
      begin
        Inc(Count);
        if ListOnly or CountOnly then
          Continue;
        if AShowName then
          OutText := OutText + AName + ':';
        if ShowN then
          OutText := OutText + IntToStr(K + 1) + ':';
        OutText := OutText + Ls[K] + #10;
      end;
    if Count > 0 then
      Status := 0;
    if ListOnly and (Count > 0) then
      OutText := OutText + AName + #10;
    if CountOnly then
    begin
      if AShowName then
        OutText := OutText + AName + ':';
      OutText := OutText + IntToStr(Count) + #10;
    end;
  end;

begin
  ShowN := False;
  IgnoreCase := False;
  Invert := False;
  ListOnly := False;
  CountOnly := False;
  Fixed := False;
  I := 0;
  while I <= High(ACall.Args) do
  begin
    if ACall.Args[I] = '--' then
    begin
      Inc(I);
      Break;
    end;
    if (ACall.Args[I] <> '') and (ACall.Args[I][1] = '-') and
      (ACall.Args[I] <> '-') then
    begin
      for J := 2 to Length(ACall.Args[I]) do
        case ACall.Args[I][J] of
          'n': ShowN := True;
          'i': IgnoreCase := True;
          'v': Invert := True;
          'l': ListOnly := True;
          'c': CountOnly := True;
          'F': Fixed := True;
        end;
      Inc(I);
    end
    else
      Break;
  end;
  if I > High(ACall.Args) then
    Exit(Usage('grep: no pattern'));
  Pattern := ACall.Args[I];
  Inc(I);
  if (not Fixed) and HasRegexMeta(Pattern) then
    Exit(Usage('grep: pattern uses a regular expression; the builtin shell ' +
      'matches fixed strings only (use -F)'));
  SetLength(Args, Length(ACall.Args) - I);
  P := I;
  while I <= High(ACall.Args) do
  begin
    Args[I - P] := ACall.Args[I];
    Inc(I);
  end;
  Multiple := Length(Args) > 1;
  OutText := '';
  ErrText := '';
  Status := 1;
  LineNo := 0;
  if Length(Args) = 0 then
    ScanStream(ACall.Stdin, '', False)
  else
    for J := 0 to High(Args) do
    begin
      if Args[J] = '-' then
        Text := ACall.Stdin
      else if not FFs.ReadFile(FFs.Resolve(ACall.Cwd, Args[J]), Data, E) then
      begin
        ErrText := ErrText + 'grep: ' + Args[J] + ': ' + E + #10;
        Status := 2;
        Continue;
      end
      else
        Text := Data;
      ScanStream(Text, Args[J], Multiple);
    end;
  Result.Stdout := OutText;
  Result.Stderr := ErrText;
  Result.ExitCode := Status;
end;

function TBuiltinCommands.Ls(const ACall: TShellCall): TShellResult;
var
  I, J: Integer;
  All, DirOnly: Boolean;
  Args: TStringArray;
  Target, E: string;
  Entries: TStringArray;
  Kind: TShellFileKind;
  OutText: string;
begin
  All := False;
  DirOnly := False;
  I := 0;
  while I <= High(ACall.Args) do
  begin
    if (ACall.Args[I] <> '') and (ACall.Args[I][1] = '-') and
      (ACall.Args[I] <> '-') then
    begin
      for J := 2 to Length(ACall.Args[I]) do
        case ACall.Args[I][J] of
          'a': All := True;
          'd': DirOnly := True;
        end;
      Inc(I);
    end
    else
      Break;
  end;
  SetLength(Args, Length(ACall.Args) - I);
  J := I;
  while I <= High(ACall.Args) do
  begin
    Args[I - J] := ACall.Args[I];
    Inc(I);
  end;
  if Length(Args) > 1 then
    Exit(Usage('ls: only one path is supported'));
  if Length(Args) = 0 then
    Target := ACall.Cwd
  else
    Target := FFs.Resolve(ACall.Cwd, Args[0]);
  OutText := '';
  if not FFs.Stat(Target, Kind, E) then
    Exit(Failure('ls: ' + Args[0] + ': ' + E, 2));
  if DirOnly or (Kind <> sfkDirectory) then
  begin
    if Length(Args) = 0 then
      Exit(ShellResultOk(ACall.Cwd + #10));
    Exit(ShellResultOk(Args[0] + #10));
  end;
  if not FFs.ListDir(Target, Entries, E) then
    Exit(Failure('ls: ' + Args[0] + ': ' + E, 2));
  for I := 0 to High(Entries) do
  begin
    if (not All) and (Entries[I] <> '') and (Entries[I][1] = '.') then
      Continue;
    OutText := OutText + Entries[I] + #10;
  end;
  Result := ShellResultOk(OutText);
end;

function TBuiltinCommands.Mkdir(const ACall: TShellCall): TShellResult;
var
  I, J: Integer;
  Parents: Boolean;
  E: string;
  Paths: TStringArray;
begin
  Parents := False;
  I := 0;
  if (Length(ACall.Args) > 0) and (ACall.Args[0] = '-p') then
  begin
    Parents := True;
    I := 1;
  end;
  if I > High(ACall.Args) then
    Exit(Usage('mkdir: missing operand'));
  SetLength(Paths, Length(ACall.Args) - I);
  J := I;
  while I <= High(ACall.Args) do
  begin
    Paths[I - J] := ACall.Args[I];
    Inc(I);
  end;
  Result := Default(TShellResult);
  for I := 0 to High(Paths) do
    if not FFs.MakeDir(FFs.Resolve(ACall.Cwd, Paths[I]), Parents, E) then
    begin
      Result.Stderr := Result.Stderr + 'mkdir: ' + Paths[I] + ': ' + E + #10;
      Result.ExitCode := 1;
    end;
end;

function TBuiltinCommands.Rm(const ACall: TShellCall): TShellResult;
var
  I, J: Integer;
  Recursive, Force: Boolean;
  E: string;
  Paths: TStringArray;
  Path: string;
begin
  Recursive := False;
  Force := False;
  I := 0;
  while I <= High(ACall.Args) do
  begin
    if (ACall.Args[I] <> '') and (ACall.Args[I][1] = '-') and
      (ACall.Args[I] <> '-') then
    begin
      for J := 2 to Length(ACall.Args[I]) do
        case ACall.Args[I][J] of
          'r': Recursive := True;
          'f': Force := True;
        end;
      Inc(I);
    end
    else
      Break;
  end;
  if I > High(ACall.Args) then
  begin
    if Force then
      Exit(ShellResultOk(''));
    Exit(Usage('rm: missing operand'));
  end;
  SetLength(Paths, Length(ACall.Args) - I);
  J := I;
  while I <= High(ACall.Args) do
  begin
    Paths[I - J] := ACall.Args[I];
    Inc(I);
  end;
  Result := Default(TShellResult);
  for I := 0 to High(Paths) do
  begin
    Path := FFs.Resolve(ACall.Cwd, Paths[I]);
    if (not Recursive) and DirectoryExists(Path) then
    begin
      Result.Stderr := Result.Stderr + 'rm: ' + Paths[I] +
        ': is a directory' + #10;
      Result.ExitCode := 1;
      Continue;
    end;
    if not FFs.Delete(Path, Recursive, E) then
    begin
      if Force and (Pos('no such file', E) > 0) then
        Continue;
      Result.Stderr := Result.Stderr + 'rm: ' + Paths[I] + ': ' + E + #10;
      Result.ExitCode := 1;
    end;
  end;
end;

function TBuiltinCommands.Mv(const ACall: TShellCall): TShellResult;
var
  E: string;
begin
  if Length(ACall.Args) <> 2 then
    Exit(Usage('mv: expected a source and a destination'));
  if not FFs.Move(FFs.Resolve(ACall.Cwd, ACall.Args[0]),
    FFs.Resolve(ACall.Cwd, ACall.Args[1]), E) then
    Exit(Failure('mv: ' + E, 1));
  Result := ShellResultOk('');
end;

function TBuiltinCommands.Cp(const ACall: TShellCall): TShellResult;
var
  E: string;
begin
  if Length(ACall.Args) <> 2 then
    Exit(Usage('cp: expected a source and a destination'));
  if not FFs.Copy(FFs.Resolve(ACall.Cwd, ACall.Args[0]),
    FFs.Resolve(ACall.Cwd, ACall.Args[1]), E) then
    Exit(Failure('cp: ' + E, 1));
  Result := ShellResultOk('');
end;

function TBuiltinCommands.Touch(const ACall: TShellCall): TShellResult;
var
  I: Integer;
  E: string;
begin
  if Length(ACall.Args) = 0 then
    Exit(Usage('touch: missing operand'));
  Result := Default(TShellResult);
  for I := 0 to High(ACall.Args) do
    if not FFs.Touch(FFs.Resolve(ACall.Cwd, ACall.Args[I]), E) then
    begin
      Result.Stderr := Result.Stderr + 'touch: ' + ACall.Args[I] + ': ' + E + #10;
      Result.ExitCode := 1;
    end;
end;

function TBuiltinCommands.SortCmd(const ACall: TShellCall): TShellResult;
var
  I, J: Integer;
  Reverse, Unique: Boolean;
  Args: TStringArray;
  Data, E, Text: string;
  Lines: TStringArray;
  List: TStringList;
  OutText: string;
begin
  Reverse := False;
  Unique := False;
  I := 0;
  while I <= High(ACall.Args) do
  begin
    if (ACall.Args[I] <> '') and (ACall.Args[I][1] = '-') and
      (ACall.Args[I] <> '-') then
    begin
      for J := 2 to Length(ACall.Args[I]) do
        case ACall.Args[I][J] of
          'r': Reverse := True;
          'u': Unique := True;
        end;
      Inc(I);
    end
    else
      Break;
  end;
  SetLength(Args, Length(ACall.Args) - I);
  J := I;
  while I <= High(ACall.Args) do
  begin
    Args[I - J] := ACall.Args[I];
    Inc(I);
  end;
  if Length(Args) > 1 then
    Exit(Usage('sort: only one file is supported'));
  if Length(Args) = 0 then
    Text := ACall.Stdin
  else if not FFs.ReadFile(FFs.Resolve(ACall.Cwd, Args[0]), Data, E) then
    Exit(Failure('sort: ' + Args[0] + ': ' + E, 2))
  else
    Text := Data;
  List := TStringList.Create;
  try
    List.CaseSensitive := True;
    Lines := LinesOf(Text);
    for I := 0 to High(Lines) do
      List.Add(Lines[I]);
    List.Sort;
    OutText := '';
    if Reverse then
    begin
      for I := List.Count - 1 downto 0 do
      begin
        if Unique and (I < List.Count - 1) and (List[I] = List[I + 1]) then
          Continue;
        OutText := OutText + List[I] + #10;
      end;
    end
    else
      for I := 0 to List.Count - 1 do
      begin
        if Unique and (I > 0) and (List[I] = List[I - 1]) then
          Continue;
        OutText := OutText + List[I] + #10;
      end;
    Result := ShellResultOk(OutText);
  finally
    List.Free;
  end;
end;

function TBuiltinCommands.Uniq(const ACall: TShellCall): TShellResult;
var
  I, J, Count: Integer;
  ShowCount, OnlyDup, OnlyUnique: Boolean;
  Args: TStringArray;
  Data, E, Text, OutText, Current: string;
  Lines: TStringArray;

  procedure Flush;
  begin
    if Current = '' then
      Exit;
    if OnlyDup and (Count < 2) then
      Exit;
    if OnlyUnique and (Count > 1) then
      Exit;
    if ShowCount then
      OutText := OutText + IntToStr(Count) + ' ' + Current + #10
    else
      OutText := OutText + Current + #10;
  end;

begin
  ShowCount := False;
  OnlyDup := False;
  OnlyUnique := False;
  I := 0;
  while I <= High(ACall.Args) do
  begin
    if (ACall.Args[I] <> '') and (ACall.Args[I][1] = '-') and
      (ACall.Args[I] <> '-') then
    begin
      for J := 2 to Length(ACall.Args[I]) do
        case ACall.Args[I][J] of
          'c': ShowCount := True;
          'd': OnlyDup := True;
          'u': OnlyUnique := True;
        end;
      Inc(I);
    end
    else
      Break;
  end;
  SetLength(Args, Length(ACall.Args) - I);
  J := I;
  while I <= High(ACall.Args) do
  begin
    Args[I - J] := ACall.Args[I];
    Inc(I);
  end;
  if Length(Args) > 1 then
    Exit(Usage('uniq: only one file is supported'));
  if Length(Args) = 0 then
    Text := ACall.Stdin
  else if not FFs.ReadFile(FFs.Resolve(ACall.Cwd, Args[0]), Data, E) then
    Exit(Failure('uniq: ' + Args[0] + ': ' + E, 2))
  else
    Text := Data;
  Lines := LinesOf(Text);
  OutText := '';
  Current := '';
  Count := 0;
  for I := 0 to High(Lines) do
  begin
    if Lines[I] = Current then
      Inc(Count)
    else
    begin
      Flush;
      Current := Lines[I];
      Count := 1;
    end;
  end;
  Flush;
  Result := ShellResultOk(OutText);
end;

function TBuiltinCommands.Basename(const ACall: TShellCall): TShellResult;
var
  S: string;
  P: Integer;
begin
  if (Length(ACall.Args) < 1) or (Length(ACall.Args) > 2) then
    Exit(Usage('basename: expected a path and an optional suffix'));
  S := ACall.Args[0];
  while (Length(S) > 1) and (S[Length(S)] = '/') do
    Delete(S, Length(S), 1);
  P := Length(S);
  while (P > 1) and (S[P] <> '/') do
    Dec(P);
  if S[P] = '/' then
    S := Copy(S, P + 1, MaxInt);
  if (Length(ACall.Args) = 2) and (ACall.Args[1] <> '') and
    (Length(S) > Length(ACall.Args[1])) and
    (Copy(S, Length(S) - Length(ACall.Args[1]) + 1, MaxInt) = ACall.Args[1]) then
    S := Copy(S, 1, Length(S) - Length(ACall.Args[1]));
  Result := ShellResultOk(S + #10);
end;

function TBuiltinCommands.Dirname(const ACall: TShellCall): TShellResult;
var
  S: string;
  P: Integer;
begin
  if Length(ACall.Args) <> 1 then
    Exit(Usage('dirname: expected one path'));
  S := ACall.Args[0];
  while (Length(S) > 1) and (S[Length(S)] = '/') do
    Delete(S, Length(S), 1);
  P := Length(S);
  while (P > 1) and (S[P] <> '/') do
    Dec(P);
  if P <= 1 then
  begin
    if S = '/' then
      Result := ShellResultOk('/' + #10)
    else
      Result := ShellResultOk('.' + #10);
    Exit;
  end;
  S := Copy(S, 1, P - 1);
  while (Length(S) > 1) and (S[Length(S)] = '/') do
    Delete(S, Length(S), 1);
  Result := ShellResultOk(S + #10);
end;

function TBuiltinCommands.TestCmd(const ACall: TShellCall): TShellResult;
var
  A: TStringArray;
  Kind: TShellFileKind;
  E, Op, Left, Right: string;
  I: Int64;
  Fs: TFileStream;
  Inner: TShellCall;
begin
  E := '';
  A := ACall.Args;
  { `[` supplies its closing bracket; the caller strips it. }
  if Length(A) = 0 then
    Exit(ShellResultOk('', 1));
  if Length(A) = 1 then
  begin
    if A[0] <> '' then
      Exit(ShellResultOk('', 0));
    Exit(ShellResultOk('', 1));
  end;
  if (Length(A) = 2) and (A[0] = '!') then
  begin
    if A[1] <> '' then
      Exit(ShellResultOk('', 1));
    Exit(ShellResultOk('', 0));
  end;
  if (Length(A) = 3) and (A[0] = '!') then
  begin
    Inner := ACall;
    SetLength(Inner.Args, 2);
    Inner.Args[0] := A[1];
    Inner.Args[1] := A[2];
    Result := TestCmd(Inner);
    if Result.ExitCode = 0 then
      Result.ExitCode := 1
    else
      Result.ExitCode := 0;
    Exit;
  end;
  if Length(A) = 2 then
  begin
    Op := A[0];
    Left := A[1];
    if Op = '-z' then
    begin
      if Left = '' then Exit(ShellResultOk('', 0)) else Exit(ShellResultOk('', 1));
    end;
    if Op = '-n' then
    begin
      if Left <> '' then Exit(ShellResultOk('', 0)) else Exit(ShellResultOk('', 1));
    end;
    if (Op = '-e') or (Op = '-f') or (Op = '-d') or (Op = '-s') or
      (Op = '-r') or (Op = '-w') or (Op = '-x') then
    begin
      if not FFs.Stat(FFs.Resolve(ACall.Cwd, Left), Kind, E) then
        Exit(ShellResultOk('', 1));
      if Op = '-f' then
      begin
        if Kind = sfkFile then Exit(ShellResultOk('', 0)) else Exit(ShellResultOk('', 1));
      end;
      if Op = '-d' then
      begin
        if Kind = sfkDirectory then Exit(ShellResultOk('', 0)) else Exit(ShellResultOk('', 1));
      end;
      if Op = '-s' then
      begin
        try
          Fs := TFileStream.Create(FFs.Resolve(ACall.Cwd, Left),
            fmOpenRead or fmShareDenyNone);
          try
            if Fs.Size > 0 then
              Exit(ShellResultOk('', 0))
            else
              Exit(ShellResultOk('', 1));
          finally
            Fs.Free;
          end;
        except
          Exit(ShellResultOk('', 1));
        end;
      end;
      if Op = '-r' then
      begin
        if fpAccess(PChar(FFs.Resolve(ACall.Cwd, Left)), R_OK) = 0 then
          Exit(ShellResultOk('', 0)) else Exit(ShellResultOk('', 1));
      end;
      if Op = '-w' then
      begin
        if fpAccess(PChar(FFs.Resolve(ACall.Cwd, Left)), W_OK) = 0 then
          Exit(ShellResultOk('', 0)) else Exit(ShellResultOk('', 1));
      end;
      if Op = '-x' then
      begin
        if fpAccess(PChar(FFs.Resolve(ACall.Cwd, Left)), X_OK) = 0 then
          Exit(ShellResultOk('', 0)) else Exit(ShellResultOk('', 1));
      end;
      Exit(ShellResultOk('', 0));   // -e
    end;
    Exit(Usage('test: unsupported expression'));
  end;
  if Length(A) = 3 then
  begin
    Op := A[1];
    Left := A[0];
    Right := A[2];
    if (Op = '=') or (Op = '==') then
    begin
      if Left = Right then Exit(ShellResultOk('', 0)) else Exit(ShellResultOk('', 1));
    end;
    if Op = '!=' then
    begin
      if Left <> Right then Exit(ShellResultOk('', 0)) else Exit(ShellResultOk('', 1));
    end;
    if (Op = '-eq') or (Op = '-ne') or (Op = '-lt') or (Op = '-le') or
      (Op = '-gt') or (Op = '-ge') then
    begin
      if not TryStrToInt64(Left, I) then
        Exit(Usage('test: integer expression expected: ' + Left));
      if not TryStrToInt64(Right, I) then
        Exit(Usage('test: integer expression expected: ' + Right));
      if (Op = '-eq') and (StrToInt64(Left) = StrToInt64(Right)) then Exit(ShellResultOk('', 0));
      if (Op = '-ne') and (StrToInt64(Left) <> StrToInt64(Right)) then Exit(ShellResultOk('', 0));
      if (Op = '-lt') and (StrToInt64(Left) < StrToInt64(Right)) then Exit(ShellResultOk('', 0));
      if (Op = '-le') and (StrToInt64(Left) <= StrToInt64(Right)) then Exit(ShellResultOk('', 0));
      if (Op = '-gt') and (StrToInt64(Left) > StrToInt64(Right)) then Exit(ShellResultOk('', 0));
      if (Op = '-ge') and (StrToInt64(Left) >= StrToInt64(Right)) then Exit(ShellResultOk('', 0));
      Exit(ShellResultOk('', 1));
    end;
    Exit(Usage('test: unsupported expression'));
  end;
  Result := Usage('test: unsupported expression');
end;

function TBuiltinCommands.Bracket(const ACall: TShellCall): TShellResult;
var
  A: TStringArray;
  I, N: Integer;
  Inner: TShellCall;
begin
  if Length(ACall.Args) = 0 then
    Exit(Usage('[: missing ]'));
  if ACall.Args[High(ACall.Args)] <> ']' then
    Exit(Usage('[: missing ]'));
  N := Length(ACall.Args) - 1;
  SetLength(A, N);
  for I := 0 to N - 1 do
    A[I] := ACall.Args[I];
  Inner := ACall;
  Inner.Args := A;
  Result := TestCmd(Inner);
end;

function TBuiltinCommands.TrueCmd(const ACall: TShellCall): TShellResult;
begin
  Result := ShellResultOk('');
end;

function TBuiltinCommands.FalseCmd(const ACall: TShellCall): TShellResult;
begin
  Result := ShellResultOk('', 1);
end;

function TBuiltinCommands.ToolAllowed(const AName: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FAllowed) do
    if MatchGlob(FAllowed[I], AName) then
      Exit(True);
  Result := False;
end;

function TBuiltinCommands.InvokeTool(const AName, AJson: string): TShellResult;
var
  ArgsJson, Text, E: string;
  Data: TJSONData;
  Obj: TJSONObject;
begin
  if AName = 'run_command' then
    Exit(Failure('tool: run_command is not available in the builtin shell', 1));
  if not ToolAllowed(AName) then
    Exit(Failure('tool: not allowed in the builtin shell: ' + AName, 1));
  if not Assigned(FInvoke) then
    Exit(Failure('tool: no tool dispatcher is configured', 1));
  ArgsJson := Trim(AJson);
  if ArgsJson = '' then
    ArgsJson := '{}';
  try
    Data := GetJSON(ArgsJson);
  except
    on Ex: Exception do
      Exit(Usage('tool: invalid JSON arguments: ' + Ex.Message));
  end;
  try
    if not (Data is TJSONObject) then
      Exit(Usage('tool: arguments must be a JSON object'));
    Obj := TJSONObject(Data);
    if Obj.Find('reason') = nil then
      Obj.Add('reason', FReason);
    ArgsJson := Obj.AsJSON;
  finally
    Data.Free;
  end;
  if FInvoke(AName, ArgsJson, FReason, Text, E) then
    Result := ShellResultOk(EnsureTrailingNewline(Text))
  else
    Result := Failure('tool ' + AName + ': ' + E, 1);
end;

function TBuiltinCommands.Tool(const ACall: TShellCall): TShellResult;
begin
  if Length(ACall.Args) < 1 then
    Exit(Usage('tool: expected a tool name'));
  Result := InvokeTool(ACall.Args[0], JoinArgs(ACall.Args, 1));
end;

function TBuiltinCommands.Mcp(const ACall: TShellCall): TShellResult;
var
  Spec, Server, ToolName: string;
  P: Integer;
begin
  if Length(ACall.Args) < 1 then
    Exit(Usage('mcp: expected <server>:<tool>'));
  Spec := ACall.Args[0];
  P := Pos(':', Spec);
  if (P < 2) or (P = Length(Spec)) then
    Exit(Usage('mcp: expected <server>:<tool>'));
  Server := Copy(Spec, 1, P - 1);
  ToolName := Copy(Spec, P + 1, MaxInt);
  Result := InvokeTool(McpToolName(Server, ToolName), JoinArgs(ACall.Args, 1));
end;

end.
