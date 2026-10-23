unit hildegard.helper.shell.sed;
{ A line-oriented sed subset for the builtin shell tier.

  Supported: -n, -E/-r, -e, -i[SUFFIX]; addresses (N, $, /re/, and the
  ranges N,M, N,$, /re/,/re/, /re/,$); the p, d, q and s commands, with the
  g/p/i flags on s.

  The pattern language is bash's: BRE by default, ERE with -E, translated to
  the engine by shell.pattern. A program outside the subset is a program error
  (status 1), never a silent approximation. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, hildegard.helper.shell.pattern;

{ Run AProgram over AInput. ASuppress is -n; AExtended is -E.
  False + AError on a program error. }
function RunSed(const AProgram, AInput: string; ASuppress, AExtended: Boolean;
  out AOutput, AError: string): Boolean;

implementation

uses
  regexpr, hildegard.helper.shell.textlines;

type
  TAddrKind = (akNone, akLine, akLast, akRegex);

  TAddress = record
    Kind: TAddrKind;
    Line: Integer;
    Regex: TRegExpr;
  end;

  TSedOp = (soPrint, soDelete, soSubst, soQuit);

  TSedCommand = record
    A1, A2: TAddress;
    HasA2: Boolean;
    Op: TSedOp;
    Re: TRegExpr;
    Replacement: string;
    Global: Boolean;
    PrintAfter: Boolean;
    InRange: Boolean;
  end;

  TSedProgram = class
  public
    Commands: array of TSedCommand;
    destructor Destroy; override;
    function Add: Integer;
    function Parse(const AProgram: string; AExtended: Boolean;
      out AError: string): Boolean;
  end;


destructor TSedProgram.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(Commands) do
  begin
    Commands[I].A1.Regex.Free;
    Commands[I].A2.Regex.Free;
    Commands[I].Re.Free;
  end;
  inherited Destroy;
end;

function TSedProgram.Add: Integer;
begin
  Result := Length(Commands);
  SetLength(Commands, Result + 1);
  Commands[Result] := Default(TSedCommand);
end;

function CompileRegex(const APattern: string; AExtended: Boolean;
  out AError: string): TRegExpr;
begin
  Result := nil;
  AError := '';
  try
    Result := TRegExpr.Create;
    Result.Expression := TranslatePattern(APattern, AExtended, AError);
    if AError <> '' then
    begin
      FreeAndNil(Result);
      Exit;
    end;
    Result.Exec('');   // force compilation
  except
    on E: Exception do
    begin
      AError := E.Message;
      FreeAndNil(Result);
    end;
  end;
end;

function TSedProgram.Parse(const AProgram: string; AExtended: Boolean;
  out AError: string): Boolean;
var
  I: Integer;
  Cmd: Integer;
  C, Delim: Char;
  Pat, Repl, Flags: string;

  function SkipSeparators: Boolean;
  begin
    while (I <= Length(AProgram)) and
      (AProgram[I] in [' ', #9, #10, #13, ';']) do
      Inc(I);
    Result := I <= Length(AProgram);
  end;

  function ParseAddress(out A: TAddress): Boolean;
  var
    N: Integer;
    P: string;
  begin
    A := Default(TAddress);
    A.Kind := akNone;
    Result := True;
    while (I <= Length(AProgram)) and (AProgram[I] = ' ') do
      Inc(I);
    if I > Length(AProgram) then
      Exit;
    if AProgram[I] = '$' then
    begin
      A.Kind := akLast;
      Inc(I);
      Exit;
    end;
    if AProgram[I] = '/' then
    begin
      Inc(I);
      P := '';
      while (I <= Length(AProgram)) and (AProgram[I] <> '/') do
      begin
        if AProgram[I] = '\' then
        begin
          P := P + AProgram[I];
          Inc(I);
          if I <= Length(AProgram) then
          begin
            P := P + AProgram[I];
            Inc(I);
          end;
        end
        else
        begin
          P := P + AProgram[I];
          Inc(I);
        end;
      end;
      if I > Length(AProgram) then
      begin
        AError := 'unterminated address regex';
        Exit(False);
      end;
      Inc(I);
      A.Kind := akRegex;
      A.Regex := CompileRegex(P, AExtended, AError);
      if A.Regex = nil then
        Exit(False);
      Exit;
    end;
    if AProgram[I] in ['0'..'9'] then
    begin
      N := 0;
      while (I <= Length(AProgram)) and (AProgram[I] in ['0'..'9']) do
      begin
        N := N * 10 + (Ord(AProgram[I]) - Ord('0'));
        Inc(I);
      end;
      A.Kind := akLine;
      A.Line := N;
    end;
  end;

begin
  AError := '';
  I := 1;
  while SkipSeparators do
  begin
    Cmd := Add;
    if not ParseAddress(Commands[Cmd].A1) then
      Exit(False);
    while (I <= Length(AProgram)) and (AProgram[I] = ' ') do
      Inc(I);
    if (I <= Length(AProgram)) and (AProgram[I] = ',') then
    begin
      Inc(I);
      Commands[Cmd].HasA2 := True;
      if not ParseAddress(Commands[Cmd].A2) then
        Exit(False);
    end;
    while (I <= Length(AProgram)) and (AProgram[I] = ' ') do
      Inc(I);
    if I > Length(AProgram) then
    begin
      AError := 'missing command';
      Exit(False);
    end;
    C := AProgram[I];
    case C of
      'p':
        begin
          Commands[Cmd].Op := soPrint;
          Inc(I);
        end;
      'd':
        begin
          Commands[Cmd].Op := soDelete;
          Inc(I);
        end;
      'q':
        begin
          Commands[Cmd].Op := soQuit;
          Inc(I);
        end;
      's':
        begin
          Commands[Cmd].Op := soSubst;
          Inc(I);
          if I > Length(AProgram) then
          begin
            AError := 'unterminated s command';
            Exit(False);
          end;
          Delim := AProgram[I];
          Inc(I);
          Pat := '';
          while (I <= Length(AProgram)) and (AProgram[I] <> Delim) do
            if AProgram[I] = '\' then
            begin
              Pat := Pat + AProgram[I];
              Inc(I);
              if I <= Length(AProgram) then
              begin
                Pat := Pat + AProgram[I];
                Inc(I);
              end;
            end
            else
            begin
              Pat := Pat + AProgram[I];
              Inc(I);
            end;
          if I > Length(AProgram) then
          begin
            AError := 'unterminated s pattern';
            Exit(False);
          end;
          Inc(I);
          Repl := '';
          while (I <= Length(AProgram)) and (AProgram[I] <> Delim) do
            if AProgram[I] = '\' then
            begin
              Repl := Repl + AProgram[I];
              Inc(I);
              if I <= Length(AProgram) then
              begin
                Repl := Repl + AProgram[I];
                Inc(I);
              end;
            end
            else
            begin
              Repl := Repl + AProgram[I];
              Inc(I);
            end;
          if I > Length(AProgram) then
          begin
            AError := 'unterminated s replacement';
            Exit(False);
          end;
          Inc(I);
          Flags := '';
          while (I <= Length(AProgram)) and
            (AProgram[I] in ['g', 'p', 'i', 'I']) do
          begin
            Flags := Flags + AProgram[I];
            Inc(I);
          end;
          Commands[Cmd].Replacement := Repl;
          Commands[Cmd].Global := Pos('g', Flags) > 0;
          Commands[Cmd].PrintAfter := Pos('p', Flags) > 0;
          Commands[Cmd].Re := CompileRegex(Pat, AExtended, AError);
          if Commands[Cmd].Re = nil then
            Exit(False);
          if (Pos('i', Flags) > 0) or (Pos('I', Flags) > 0) then
            Commands[Cmd].Re.ModifierI := True;
        end;
    else
      begin
        AError := 'unsupported sed command: ' + C;
        Exit(False);
      end;
    end;
  end;
  Result := True;
end;

function AddrMatches(const AAddr: TAddress; ALineNo, ATotal: Integer;
  const ALine: string): Boolean;
begin
  case AAddr.Kind of
    akNone: Result := True;
    akLine: Result := ALineNo = AAddr.Line;
    akLast: Result := ALineNo = ATotal;
    akRegex: Result := AAddr.Regex.Exec(ALine);
  end;
end;

{ Address state for one command: a range stays active until its end address
  matches (inclusive). A regex end is not tested on the line that opened the
  range, which is bash's behaviour. }
function AddressActive(var ACmd: TSedCommand; ALineNo, ATotal: Integer;
  const ALine: string): Boolean;
begin
  if not ACmd.HasA2 then
    Exit(AddrMatches(ACmd.A1, ALineNo, ATotal, ALine));
  if ACmd.InRange then
  begin
    Result := True;
    if AddrMatches(ACmd.A2, ALineNo, ATotal, ALine) then
      ACmd.InRange := False;
    Exit;
  end;
  Result := AddrMatches(ACmd.A1, ALineNo, ATotal, ALine);
  if not Result then
    Exit;
  ACmd.InRange := True;
  if (ACmd.A2.Kind = akLine) and (ALineNo >= ACmd.A2.Line) then
    ACmd.InRange := False;
end;

function ExpandReplacement(ARe: TRegExpr; const ARepl: string): string;
var
  I, N: Integer;
  C: Char;
begin
  Result := '';
  I := 1;
  while I <= Length(ARepl) do
  begin
    C := ARepl[I];
    if C = '&' then
    begin
      Result := Result + ARe.Match[0];
      Inc(I);
    end
    else if C = '\' then
    begin
      Inc(I);
      if I > Length(ARepl) then
        Break;
      C := ARepl[I];
      if (C >= '0') and (C <= '9') then
      begin
        N := Ord(C) - Ord('0');
        if N <= 9 then
          Result := Result + ARe.Match[N];
        Inc(I);
      end
      else
      begin
        { Recognised escapes. Anything else stays literal, which is what sed
          does -- but the escapes that DO exist must actually work. Emitting the
          character verbatim for every non-digit made `\n` produce the letter n,
          which is what a caller reported seeing where a line break belonged. }
        if C = 'n' then
          Result := Result + #10
        else if C = 't' then
          Result := Result + #9
        else if C = 'r' then
          Result := Result + #13
        else if C = '\' then
          Result := Result + '\'
        else if C = '&' then
          Result := Result + '&'   { escaped & is a literal ampersand }
        else
          Result := Result + C;
        Inc(I);
      end;
    end
    else
    begin
      Result := Result + C;
      Inc(I);
    end;
  end;
end;

{ Substitute on ALine with ARe already matched at least once. }
function SubstituteLine(ARe: TRegExpr; const ALine, ARepl: string;
  AGlobal: Boolean): string;
var
  Rest, Piece: string;
  P, Len: Integer;
begin
  Result := '';
  Rest := ALine;
  while ARe.Exec(Rest) do
  begin
    P := ARe.MatchPos[0];
    Len := ARe.MatchLen[0];
    Result := Result + Copy(Rest, 1, P - 1) + ExpandReplacement(ARe, ARepl);
    if not AGlobal then
    begin
      Rest := Copy(Rest, P + Len, MaxInt);
      Break;
    end;
    if Len = 0 then
    begin
      if P <= Length(Rest) then
      begin
        Result := Result + Copy(Rest, P, 1);
        Rest := Copy(Rest, P + 1, MaxInt);
      end
      else
      begin
        Rest := '';
        Break;
      end;
    end
    else
      Rest := Copy(Rest, P + Len, MaxInt);
  end;
  Result := Result + Rest;
end;

function RunSed(const AProgram, AInput: string; ASuppress, AExtended: Boolean;
  out AOutput, AError: string): Boolean;
var
  P: TSedProgram;
  Lines: TStringArray;
  I, J: Integer;
  Line: string;
  Deleted, Quit: Boolean;
begin
  AOutput := '';
  AError := '';
  Result := False;
  P := TSedProgram.Create;
  try
    if not P.Parse(AProgram, AExtended, AError) then
      Exit(False);
    Lines := LinesOf(AInput);
    for I := 0 to High(Lines) do
    begin
      Line := Lines[I];
      Deleted := False;
      Quit := False;
      for J := 0 to High(P.Commands) do
      begin
        if not AddressActive(P.Commands[J], I + 1, Length(Lines), Line) then
          Continue;
        case P.Commands[J].Op of
          soPrint: AOutput := AOutput + Line + #10;
          soDelete:
            begin
              Deleted := True;
              Break;
            end;
          soQuit:
            begin
              Quit := True;
              Break;
            end;
          soSubst:
            if P.Commands[J].Re.Exec(Line) then
            begin
              Line := SubstituteLine(P.Commands[J].Re, Line,
                P.Commands[J].Replacement, P.Commands[J].Global);
              if P.Commands[J].PrintAfter then
                AOutput := AOutput + Line + #10;
            end;
        end;
      end;
      if (not Deleted) and (not ASuppress) then
        AOutput := AOutput + Line + #10;
      if Quit then
        Break;
    end;
    Result := True;
  finally
    P.Free;
  end;
end;

end.
