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
  SysUtils, Classes, shell.types, shell.fs, hildegard.helper.shell.fs,
  hildegard.helper.hash, changes.text;

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
    { Compare two files. Reuses DiffText from the changes library, so a diff an
      agent asks for and a diff the change log records are the same engine. }
    function Diff(const ACall: TShellCall): TShellResult;
    function Pwd(const ACall: TShellCall): TShellResult;
    function StatCmd(const ACall: TShellCall): TShellResult;
    function Seq(const ACall: TShellCall): TShellResult;
    { The hex viewer: inspect bytes that are not readable text. }
    function Od(const ACall: TShellCall): TShellResult;
    { Content hashes. sha256sum reuses the harness's own Sha256Hex; md5sum is a
      local implementation because the repo has no MD5 (and should not need one
      elsewhere - this is for compatibility with scripts that ask for it). }
    function Sha256Sum(const ACall: TShellCall): TShellResult;
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
    function Sed(const ACall: TShellCall): TShellResult;
    function Awk(const ACall: TShellCall): TShellResult;
    function Find(const ACall: TShellCall): TShellResult;
    function Jq(const ACall: TShellCall): TShellResult;
    function Cut(const ACall: TShellCall): TShellResult;
    function Tr(const ACall: TShellCall): TShellResult;
    function Tee(const ACall: TShellCall): TShellResult;
    function Printf(const ACall: TShellCall): TShellResult;
    function Rg(const ACall: TShellCall): TShellResult;
    function Tool(const ACall: TShellCall): TShellResult;
    function Mcp(const ACall: TShellCall): TShellResult;
  end;

{ The option flags a command supports (e.g. '-n'), or '' when it takes none.
  False when AName is not a builtin command. }
function BuiltinCommandOptions(const AName: string; out AOptions: string): Boolean;

{ True when the name is one of the tier's commands. }
function IsBuiltinCommand(const AName: string): Boolean;

{ The tier's command names, space-separated, for the system prompt. GENERATED
  from the same table IsBuiltinCommand reads, so the list a model is shown cannot
  drift from what the tier actually runs. }
function BuiltinCommandList: string;

{ True when a literal argument is an option the command does not support.
  A combined short flag is decomposed (-rf -> r, f); '--' is always allowed;
  a long option is unsupported. 'N' in AOptions allows the BSD numeric
  shorthand (-20; head/tail). An empty AOptions means "no options at all". }
function IsUnsupportedOption(const AArg, AOptions: string): Boolean;

{ True when AArg is -<digits> and AOptions allows the numeric shorthand. }
function IsNumericOption(const AArg, AOptions: string): Boolean;

implementation

uses
  StrUtils, DateUtils, fpjson, jsonparser, hildegard.helper.shell.pattern,
  hildegard.helper.shell.sed, hildegard.helper.shell.awk,
  hildegard.helper.shell.jq, hildegard.helper.shell.textcmd,
  hildegard.helper.shell.textlines,
  hildegard.helper.gitignore,
  shell.interpreter, hildegard.helper.mcp.client
  {$ifdef unix}, BaseUnix{$endif};

const
  DefaultLines = 10;

type
  TCommandSpec = record
    Name: string;
    Options: string;
  end;

const
  CommandSpecs: array[0..36] of TCommandSpec = (
    (Name: 'echo'; Options: '-n'),
    (Name: 'head'; Options: '-nN'),
    (Name: 'tail'; Options: '-nN'),
    (Name: 'wc'; Options: '-lwc'),
    (Name: 'diff'; Options: '-quc'),
    (Name: 'pwd'; Options: ''),
    (Name: 'stat'; Options: ''),
    (Name: 'seq'; Options: ''),
    (Name: 'od'; Options: '-Ancxtd'),
    (Name: 'sha256sum'; Options: ''),
    (Name: 'grep'; Options: '-nivlcFEGrm'),
    (Name: 'sed'; Options: '-nErei'),
    (Name: 'awk'; Options: '-F'),
    (Name: 'find'; Options: ''),
    (Name: 'jq'; Options: '-rc'),
    (Name: 'cut'; Options: '-dfcs'),
    (Name: 'tr'; Options: '-ds'),
    (Name: 'tee'; Options: '-a'),
    (Name: 'printf'; Options: ''),
    (Name: 'rg'; Options: '-nilcFErg'),
    (Name: 'ls'; Options: '-adl'),
    (Name: 'mkdir'; Options: '-p'),
    (Name: 'rm'; Options: '-rf'),
    { -k, -t and -o take a value, attached (-k2, -t:) or separate. The letters
      cover the attached form; the separate form is admitted by the same list. }
    (Name: 'sort'; Options: '-rufnhMkbtsco'),
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

function BuiltinCommandList: string;
var
  I: Integer;
begin
  { Generated from the same table the tier dispatches with, so the list a model
    reads cannot disagree with what actually runs. }
  Result := '';
  for I := 0 to High(CommandSpecs) do
  begin
    if CommandSpecs[I].Name = '' then
      Continue;
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + CommandSpecs[I].Name;
  end;
end;

function IsNumericOption(const AArg, AOptions: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if (Pos('N', AOptions) = 0) or (Length(AArg) < 2) or (AArg[1] <> '-') then
    Exit;
  for I := 2 to Length(AArg) do
    if (AArg[I] < '0') or (AArg[I] > '9') then
      Exit;
  Result := True;
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
  begin
    { A long option needs a name after '--'. '---' is an argument (bash's
      `echo ---`), not an option. }
    if (Length(AArg) > 3) and (AArg[3] in ['a'..'z', 'A'..'Z', '0'..'9']) then
      Exit(True);
    Exit(False);
  end;
  if IsNumericOption(AArg, AOptions) then
    Exit(False);
  for I := 2 to Length(AArg) do
  begin
    Ch := AArg[I];
    if Pos(Ch, AOptions) = 0 then
      Exit(True);
  end;
  Result := False;
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
    else if IsNumericOption(ACall.Args[I], '-nN') then
    begin
      N := StrToIntDef(Copy(ACall.Args[I], 2, MaxInt), -1);
      if N < 0 then
        Exit(Usage('head: invalid number of lines: ' + ACall.Args[I]));
      Inc(I);
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
    else if IsNumericOption(ACall.Args[I], '-nN') then
    begin
      N := StrToIntDef(Copy(ACall.Args[I], 2, MaxInt), -1);
      if N < 0 then
        Exit(Usage('tail: invalid number of lines: ' + ACall.Args[I]));
      Inc(I);
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

function TBuiltinCommands.Od(const ACall: TShellCall): TShellResult;
var
  I: Integer;
  NoAddr, AsChars, AsHex, AsOctal: Boolean;
  Data, E, OutText, Line, Hex: string;
  LineNo: Integer;
  B: Byte;
begin
  { The hex viewer. Everything else in the tier treats content as text, so a
    binary file is either refused or mangled; od is how an agent looks at bytes. }
  NoAddr := False;
  AsChars := False;
  AsHex := True;      // the default format here; od's own default is octal
  AsOctal := False;
  I := 0;
  while (I <= High(ACall.Args)) and (ACall.Args[I] <> '') and
    (ACall.Args[I][1] = '-') and (ACall.Args[I] <> '-') do
  begin
    if Copy(ACall.Args[I], 1, 3) = '-tx' then
    begin
      AsHex := True;
      AsOctal := False;
    end
    else if Copy(ACall.Args[I], 1, 3) = '-to' then
    begin
      AsOctal := True;
      AsHex := False;
    end
    else if Copy(ACall.Args[I], 1, 2) = '-A' then
    begin
      if ACall.Args[I] = '-An' then
        NoAddr := True;
    end
    else
    begin
      case ACall.Args[I][2] of
        'c': begin AsChars := True; AsHex := False; AsOctal := False; end;
        'x': begin AsHex := True; AsChars := False; AsOctal := False; end;
        'o': begin AsOctal := True; AsHex := False; AsChars := False; end;
      end;
    end;
    Inc(I);
  end;
  if I <= High(ACall.Args) then
  begin
    if not FFs.ReadFile(FFs.Resolve(ACall.Cwd, ACall.Args[I]), Data, E) then
      Exit(Failure('od: ' + ACall.Args[I] + ': ' + E, 2));
  end
  else
    Data := ACall.Stdin;

  OutText := '';
  if Data = '' then
    Exit(ShellResultOk(''));
  LineNo := 0;
  I := 1;
  while I <= Length(Data) do
  begin
    Hex := '';
    for B := 0 to 15 do
      if I + B <= Length(Data) then
      begin
        if AsChars then
        begin
          case Ord(Data[I + B]) of
            0: Hex := Hex + ' \0';
            9: Hex := Hex + ' \t';
            10: Hex := Hex + ' \n';
            13: Hex := Hex + ' \r';
          else
            if (Ord(Data[I + B]) < 32) or (Ord(Data[I + B]) > 126) then
              Hex := Hex + Format(' %3d', [Ord(Data[I + B])])
            else
              Hex := Hex + '   ' + Data[I + B];
          end;
        end
        else if AsOctal then
          Hex := Hex + Format('  %.3o', [Ord(Data[I + B])])
        else
          Hex := Hex + Format('  %.2x', [Ord(Data[I + B])]);
      end;
    if NoAddr then
      Line := ''
    else
      Line := Format('%.7d', [LineNo * 16]) + ' ';
    OutText := OutText + TrimRight(Line + TrimLeft(Hex)) + #10;
    Inc(I, 16);
    Inc(LineNo);
  end;
  Result := ShellResultOk(OutText);
end;

function TBuiltinCommands.Pwd(const ACall: TShellCall): TShellResult;
begin
  { The working directory. Trivial, but an agent reaches for it reflexively and
    its absence escalated the whole script out of the gated tier. }
  Result := ShellResultOk(ACall.Cwd + #10);
end;

function TBuiltinCommands.StatCmd(const ACall: TShellCall): TShellResult;
var
  I: Integer;
  Info: TShellFileInfo;
  E, Kind, OutText: string;
begin
  if Length(ACall.Args) = 0 then
    Exit(Usage('stat: expected a file'));
  OutText := '';
  for I := 0 to High(ACall.Args) do
  begin
    if not FFs.Info(FFs.Resolve(ACall.Cwd, ACall.Args[I]), Info, E) then
      Exit(Failure('stat: ' + ACall.Args[I] + ': ' + E, 1));
    case Info.Kind of
      sfkDirectory: Kind := 'directory';
      sfkFile: Kind := 'regular file';
      sfkMissing: Kind := 'missing';
    else
      Kind := 'special';
    end;
    { Size first, because it is the field an agent almost always wants and it
      must agree with wc -c. }
    OutText := OutText + ACall.Args[I] + ': ' + Kind + ', ' +
      IntToStr(Info.Size) + ' bytes';
    if Info.Modified <> 0 then
      OutText := OutText + ', modified ' + IntToStr(Info.Modified);
    OutText := OutText + #10;
  end;
  Result := ShellResultOk(OutText);
end;

function TBuiltinCommands.Seq(const ACall: TShellCall): TShellResult;
var
  First, Step, Last, V: Integer;
  OutText: string;
  N: Integer;
begin
  { seq generates a range - the usual reason an agent reaches for a loop. }
  Step := 1;
  case Length(ACall.Args) of
    1:
      begin
        if not TryStrToInt(ACall.Args[0], Last) then
          Exit(Usage('seq: invalid number: ' + ACall.Args[0]));
        First := 1;
      end;
    2:
      begin
        if not TryStrToInt(ACall.Args[0], First) or
           not TryStrToInt(ACall.Args[1], Last) then
          Exit(Usage('seq: invalid number'));
      end;
    3:
      begin
        if not TryStrToInt(ACall.Args[0], First) or
           not TryStrToInt(ACall.Args[1], Step) or
           not TryStrToInt(ACall.Args[2], Last) then
          Exit(Usage('seq: invalid number'));
        if Step = 0 then
          Exit(Usage('seq: step must not be zero'));
      end;
  else
    Exit(Usage('seq: expected [first [step]] last'));
  end;
  { A step whose sign disagrees with the range yields nothing, as seq(1) does -
    not an error, and not an unbounded loop. }
  OutText := '';
  V := First;
  N := 0;
  while ((Step > 0) and (V <= Last)) or ((Step < 0) and (V >= Last)) do
  begin
    OutText := OutText + IntToStr(V) + #10;
    Inc(V, Step);
    Inc(N);
    if N > 1000000 then
      Exit(Failure('seq: range too large', 1));
  end;
  Result := ShellResultOk(OutText);
end;

function TBuiltinCommands.Diff(const ACall: TShellCall): TShellResult;
var
  I: Integer;
  Brief, Unified: Boolean;
  Args: TStringArray;
  A, B, E, OutText, Body: string;
  Capped: Boolean;
begin
  { Reuses DiffText from the changes library, so what an agent asks for here and
    what the change log records are the same engine - two diff implementations
    would be a way to disagree with ourselves. }
  Brief := False;
  Unified := True;
  I := 0;
  while (I <= High(ACall.Args)) and (ACall.Args[I] <> '') and
    (ACall.Args[I][1] = '-') and (ACall.Args[I] <> '-') do
  begin
    if ACall.Args[I] = '-q' then
      Brief := True
    else if ACall.Args[I] = '-u' then
      Unified := True
    else if ACall.Args[I] = '-c' then
      Unified := False
    else
      Exit(Usage('diff: unsupported option ' + ACall.Args[I]));
    Inc(I);
  end;
  if I + 1 > High(ACall.Args) then
    Exit(Usage('diff: expected two files'));
  SetLength(Args, High(ACall.Args) - I + 1);
  while I <= High(ACall.Args) do
  begin
    Args[I - (High(ACall.Args) - High(Args))] := ACall.Args[I];
    Inc(I);
  end;
  if Length(Args) <> 2 then
    Exit(Usage('diff: expected two files'));
  if not FFs.ReadFile(FFs.Resolve(ACall.Cwd, Args[0]), A, E) then
    Exit(Failure('diff: ' + Args[0] + ': ' + E, 2));
  if not FFs.ReadFile(FFs.Resolve(ACall.Cwd, Args[1]), B, E) then
    Exit(Failure('diff: ' + Args[1] + ': ' + E, 2));

  { The exit status is the point for scripts: 0 same, 1 different, 2 trouble. }
  if A = B then
    Exit(ShellResultOk(''));
  if Brief then
    Exit(ShellResultOk('Files ' + Args[0] + ' and ' + Args[1] +
      ' differ' + #10, 1));

  Body := DiffText(A, B, 1024 * 1024, Capped);
  if Body = '' then
    { DiffText returns '' when the texts are equal; we already know they are
      not, so fall back to a plain summary rather than claiming sameness. }
    Body := '@@ -1 +1 @@' + #10 + '-see ' + Args[0] + #10 + '+see ' +
      Args[1] + #10;
  OutText := '--- ' + Args[0] + #10 + '+++ ' + Args[1] + #10 + Body;
  Result := ShellResultOk(OutText, 1);
end;

function TBuiltinCommands.Sha256Sum(const ACall: TShellCall): TShellResult;
var
  I: Integer;
  Data, E, OutText, Dig: string;
  Any: Boolean;
begin
  { Reuses the harness's own Sha256Hex, so a shell digest and a recorded change
    hash agree - two implementations of the same hash would be a way to disagree
    with ourselves. }
  Any := False;
  OutText := '';
  for I := 0 to High(ACall.Args) do
  begin
    if (ACall.Args[I] = '-') then
    begin
      Dig := Sha256Hex(ACall.Stdin);
      OutText := OutText + Dig + '  -' + #10;
      Any := True;
      Continue;
    end;
    if not FFs.ReadFile(FFs.Resolve(ACall.Cwd, ACall.Args[I]), Data, E) then
    begin
      OutText := OutText + 'sha256sum: ' + ACall.Args[I] + ': ' + E + #10;
      Result := Failure(OutText, 2);
      Exit;
    end;
    Dig := Sha256Hex(Data);
    OutText := OutText + Dig + '  ' + ACall.Args[I] + #10;
    Any := True;
  end;
  if not Any then
  begin
    Dig := Sha256Hex(ACall.Stdin);
    OutText := Dig + '  -' + #10;
  end;
  Result := ShellResultOk(OutText);
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
  I, J, P: Integer;
  ShowN, IgnoreCase, Invert, ListOnly, CountOnly, Fixed, Extended,
    Recursive, Quiet, NoFilename, OnlyMatch, WordMatch, LineMatch: Boolean;
  MaxCount, MatchSoFar: Integer;
  Args: TStringArray;
  Pattern, Data, E, Text, Full: string;
  Lines: TStringArray;
  OutText, ErrText: string;
  Status: Integer;
  Multiple: Boolean;
  Matcher: TPatternMatcher;
  Kind: TShellFileKind;

  procedure ScanStream(const AText, AName: string; AShowName: Boolean);
  var
    K, Count, M: Integer;
    Ls: TStringArray;
    Hits: TStringArray;
  begin
    Ls := LinesOf(AText);
    Count := 0;
    for K := 0 to High(Ls) do
      if (MaxCount > 0) and (Count >= MaxCount) then
        Break
      else if Matcher.Matches(Ls[K]) then
      begin
        Inc(Count);
        if ListOnly or CountOnly or Quiet then
          Continue;
        { -o prints only the matched text, once per match. }
        if OnlyMatch then
        begin
          Hits := Matcher.AllMatches(Ls[K]);
          for M := 0 to High(Hits) do
          begin
            if AShowName and (not NoFilename) then
              OutText := OutText + AName + ':';
            OutText := OutText + Hits[M] + #10;
          end;
          Continue;
        end;
        { -h drops the filename a multi-file search would print. }
        if AShowName and (not NoFilename) then
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
      if AShowName and (not NoFilename) then
        OutText := OutText + AName + ':';
      OutText := OutText + IntToStr(Count) + #10;
    end;
  end;

  procedure ScanFile(const AFullPath, ADisplay: string; AShowName: Boolean);
  var
    D, Err: string;
    Ls: TStringArray;
    K, Count: Integer;
  begin
    if not FFs.ReadFile(AFullPath, D, Err) then
    begin
      ErrText := ErrText + 'grep: ' + ADisplay + ': ' + Err + #10;
      Status := 2;
      Exit;
    end;
    if Pos(#0, D) = 0 then
    begin
      ScanStream(D, ADisplay, AShowName);
      Exit;
    end;
    { Binary: report existence rather than dump bytes, like grep. }
    Ls := LinesOf(D);
    Count := 0;
    for K := 0 to High(Ls) do
      if Matcher.Matches(Ls[K]) then
        Inc(Count);
    if Count > 0 then
    begin
      Status := 0;
      if ListOnly then
        OutText := OutText + ADisplay + #10
      else if CountOnly then
      begin
        if AShowName then
          OutText := OutText + ADisplay + ':';
        OutText := OutText + IntToStr(Count) + #10;
      end
      else
        OutText := OutText + 'Binary file ' + ADisplay + ' matches' + #10;
    end
    else if CountOnly then
    begin
      if AShowName then
        OutText := OutText + ADisplay + ':';
      OutText := OutText + '0' + #10;
    end;
  end;

  procedure WalkDir(const ADir, ADisplayDir: string; ADepth: Integer);
  var
    Entries: TStringArray;
    Err, Child, Display: string;
    I: Integer;
    {$ifdef unix}
    LSt: Stat;
    {$endif}
  begin
    if ADepth > 64 then
    begin
      ErrText := ErrText + 'grep: ' + ADisplayDir +
        ': directory nesting too deep' + #10;
      Status := 2;
      Exit;
    end;
    if not FFs.ListDir(ADir, Entries, Err) then
    begin
      ErrText := ErrText + 'grep: ' + ADisplayDir + ': ' + Err + #10;
      Status := 2;
      Exit;
    end;
    for I := 0 to High(Entries) do
    begin
      Child := ADir + '/' + Entries[I];
      if ADisplayDir = '' then
        Display := Entries[I]
      else if ADisplayDir = '/' then
        Display := '/' + Entries[I]
      else
        Display := ADisplayDir + '/' + Entries[I];
      if not FFs.Stat(Child, Kind, Err) then
        Continue;
      if Kind = sfkDirectory then
      begin
        { -r does not follow symlinked directories (that is -R, unsupported).
          Windows has no lstat; the depth limit bounds a junction loop. }
        {$ifdef unix}
        if (fpLstat(PChar(Child), LSt) = 0) and
          ((LSt.st_mode and S_IFMT) = S_IFLNK) then
          Continue;
        {$endif}
        WalkDir(Child, Display, ADepth + 1);
      end
      else
        ScanFile(Child, Display, True);
    end;
  end;

begin
  ShowN := False;
  IgnoreCase := False;
  Invert := False;
  ListOnly := False;
  CountOnly := False;
  Fixed := False;
  Extended := False;
  Recursive := False;
  Quiet := False;
  NoFilename := False;
  OnlyMatch := False;
  WordMatch := False;
  LineMatch := False;
  MaxCount := 0;
  I := 0;
  while I <= High(ACall.Args) do
  begin
    if ACall.Args[I] = '--' then
    begin
      Inc(I);
      Break;
    end;
    if ACall.Args[I] = '-m' then
    begin
      if I = High(ACall.Args) then
        Exit(Usage('grep: option requires an argument -- m'));
      Inc(I);
      MaxCount := StrToIntDef(ACall.Args[I], 0);
      if MaxCount < 0 then
        Exit(Usage('grep: invalid max count: ' + ACall.Args[I]));
      Inc(I);
      Continue;
    end;
    if (ACall.Args[I] <> '') and (ACall.Args[I][1] = '-') and
      (ACall.Args[I] <> '-') then
    begin
      J := 2;
      while J <= Length(ACall.Args[I]) do
      begin
        case ACall.Args[I][J] of
          'n': ShowN := True;
          'i': IgnoreCase := True;
          'v': Invert := True;
          'l': ListOnly := True;
          'c': CountOnly := True;
          'F': Fixed := True;
          'E': Extended := True;
          'G': Extended := False;
          'r': Recursive := True;
          'q': Quiet := True;
          'h': NoFilename := True;
          'o': OnlyMatch := True;
          'w': WordMatch := True;
          'x': LineMatch := True;
          'm':
            begin
              if J < Length(ACall.Args[I]) then
              begin
                MaxCount := StrToIntDef(Copy(ACall.Args[I], J + 1, MaxInt), 0);
                J := Length(ACall.Args[I]);
              end
              else
              begin
                if I = High(ACall.Args) then
                  Exit(Usage('grep: option requires an argument -- m'));
                Inc(I);
                MaxCount := StrToIntDef(ACall.Args[I], 0);
              end;
            end;
        end;
        Inc(J);
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
  SetLength(Args, Length(ACall.Args) - I);
  P := I;
  while I <= High(ACall.Args) do
  begin
    Args[I - P] := ACall.Args[I];
    Inc(I);
  end;
  Multiple := Length(Args) > 1;
  Matcher := TPatternMatcher.Create(Pattern, Fixed, Extended, IgnoreCase, Invert);
  { -w and -x constrain what counts as a match, inside the matcher so every scan
    path agrees. }
  Matcher.SetMatchMode(WordMatch, LineMatch);
  try
    if Matcher.Invalid <> '' then
      Exit(Failure('grep: invalid regular expression: ' + Matcher.Invalid, 2));
    OutText := '';
    ErrText := '';
    Status := 1;
    if Length(Args) = 0 then
    begin
      if Recursive then
        WalkDir(FFs.Resolve(ACall.Cwd, '.'), '.', 0)
      else
        ScanStream(ACall.Stdin, '', False);
    end
    else
      for J := 0 to High(Args) do
      begin
        if Args[J] = '-' then
        begin
          if not Recursive then
            ScanStream(ACall.Stdin, '', False);
          Continue;
        end;
        Full := FFs.Resolve(ACall.Cwd, Args[J]);
        if not FFs.Stat(Full, Kind, E) then
        begin
          ErrText := ErrText + 'grep: ' + Args[J] + ': ' + E + #10;
          Status := 2;
          Continue;
        end;
        if Kind = sfkDirectory then
        begin
          if Recursive then
            WalkDir(Full, Args[J], 0)
          else
          begin
            ErrText := ErrText + 'grep: ' + Args[J] + ': is a directory' + #10;
            Status := 2;
          end;
        end
        else
          ScanFile(Full, Args[J], Recursive or Multiple);
      end;
    Result.Stdout := OutText;
    Result.Stderr := ErrText;
    Result.ExitCode := Status;
  finally
    Matcher.Free;
  end;
end;

function TBuiltinCommands.Ls(const ACall: TShellCall): TShellResult;
const
  RWX = 'rwxrwxrwx';
var
  I, J: Integer;
  All, DirOnly, Long: Boolean;
  Args: TStringArray;
  Target, E: string;
  Entries: TStringArray;
  Kind: TShellFileKind;
  OutText: string;

  function PadLeft(const AText: string; AWidth: Integer): string;
  begin
    if Length(AText) >= AWidth then
      Result := AText
    else
      Result := StringOfChar(' ', AWidth - Length(AText)) + AText;
  end;

  function LongLine(const AFull, AName: string): string;
  var
    Info: TShellFileInfo;
    Err: string;
    Mode, When: string;
    K: Integer;
  begin
    Result := '';
    if not FFs.Info(AFull, Info, Err) then
      Exit;
    if Info.Kind = sfkDirectory then
      Mode := 'd'
    else
      Mode := '-';
    for K := 0 to 8 do
      if (Info.Mode and (LongWord(1) shl (8 - K))) <> 0 then
        Mode := Mode + RWX[K + 1]
      else
        Mode := Mode + '-';
    if Info.Modified = 0 then
      When := '-'
    else
      When := FormatDateTime('yyyy-mm-dd hh:nn',
        UnixToDateTime(Info.Modified, True));
    Result := Mode + '  ' + PadLeft(IntToStr(Info.Size), 8) + '  ' + When +
      '  ' + AName;
  end;

begin
  All := False;
  DirOnly := False;
  Long := False;
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
          'l': Long := True;
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
    if Long then
      OutText := LongLine(Target, IfThen(Length(Args) = 0, ACall.Cwd, Args[0]));
    if OutText = '' then
      OutText := IfThen(Length(Args) = 0, ACall.Cwd, Args[0]);
    Exit(ShellResultOk(OutText + #10));
  end;
  if not FFs.ListDir(Target, Entries, E) then
    Exit(Failure('ls: ' + Args[0] + ': ' + E, 2));
  for I := 0 to High(Entries) do
  begin
    if (not All) and (Entries[I] <> '') and (Entries[I][1] = '.') then
      Continue;
    if Long then
      OutText := OutText + LongLine(Target + '/' + Entries[I], Entries[I]) + #10
    else
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
  I, J, K: Integer;
  Reverse, Unique, Numeric, FoldCase: Boolean;
  FieldNum: Integer;
  Sep, OutFile, Arg: string;
  Args: TStringArray;
  Data, E, Text, OutText: string;
  Lines, Tmp: TStringArray;

  { The comparison key: field N when -k was given, else the whole line. }
  function KeyOf(const S: string): string;
  var
    P, Start, F: Integer;
    SepCh: Char;
  begin
    Result := S;
    if FieldNum <= 1 then
      Exit;
    if Sep <> '' then
      SepCh := Sep[1]
    else
      SepCh := ' ';
    F := 1;
    Start := 1;
    for P := 1 to Length(S) do
      if S[P] = SepCh then
      begin
        Inc(F);
        if F = FieldNum then
        begin
          Start := P + 1;
          Break;
        end;
      end;
    if F < FieldNum then
      Exit('');
    Result := Copy(S, Start, MaxInt);
  end;

  function NumOf(const S: string): Double;
  begin
    Result := StrToFloatDef(Trim(KeyOf(S)), 0);
  end;

  function Cmp(const A, B: string): Integer;
  begin
    if Numeric then
    begin
      if NumOf(A) < NumOf(B) then
        Exit(-1);
      if NumOf(A) > NumOf(B) then
        Exit(1);
      Exit(0);
    end;
    if FoldCase then
      Result := AnsiCompareText(KeyOf(A), KeyOf(B))
    else
      Result := AnsiCompareStr(KeyOf(A), KeyOf(B));
  end;

  { Merge sort: stable, so equal keys keep input order the way sort(1) does.
    TStringList.Sort cannot be used - it is lexical only, which is exactly why
    -n used to order "10" before "9" instead of refusing. }
  procedure MSort(var A, ABuf: TStringArray; ALo, AHi: Integer);
  var
    Mid, Li, Ri, Ti, M: Integer;
  begin
    if ALo >= AHi then
      Exit;
    Mid := (ALo + AHi) div 2;
    MSort(A, ABuf, ALo, Mid);
    MSort(A, ABuf, Mid + 1, AHi);
    Li := ALo;
    Ri := Mid + 1;
    Ti := ALo;
    while (Li <= Mid) and (Ri <= AHi) do
    begin
      if Cmp(A[Li], A[Ri]) <= 0 then
      begin
        ABuf[Ti] := A[Li];
        Inc(Li);
      end
      else
      begin
        ABuf[Ti] := A[Ri];
        Inc(Ri);
      end;
      Inc(Ti);
    end;
    while Li <= Mid do
    begin
      ABuf[Ti] := A[Li];
      Inc(Li);
      Inc(Ti);
    end;
    while Ri <= AHi do
    begin
      ABuf[Ti] := A[Ri];
      Inc(Ri);
      Inc(Ti);
    end;
    for M := ALo to AHi do
      A[M] := ABuf[M];
  end;

begin
  Reverse := False;
  Unique := False;
  Numeric := False;
  FoldCase := False;
  FieldNum := 0;
  Sep := '';
  OutFile := '';
  I := 0;
  while I <= High(ACall.Args) do
  begin
    Arg := ACall.Args[I];
    if (Arg = '') or (Arg[1] <> '-') or (Arg = '-') then
      Break;
    { Options that take a value, attached (-k2, -t:) or separate (-k 2). }
    if (Arg = '-k') or (Arg = '-t') or (Arg = '-o') then
    begin
      if I >= High(ACall.Args) then
        Exit(Usage('sort: ' + Arg + ' requires an argument'));
      if Arg = '-k' then
        FieldNum := StrToIntDef(ACall.Args[I + 1], 0)
      else if Arg = '-t' then
        Sep := ACall.Args[I + 1]
      else
        OutFile := ACall.Args[I + 1];
      Inc(I, 2);
      Continue;
    end;
    if (Length(Arg) > 2) and (Copy(Arg, 1, 2) = '-k') then
    begin
      FieldNum := StrToIntDef(Copy(Arg, 3, MaxInt), 0);
      Inc(I);
      Continue;
    end;
    if (Length(Arg) > 2) and (Copy(Arg, 1, 2) = '-t') then
    begin
      Sep := Copy(Arg, 3, 1);
      Inc(I);
      Continue;
    end;
    if (Length(Arg) > 2) and (Copy(Arg, 1, 2) = '-o') then
    begin
      OutFile := Copy(Arg, 3, MaxInt);
      Inc(I);
      Continue;
    end;
    for J := 2 to Length(Arg) do
      case Arg[J] of
        'r': Reverse := True;
        'u': Unique := True;
        'n': Numeric := True;
        'f': FoldCase := True;
      else
        Exit(Usage('sort: unsupported option -' + Arg[J]));
      end;
    Inc(I);
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

  Lines := LinesOf(Text);
  SetLength(Tmp, Length(Lines));
  if Length(Lines) > 1 then
    MSort(Lines, Tmp, 0, High(Lines));
  OutText := '';
  if Reverse then
  begin
    for I := High(Lines) downto 0 do
    begin
      if Unique and (I < High(Lines)) and (Lines[I] = Lines[I + 1]) then
        Continue;
      OutText := OutText + Lines[I] + #10;
    end;
  end
  else
    for I := 0 to High(Lines) do
    begin
      if Unique and (I > 0) and (Lines[I] = Lines[I - 1]) then
        Continue;
      OutText := OutText + Lines[I] + #10;
    end;
  { -o writes to a file and prints nothing, which is why the effect table names
    it as a write. }
  if OutFile <> '' then
  begin
    if not FFs.WriteFile(FFs.Resolve(ACall.Cwd, OutFile), OutText, False, E) then
      Exit(Failure('sort: ' + OutFile + ': ' + E, 2));
    Exit(ShellResultOk(''));
  end;
  Result := ShellResultOk(OutText);
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
        {$ifdef unix}
        if fpAccess(PChar(FFs.Resolve(ACall.Cwd, Left)), R_OK) = 0 then
        {$else}
        if FileExists(FFs.Resolve(ACall.Cwd, Left)) then
        {$endif}
          Exit(ShellResultOk('', 0)) else Exit(ShellResultOk('', 1));
      end;
      if Op = '-w' then
      begin
        {$ifdef unix}
        if fpAccess(PChar(FFs.Resolve(ACall.Cwd, Left)), W_OK) = 0 then
        {$else}
        if FileExists(FFs.Resolve(ACall.Cwd, Left)) then
        {$endif}
          Exit(ShellResultOk('', 0)) else Exit(ShellResultOk('', 1));
      end;
      if Op = '-x' then
      begin
        {$ifdef unix}
        if fpAccess(PChar(FFs.Resolve(ACall.Cwd, Left)), X_OK) = 0 then
        {$else}
        if FileExists(FFs.Resolve(ACall.Cwd, Left)) then
        {$endif}
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

function TBuiltinCommands.Sed(const ACall: TShellCall): TShellResult;
var
  I, J: Integer;
  Suppress, Extended, InPlace: Boolean;
  Suffix, Scripts, A, OutText, Err, Data, E, Target: string;
  Files: TStringArray;

  procedure AddScript(const S: string);
  begin
    if Scripts = '' then
      Scripts := S
    else
      Scripts := Scripts + #10 + S;
  end;

begin
  Suppress := False;
  Extended := False;
  InPlace := False;
  Suffix := '';
  Scripts := '';
  I := 0;
  while I <= High(ACall.Args) do
  begin
    A := ACall.Args[I];
    if A = '--' then
    begin
      Inc(I);
      Break;
    end;
    if (A = '') or (A[1] <> '-') or (A = '-') then
      Break;
    J := 2;
    while J <= Length(A) do
    begin
      case A[J] of
        'n': Suppress := True;
        'E', 'r': Extended := True;
        'i':
          begin
            InPlace := True;
            Suffix := Copy(A, J + 1, MaxInt);
            J := Length(A);
          end;
        'e':
          begin
            if J < Length(A) then
              AddScript(Copy(A, J + 1, MaxInt))
            else
            begin
              if I = High(ACall.Args) then
                Exit(Usage('sed: option -e requires an argument'));
              Inc(I);
              AddScript(ACall.Args[I]);
            end;
            J := Length(A);
          end;
      else
        Exit(Usage('sed: unsupported option -' + A[J]));
      end;
      Inc(J);
    end;
    Inc(I);
  end;
  if Scripts = '' then
  begin
    if I > High(ACall.Args) then
      Exit(Usage('sed: missing script'));
    Scripts := ACall.Args[I];
    Inc(I);
  end;
  SetLength(Files, Length(ACall.Args) - I);
  J := I;
  while I <= High(ACall.Args) do
  begin
    Files[I - J] := ACall.Args[I];
    Inc(I);
  end;
  if InPlace and (Length(Files) = 0) then
    Exit(Usage('sed: -i requires a file'));
  if Length(Files) = 0 then
  begin
    if not RunSed(Scripts, ACall.Stdin, Suppress, Extended, OutText, Err) then
      Exit(Failure('sed: ' + Err, 1));
    Exit(ShellResultOk(OutText));
  end;
  Result := Default(TShellResult);
  for I := 0 to High(Files) do
  begin
    Target := FFs.Resolve(ACall.Cwd, Files[I]);
    if not FFs.ReadFile(Target, Data, E) then
    begin
      Result.Stderr := Result.Stderr + 'sed: ' + Files[I] + ': ' + E + #10;
      Result.ExitCode := 2;
      Exit;
    end;
    if not RunSed(Scripts, Data, Suppress, Extended, OutText, Err) then
    begin
      Result.Stderr := Result.Stderr + 'sed: ' + Err + #10;
      Result.ExitCode := 1;
      Exit;
    end;
    if InPlace then
    begin
      if (Suffix <> '') and
        (not FFs.WriteFile(Target + Suffix, Data, False, E)) then
      begin
        Result.Stderr := Result.Stderr + 'sed: cannot write ' + Files[I] +
          Suffix + ': ' + E + #10;
        Result.ExitCode := 4;
        Exit;
      end;
      if not FFs.WriteFile(Target, OutText, False, E) then
      begin
        Result.Stderr := Result.Stderr + 'sed: cannot write ' + Files[I] +
          ': ' + E + #10;
        Result.ExitCode := 4;
        Exit;
      end;
    end
    else
      Result.Stdout := Result.Stdout + OutText;
  end;
end;

function TBuiltinCommands.Awk(const ACall: TShellCall): TShellResult;
var
  I, J: Integer;
  A, FieldSep, ProgramText, OutText, Err, Data, E, Combined: string;
  Files: TStringArray;
begin
  FieldSep := '';
  I := 0;
  while I <= High(ACall.Args) do
  begin
    A := ACall.Args[I];
    if A = '--' then
    begin
      Inc(I);
      Break;
    end;
    if (A = '') or (A[1] <> '-') or (A = '-') then
      Break;
    if A = '-F' then
    begin
      if I = High(ACall.Args) then
        Exit(Usage('awk: option -F requires an argument'));
      Inc(I);
      FieldSep := ACall.Args[I];
    end
    else if Copy(A, 1, 2) = '-F' then
      FieldSep := Copy(A, 3, MaxInt)
    else
      Exit(Usage('awk: unsupported option ' + A));
    Inc(I);
  end;
  if I > High(ACall.Args) then
    Exit(Usage('awk: missing program'));
  ProgramText := ACall.Args[I];
  Inc(I);
  SetLength(Files, Length(ACall.Args) - I);
  J := I;
  while I <= High(ACall.Args) do
  begin
    Files[I - J] := ACall.Args[I];
    Inc(I);
  end;
  if FieldSep = '\t' then
    FieldSep := #9
  else if (FieldSep <> '') and (Length(FieldSep) > 1) then
    Exit(Usage('awk: only a single-character -F is supported'));
  if Length(Files) = 0 then
    Combined := ACall.Stdin
  else
  begin
    Combined := '';
    for I := 0 to High(Files) do
    begin
      if Files[I] = '-' then
        Combined := Combined + ACall.Stdin
      else if not FFs.ReadFile(FFs.Resolve(ACall.Cwd, Files[I]), Data, E) then
      begin
        Result := Failure('awk: ' + Files[I] + ': ' + E, 2);
        Exit;
      end
      else
        Combined := Combined + Data;
    end;
  end;
  if not RunAwk(ProgramText, Combined, FieldSep, OutText, Err) then
    Exit(Failure('awk: ' + Err, 1));
  Result := ShellResultOk(OutText);
end;

function TBuiltinCommands.Find(const ACall: TShellCall): TShellResult;
var
  I: Integer;
  Paths: TStringArray;
  NamePattern, TypeFilter: string;
  NameInsensitive: Boolean;
  MaxDepth: Integer;
  OutText, ErrText, Full, Err: string;
  Status: Integer;
  OperandKind: TShellFileKind;

  function Matches(const ADisplay, AFull: string; AKind: TShellFileKind): Boolean;
  var
    Base, Pattern: string;
  begin
    if TypeFilter = 'f' then
    begin
      if AKind <> sfkFile then Exit(False);
    end
    else if TypeFilter = 'd' then
    begin
      if AKind <> sfkDirectory then Exit(False);
    end;
    if NamePattern = '' then
      Exit(True);
    Base := ExtractFileName(ADisplay);
    Pattern := NamePattern;
    if NameInsensitive then
    begin
      Base := LowerCase(Base);
      Pattern := LowerCase(Pattern);
    end;
    Result := MatchGlob(Pattern, Base);
  end;

  procedure Walk(const ADir, ADisplay: string; ADepth: Integer); forward;

  procedure Emit(const ADisplay, AFull: string);
  var
    Kind: TShellFileKind;
    E: string;
  begin
    if not FFs.Stat(AFull, Kind, E) then
      Exit;
    if Matches(ADisplay, AFull, Kind) then
      OutText := OutText + ADisplay + #10;
  end;

  procedure Walk(const ADir, ADisplay: string; ADepth: Integer);
  var
    Entries: TStringArray;
    E, Child, ChildDisplay: string;
    J: Integer;
    Kind: TShellFileKind;
    {$ifdef unix}
    LSt: Stat;
    {$endif}
  begin
    if (MaxDepth >= 0) and (ADepth > MaxDepth) then
      Exit;
    Emit(ADisplay, ADir);
    if (MaxDepth >= 0) and (ADepth >= MaxDepth) then
      Exit;
    if not FFs.Stat(ADir, Kind, E) then
      Exit;
    if Kind <> sfkDirectory then
      Exit;
    if not FFs.ListDir(ADir, Entries, E) then
    begin
      ErrText := ErrText + 'find: ' + ADisplay + ': ' + E + #10;
      Status := 1;
      Exit;
    end;
    for J := 0 to High(Entries) do
    begin
      Child := ADir + '/' + Entries[J];
      if ADisplay = '' then
        ChildDisplay := Entries[J]
      else if ADisplay = '/' then
        ChildDisplay := '/' + Entries[J]
      else
        ChildDisplay := ADisplay + '/' + Entries[J];
      {$ifdef unix}
      if (fpLstat(PChar(Child), LSt) = 0) and
        ((LSt.st_mode and S_IFMT) = S_IFLNK) then
      begin
        { find does not follow symlinks by default; report the link itself. }
        Emit(ChildDisplay, Child);
        Continue;
      end;
      {$endif}
      Walk(Child, ChildDisplay, ADepth + 1);
    end;
  end;

begin
  NamePattern := '';
  TypeFilter := '';
  NameInsensitive := False;
  MaxDepth := -1;
  Paths := nil;
  I := 0;
  while (I <= High(ACall.Args)) and
    ((ACall.Args[I] = '') or (ACall.Args[I][1] <> '-')) do
  begin
    SetLength(Paths, Length(Paths) + 1);
    Paths[High(Paths)] := ACall.Args[I];
    Inc(I);
  end;
  while I <= High(ACall.Args) do
  begin
    if ACall.Args[I] = '-name' then
    begin
      if I = High(ACall.Args) then
        Exit(Usage('find: -name requires an argument'));
      Inc(I);
      NamePattern := ACall.Args[I];
    end
    else if ACall.Args[I] = '-iname' then
    begin
      if I = High(ACall.Args) then
        Exit(Usage('find: -iname requires an argument'));
      Inc(I);
      NamePattern := ACall.Args[I];
      NameInsensitive := True;
    end
    else if ACall.Args[I] = '-type' then
    begin
      if I = High(ACall.Args) then
        Exit(Usage('find: -type requires an argument'));
      Inc(I);
      TypeFilter := ACall.Args[I];
      if (TypeFilter <> 'f') and (TypeFilter <> 'd') then
        Exit(Usage('find: only -type f and -type d are supported'));
    end
    else if ACall.Args[I] = '-maxdepth' then
    begin
      if I = High(ACall.Args) then
        Exit(Usage('find: -maxdepth requires an argument'));
      Inc(I);
      MaxDepth := StrToIntDef(ACall.Args[I], -1);
      if MaxDepth < 0 then
        Exit(Usage('find: invalid -maxdepth: ' + ACall.Args[I]));
    end
    else if ACall.Args[I] = '-print' then
    begin
      { the default }
    end
    else
      Exit(Usage('find: unsupported expression: ' + ACall.Args[I]));
    Inc(I);
  end;
  if Length(Paths) = 0 then
  begin
    SetLength(Paths, 1);
    Paths[0] := '.';
  end;
  OutText := '';
  ErrText := '';
  Status := 0;
  for I := 0 to High(Paths) do
  begin
    Full := FFs.Resolve(ACall.Cwd, Paths[I]);
    if not FFs.Stat(Full, OperandKind, Err) then
    begin
      ErrText := ErrText + 'find: ' + Paths[I] + ': ' + Err + #10;
      Status := 1;
      Continue;
    end;
    Walk(Full, Paths[I], 0);
  end;
  Result.Stdout := OutText;
  Result.Stderr := ErrText;
  Result.ExitCode := Status;
end;

function TBuiltinCommands.Jq(const ACall: TShellCall): TShellResult;
var
  I, J, Code: Integer;
  Raw, Compact: Boolean;
  A, Filter, OutText, Err, Data, E: string;
  Files: TStringArray;
begin
  Raw := False;
  Compact := False;
  I := 0;
  while I <= High(ACall.Args) do
  begin
    A := ACall.Args[I];
    if A = '--' then
    begin
      Inc(I);
      Break;
    end;
    if (A = '') or (A[1] <> '-') or (A = '-') then
      Break;
    if A = '-r' then
      Raw := True
    else if A = '-c' then
      Compact := True
    else
      Exit(Usage('jq: unsupported option ' + A));
    Inc(I);
  end;
  if I > High(ACall.Args) then
    Exit(Usage('jq: missing filter'));
  Filter := ACall.Args[I];
  Inc(I);
  SetLength(Files, Length(ACall.Args) - I);
  J := I;
  while I <= High(ACall.Args) do
  begin
    Files[I - J] := ACall.Args[I];
    Inc(I);
  end;
  Result := Default(TShellResult);
  if Length(Files) = 0 then
  begin
    if not RunJq(Filter, ACall.Stdin, Raw, Compact, OutText, Err) then
    begin
      if Pos('parse error', Err) > 0 then
        Code := 5
      else
        Code := 3;
      Exit(Failure('jq: ' + Err, Code));
    end;
    Exit(ShellResultOk(OutText));
  end;
  for I := 0 to High(Files) do
  begin
    if Files[I] = '-' then
      Data := ACall.Stdin
    else if not FFs.ReadFile(FFs.Resolve(ACall.Cwd, Files[I]), Data, E) then
    begin
      Result.Stderr := Result.Stderr + 'jq: ' + Files[I] + ': ' + E + #10;
      Result.ExitCode := 2;
      Exit;
    end;
    if not RunJq(Filter, Data, Raw, Compact, OutText, Err) then
    begin
      if Pos('parse error', Err) > 0 then
        Code := 5
      else
        Code := 3;
      Result.Stderr := Result.Stderr + 'jq: ' + Err + #10;
      Result.ExitCode := Code;
      Exit;
    end;
    Result.Stdout := Result.Stdout + OutText;
  end;
end;

function TBuiltinCommands.Cut(const ACall: TShellCall): TShellResult;
var
  I, J: Integer;
  A, Sep, Fields: string;
  HasSep, Chars, Suppress: Boolean;
  Files: TStringArray;
  Data, E, OutText, Err, Combined: string;
  Code: Integer;
begin
  HasSep := False;
  Sep := #9;
  Fields := '';
  Chars := False;
  Suppress := False;
  I := 0;
  while I <= High(ACall.Args) do
  begin
    A := ACall.Args[I];
    if A = '--' then
    begin
      Inc(I);
      Break;
    end;
    if (A = '') or (A[1] <> '-') or (A = '-') then
      Break;
    if A = '-d' then
    begin
      if I = High(ACall.Args) then
        Exit(Usage('cut: -d requires an argument'));
      Inc(I);
      Sep := ACall.Args[I];
      HasSep := True;
    end
    else if Copy(A, 1, 2) = '-d' then
    begin
      Sep := Copy(A, 3, MaxInt);
      HasSep := True;
    end
    else if A = '-f' then
    begin
      if I = High(ACall.Args) then
        Exit(Usage('cut: -f requires an argument'));
      Inc(I);
      Fields := ACall.Args[I];
    end
    else if Copy(A, 1, 2) = '-f' then
      Fields := Copy(A, 3, MaxInt)
    else if A = '-c' then
    begin
      if I = High(ACall.Args) then
        Exit(Usage('cut: -c requires an argument'));
      Inc(I);
      Fields := ACall.Args[I];
      Chars := True;
    end
    else if Copy(A, 1, 2) = '-c' then
    begin
      Fields := Copy(A, 3, MaxInt);
      Chars := True;
    end
    else if A = '-s' then
      Suppress := True
    else
      Exit(Usage('cut: unsupported option ' + A));
    Inc(I);
  end;
  if Fields = '' then
    Exit(Usage('cut: one of -f or -c is required'));
  SetLength(Files, Length(ACall.Args) - I);
  J := I;
  while I <= High(ACall.Args) do
  begin
    Files[I - J] := ACall.Args[I];
    Inc(I);
  end;
  if Length(Files) = 0 then
    Combined := ACall.Stdin
  else
  begin
    Combined := '';
    for I := 0 to High(Files) do
      if Files[I] = '-' then
        Combined := Combined + ACall.Stdin
      else if not FFs.ReadFile(FFs.Resolve(ACall.Cwd, Files[I]), Data, E) then
        Exit(Failure('cut: ' + Files[I] + ': ' + E, 2))
      else
        Combined := Combined + Data;
  end;
  if not CutText(Combined, Sep, Fields, HasSep, Chars, Suppress, OutText, Err) then
  begin
    if Pos('no positions', Err) > 0 then
      Code := 2
    else
      Code := 1;
    Exit(Failure('cut: ' + Err, Code));
  end;
  Result := ShellResultOk(OutText);
end;

function TBuiltinCommands.Tr(const ACall: TShellCall): TShellResult;
var
  I, J: Integer;
  Delete, Squeeze: Boolean;
  Args: TStringArray;
  Second: string;
  Data, E, OutText, Err, Combined: string;
begin
  Delete := False;
  Squeeze := False;
  I := 0;
  while I <= High(ACall.Args) do
  begin
    if ACall.Args[I] = '--' then
    begin
      Inc(I);
      Break;
    end;
    if (ACall.Args[I] = '-d') or (ACall.Args[I] = '-s') or
      (ACall.Args[I] = '-ds') or (ACall.Args[I] = '-sd') then
    begin
      if Pos('d', ACall.Args[I]) > 0 then
        Delete := True;
      if Pos('s', ACall.Args[I]) > 0 then
        Squeeze := True;
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
  if Length(Args) = 0 then
    Exit(Usage('tr: missing operand'));
  Combined := ACall.Stdin;
  if Length(Args) > 1 then
    Second := Args[1]
  else
    Second := '';
  if not TrText(Combined, Args[0], Second, Delete, Squeeze, OutText, Err) then
    Exit(Failure('tr: ' + Err, 1));
  Result := ShellResultOk(OutText);
end;

function TBuiltinCommands.Tee(const ACall: TShellCall): TShellResult;
var
  I, Start: Integer;
  Append: Boolean;
  E: string;
begin
  Append := False;
  Start := 0;
  if (Length(ACall.Args) > 0) and (ACall.Args[0] = '-a') then
  begin
    Append := True;
    Start := 1;
  end;
  Result := Default(TShellResult);
  Result.Stdout := ACall.Stdin;
  for I := Start to High(ACall.Args) do
    if not FFs.WriteFile(FFs.Resolve(ACall.Cwd, ACall.Args[I]), ACall.Stdin,
      Append, E) then
    begin
      Result.Stderr := Result.Stderr + 'tee: ' + ACall.Args[I] + ': ' + E + #10;
      Result.ExitCode := 1;
    end;
end;

function TBuiltinCommands.Printf(const ACall: TShellCall): TShellResult;
var
  Format: string;
  Args: TStringArray;
  I, J: Integer;
  OutText, Err: string;
begin
  if Length(ACall.Args) = 0 then
    Exit(Usage('printf: missing format'));
  Format := ACall.Args[0];
  SetLength(Args, Length(ACall.Args) - 1);
  for I := 1 to High(ACall.Args) do
    Args[I - 1] := ACall.Args[I];
  if not PrintfText(Format, Args, OutText, Err) then
    Exit(Failure('printf: ' + Err, 1));
  Result := ShellResultOk(OutText);
end;

function TBuiltinCommands.Rg(const ACall: TShellCall): TShellResult;
{ ripgrep's shape over the shared engine: recursive by default, gitignore-aware
  inside a repository, hidden entries skipped by default, `path:match` output. }
var
  I, J: Integer;
  A, Pattern, E, OutText, ErrText, RootAbs, RepoRoot, OperandRel: string;
  ShowN, IgnoreCase, ListOnly, CountOnly, Fixed, Extended, Hidden,
    NoIgnore, ImplicitRoot: Boolean;
  Globs, Roots: TStringArray;
  Matcher: TPatternMatcher;
  Ignore: TIgnoreRules;
  Status: Integer;
  RootKind: TShellFileKind;

  function JoinIgnore(const ABase, AName: string): string;
  begin
    if ABase = '' then
      Result := AName
    else
      Result := ABase + '/' + AName;
  end;

  function BaseNameOfPath(const APath: string): string;
  var
    P: Integer;
  begin
    P := Length(APath);
    while (P >= 1) and (APath[P] <> '/') do
      Dec(P);
    Result := Copy(APath, P + 1, MaxInt);
  end;

  function GlobMatches(const ARel, AName: string): Boolean;
  var
    K: Integer;
    Use: string;
  begin
    if Length(Globs) = 0 then
      Exit(True);
    for K := 0 to High(Globs) do
    begin
      if Pos('/', Globs[K]) > 0 then
        Use := ARel
      else
        Use := AName;
      if MatchGlob(Globs[K], Use) then
        Exit(True);
    end;
    Result := False;
  end;

  procedure ScanFile(const AFull, ADisplay, ARel: string; AShowName: Boolean);
  var
    D, FileErr: string;
    Ls: TStringArray;
    K, Count: Integer;
    HasMatch: Boolean;
  begin
    if not GlobMatches(ARel, BaseNameOfPath(ADisplay)) then
      Exit;
    if not FFs.ReadFile(AFull, D, FileErr) then
    begin
      ErrText := ErrText + 'rg: ' + ADisplay + ': ' + FileErr + #10;
      Status := 2;
      Exit;
    end;
    if Pos(#0, D) > 0 then
      Exit;   // rg skips binary files by default
    Ls := LinesOf(D);
    Count := 0;
    HasMatch := False;
    for K := 0 to High(Ls) do
      if Matcher.Matches(Ls[K]) then
      begin
        Inc(Count);
        HasMatch := True;
        if ListOnly or CountOnly then
          Continue;
        if AShowName then
          OutText := OutText + ADisplay + ':';
        if ShowN then
          OutText := OutText + IntToStr(K + 1) + ':';
        OutText := OutText + Ls[K] + #10;
      end;
    if HasMatch then
      Status := 0;
    if ListOnly and HasMatch then
      OutText := OutText + ADisplay + #10;
    { rg's -c lists only files that matched. }
    if CountOnly and HasMatch then
    begin
      if AShowName then
        OutText := OutText + ADisplay + ':';
      OutText := OutText + IntToStr(Count) + #10;
    end;
  end;

  procedure Walk(const AAbs, ADisplay, ARel, AIgnoreRel: string);
  var
    Entries: TStringArray;
    FileErr, Child, ChildDisplay, ChildRel, ChildIgnore, Gitignore: string;
    K: Integer;
    Kind: TShellFileKind;
    {$ifdef unix}
    LSt: Stat;
    {$endif}
  begin
    if not FFs.ListDir(AAbs, Entries, FileErr) then
      Exit;
    { This directory's ignore file applies to its entries (and deeper). }
    if Ignore <> nil then
      for K := 0 to High(Entries) do
        if Entries[K] = '.gitignore' then
        begin
          if FFs.ReadFile(AAbs + '/.gitignore', Gitignore, FileErr) then
            Ignore.AddFile(AIgnoreRel, Gitignore);
          Break;
        end;
    for K := 0 to High(Entries) do
    begin
      if Entries[K] = '.git' then
        Continue;
      if (not Hidden) and (Entries[K] <> '') and (Entries[K][1] = '.') then
        Continue;
      Child := AAbs + '/' + Entries[K];
      if ADisplay = '' then
        ChildDisplay := Entries[K]
      else if ADisplay = '/' then
        ChildDisplay := '/' + Entries[K]
      else
        ChildDisplay := ADisplay + '/' + Entries[K];
      ChildRel := JoinIgnore(ARel, Entries[K]);
      ChildIgnore := JoinIgnore(AIgnoreRel, Entries[K]);
      if not FFs.Stat(Child, Kind, FileErr) then
        Continue;
      if (Ignore <> nil) and Ignore.IsIgnored(ChildIgnore, Kind = sfkDirectory) then
        Continue;
      if Kind = sfkDirectory then
      begin
        {$ifdef unix}
        if (fpLstat(PChar(Child), LSt) = 0) and
          ((LSt.st_mode and S_IFMT) = S_IFLNK) then
          Continue;
        {$endif}
        Walk(Child, ChildDisplay, ChildRel, ChildIgnore);
      end
      else
        ScanFile(Child, ChildDisplay, ChildRel, True);
    end;
  end;

  function FindRepoRoot(const AStartAbs: string; out ARel: string): string;
  var
    Dir, Parent: string;
    Kind: TShellFileKind;
    FileErr: string;
  begin
    Result := '';
    ARel := '';
    Dir := AStartAbs;
    while True do
    begin
      if FFs.Stat(Dir + '/.git', Kind, FileErr) then
      begin
        if Dir = AStartAbs then
          ARel := ''
        else if Copy(AStartAbs, 1, Length(Dir) + 1) = Dir + '/' then
          ARel := Copy(AStartAbs, Length(Dir) + 2, MaxInt)
        else
          Exit;
        Exit(Dir);
      end;
      Parent := ExtractFileDir(Dir);
      if (Parent = '') or (Parent = Dir) then
        Exit;
      if not FFs.Stat(Parent, Kind, FileErr) then
        Exit;
      Dir := Parent;
    end;
  end;

  { Load the ignore files from the repository root down to (but not including)
    the search root; Walk loads the search root's own. }
  procedure LoadIgnoreChain(const ARepoRoot, AOperandRel: string);
  var
    Base, Part, Text, FileErr: string;
    P, Q: Integer;
  begin
    if FFs.ReadFile(ARepoRoot + '/.gitignore', Text, FileErr) then
      Ignore.AddFile('', Text);
    Base := '';
    P := 1;
    while P <= Length(AOperandRel) do
    begin
      Q := P;
      while (Q <= Length(AOperandRel)) and (AOperandRel[Q] <> '/') do
        Inc(Q);
      Part := Copy(AOperandRel, P, Q - P);
      if Base = '' then
        Base := Part
      else
        Base := Base + '/' + Part;
      if Q > Length(AOperandRel) then
        Break;   // the operand directory itself is loaded by Walk
      if FFs.ReadFile(ARepoRoot + '/' + Base + '/.gitignore', Text, FileErr) then
        Ignore.AddFile(Base, Text);
      P := Q + 1;
    end;
  end;

begin
  ShowN := False;
  IgnoreCase := False;
  ListOnly := False;
  CountOnly := False;
  Fixed := False;
  Extended := False;
  Hidden := False;
  NoIgnore := False;
  Globs := nil;
  I := 0;
  while I <= High(ACall.Args) do
  begin
    A := ACall.Args[I];
    if A = '--' then
    begin
      Inc(I);
      Break;
    end;
    if (A = '') or (A[1] <> '-') or (A = '-') then
      Break;
    if A = '--hidden' then
      Hidden := True
    else if A = '--no-ignore' then
      NoIgnore := True
    else if A = '-g' then
    begin
      if I = High(ACall.Args) then
        Exit(Usage('rg: -g requires an argument'));
      Inc(I);
      SetLength(Globs, Length(Globs) + 1);
      Globs[High(Globs)] := ACall.Args[I];
    end
    else if Copy(A, 1, 2) = '-g' then
    begin
      SetLength(Globs, Length(Globs) + 1);
      Globs[High(Globs)] := Copy(A, 3, MaxInt);
    end
    else
    begin
      for J := 2 to Length(A) do
        case A[J] of
          'n': ShowN := True;
          'i': IgnoreCase := True;
          'l': ListOnly := True;
          'c': CountOnly := True;
          'F': Fixed := True;
          'E': Extended := True;
        else
          Exit(Usage('rg: unsupported option -' + A[J]));
        end;
    end;
    Inc(I);
  end;
  if I > High(ACall.Args) then
    Exit(Usage('rg: missing pattern'));
  Pattern := ACall.Args[I];
  Inc(I);
  SetLength(Roots, Length(ACall.Args) - I);
  J := I;
  while I <= High(ACall.Args) do
  begin
    Roots[I - J] := ACall.Args[I];
    Inc(I);
  end;
  ImplicitRoot := Length(Roots) = 0;
  if ImplicitRoot then
  begin
    SetLength(Roots, 1);
    Roots[0] := '.';
  end;
  Matcher := TPatternMatcher.Create(Pattern, Fixed, Extended, IgnoreCase, False);
  Ignore := nil;
  try
    if Matcher.Invalid <> '' then
      Exit(Failure('rg: invalid regular expression: ' + Matcher.Invalid, 2));
    OutText := '';
    ErrText := '';
    Status := 1;
    for I := 0 to High(Roots) do
    begin
      RootAbs := FFs.Resolve(ACall.Cwd, Roots[I]);
      if not FFs.Stat(RootAbs, RootKind, E) then
      begin
        ErrText := ErrText + 'rg: ' + Roots[I] + ': ' + E + #10;
        Status := 2;
        Continue;
      end;
      if NoIgnore then
        RepoRoot := ''
      else
        RepoRoot := FindRepoRoot(RootAbs, OperandRel);
      FreeAndNil(Ignore);
      if RepoRoot <> '' then
      begin
        Ignore := TIgnoreRules.Create(True);
        LoadIgnoreChain(RepoRoot, OperandRel);
      end;
      if RootKind = sfkDirectory then
      begin
        { No operand means `.` silently: rg prints `name`, not `./name`. }
        if ImplicitRoot then
          Walk(RootAbs, '', '', OperandRel)
        else
          Walk(RootAbs, Roots[I], '', OperandRel);
      end
      else
        { One explicit file prints bare lines; several print the name. }
        ScanFile(RootAbs, Roots[I], Roots[I], Length(Roots) > 1);
    end;
    Result.Stdout := OutText;
    Result.Stderr := ErrText;
    Result.ExitCode := Status;
  finally
    Ignore.Free;
    Matcher.Free;
  end;
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
