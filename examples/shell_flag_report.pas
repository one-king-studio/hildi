program shell_flag_report;
{ Developer tool: tally the commands and option flags used in the recorded
  corpus, so the builtin tier's command/flag coverage is chosen from evidence
  rather than guesswork.

  Parses tests/data/shell_corpus.txt with the Shell Library (the same parser the
  tier uses), walks every simple command, and counts:
    - each command name (how often the corpus calls it)
    - each literal option token per command (e.g. "grep -n")
  Unparsable corpus entries and non-literal command names (variables) are
  counted separately.

  Usage: build/bin/shell-flag-report [corpus-path] [top-N] }

{$mode delphi}{$H+}

uses
  SysUtils, Classes, shell.types, shell.ast, shell.parser;

type
  TTally = class
  public
    Counts: TStringList;   // label -> count
    constructor Create;
    destructor Destroy; override;
    procedure Add(const ALabel: string);
    procedure Report(const ATitle: string; ATop: Integer);
  end;

constructor TTally.Create;
begin
  inherited Create;
  Counts := TStringList.Create;
  Counts.CaseSensitive := True;
end;

destructor TTally.Destroy;
begin
  Counts.Free;
  inherited Destroy;
end;

procedure TTally.Add(const ALabel: string);
var
  I: Integer;
begin
  I := Counts.IndexOfName(ALabel);
  if I < 0 then
    Counts.Add(ALabel + '=1')
  else
    Counts[I] := ALabel + '=' + IntToStr(StrToIntDef(Counts.Values[ALabel], 0) + 1);
end;

function TallySort(List: TStringList; Index1, Index2: Integer): Integer;
var
  A, B: Integer;
begin
  A := StrToIntDef(List.ValueFromIndex[Index1], 0);
  B := StrToIntDef(List.ValueFromIndex[Index2], 0);
  if A > B then
    Result := -1
  else if A < B then
    Result := 1
  else
    Result := AnsiCompareStr(List.Names[Index1], List.Names[Index2]);
end;

procedure TTally.Report(const ATitle: string; ATop: Integer);
var
  I: Integer;
begin
  WriteLn;
  WriteLn(ATitle);
  if (ATop <= 0) or (ATop > Counts.Count) then
    ATop := Counts.Count;
  WriteLn(StringOfChar('-', Length(ATitle)));
  Counts.CustomSort(@TallySort);
  for I := 0 to ATop - 1 do
    WriteLn(Format('%6d  %s', [StrToIntDef(Counts.ValueFromIndex[I], 0),
      Counts.Names[I]]));
end;

function Decode(const ALine: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  I := 1;
  while I <= Length(ALine) do
  begin
    C := ALine[I];
    if C = '\' then
    begin
      Inc(I);
      if I <= Length(ALine) then
      begin
        if ALine[I] = 'n' then
          Result := Result + #10
        else if ALine[I] = 't' then
          Result := Result + #9
        else
          Result := Result + ALine[I];
      end;
    end
    else
      Result := Result + C;
    Inc(I);
  end;
end;

function LiteralOf(const AW: TWord; out AText: string): Boolean;
var
  I: Integer;
  P: TWordPart;
begin
  AText := '';
  Result := True;
  for I := 0 to High(AW.Parts) do
  begin
    P := AW.Parts[I];
    case P.Kind of
      wpLiteral, wpGlob, wpTilde: AText := AText + P.Text;
      wpVariable, wpSpecial:
        Exit(False);
    end;
  end;
end;

var
  Commands, Flags, Programs: TTally;
  Parsed, Failed, Simple, NonLiteralName: Integer;

function IsProgramCommand(const AName: string): Boolean;
begin
  Result := (AName = 'sed') or (AName = 'awk') or (AName = 'jq') or
    (AName = 'yq') or (AName = 'rg');
end;

procedure NoteSimple(const AC: TCommand);
var
  I: Integer;
  Name, Arg: string;
begin
  if Length(AC.Words) = 0 then
    Exit;
  Inc(Simple);
  if not LiteralOf(AC.Words[0], Name) then
  begin
    Inc(NonLiteralName);
    Exit;
  end;
  Commands.Add(Name);
  for I := 1 to High(AC.Words) do
  begin
    if not LiteralOf(AC.Words[I], Arg) then
      Continue;
    if (Arg <> '') and (Arg[1] = '-') and (Arg <> '-') then
    begin
      if (Arg <> '') and (Arg[1] = '-') and (Arg <> '-') then
        Flags.Add(Name + ' ' + Arg);
      Continue;
    end;
    { The first non-option literal of a program command is its program text. }
    if IsProgramCommand(Name) then
    begin
      Programs.Add(Name + ' ' + Arg);
      Break;
    end;
  end;
end;

procedure WalkCommand(const AC: TCommand); forward;

procedure WalkStatement(const ASt: TStatement);
var
  I, J, K: Integer;
begin
  if ASt = nil then
    Exit;
  for I := 0 to High(ASt.Items) do
    for J := 0 to High(ASt.Items[I].Pipelines) do
      for K := 0 to High(ASt.Items[I].Pipelines[J].Commands) do
        WalkCommand(ASt.Items[I].Pipelines[J].Commands[K]);
end;

procedure WalkCommand(const AC: TCommand);
var
  I: Integer;
begin
  case AC.Kind of
    ckSimple: NoteSimple(AC);
    ckGroup, ckSubshell: WalkStatement(AC.Group);
    ckIf:
      begin
        for I := 0 to High(AC.Clauses) do
        begin
          WalkStatement(AC.Clauses[I].Condition);
          WalkStatement(AC.Clauses[I].Body);
        end;
        WalkStatement(AC.ElseBody);
      end;
    ckFor: WalkStatement(AC.LoopBody);
    ckWhile, ckUntil:
      begin
        WalkStatement(AC.Condition);
        WalkStatement(AC.LoopBody);
      end;
    ckCase:
      for I := 0 to High(AC.CaseItems) do
        WalkStatement(AC.CaseItems[I].Body);
    ckFunction:
      if AC.FuncBody <> nil then
        WalkCommand(AC.FuncBody);
  end;
end;

var
  Lines: TStringList;
  Source: string;
  Script: TScript;
  Error: TShellParseError;
  I, Top: Integer;
begin
  Lines := TStringList.Create;
  Commands := TTally.Create;
  Flags := TTally.Create;
  Programs := TTally.Create;
  try
    if ParamCount >= 1 then
      Lines.LoadFromFile(ParamStr(1))
    else
      Lines.LoadFromFile('tests/data/shell_corpus.txt');
    Top := 25;
    if ParamCount >= 2 then
      Top := StrToIntDef(ParamStr(2), 25);
    Parsed := 0;
    Failed := 0;
    Simple := 0;
    NonLiteralName := 0;
    for I := 0 to Lines.Count - 1 do
    begin
      if (Lines[I] = '') or (Lines[I][1] = '#') then
        Continue;
      Source := Decode(Lines[I]);
      if ParseShellScript(Source, Script, Error) then
      begin
        Inc(Parsed);
        try
          WalkStatement(Script.Root);
        finally
          Script.Free;
        end;
      end
      else
        Inc(Failed);
    end;
    WriteLn('corpus entries parsed: ', Parsed, '   not parsed: ', Failed);
    WriteLn('simple commands: ', Simple, '   non-literal command names: ',
      NonLiteralName);
    WriteLn('distinct command names: ', Commands.Counts.Count, '   distinct flags: ',
      Flags.Counts.Count);
    Commands.Report('COMMAND NAME (how often the corpus calls it)', Top);
    Flags.Report('OPTION TOKEN (command + literal flag)', Top);
    Programs.Report('PROGRAM TEXT (sed/awk/jq/yq/rg + first non-option literal)',
      Top);
  finally
    Programs.Free;
    Flags.Free;
    Commands.Free;
    Lines.Free;
  end;
end.
