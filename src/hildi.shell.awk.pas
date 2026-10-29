unit hildi.shell.awk;
{ A field-oriented awk subset for the builtin shell tier.

  Supported: -F (a single-character separator); a program of the form
  [condition] followed by a print action; conditions = a regex on $0, or
  comparisons over
  $N / NF / NR with == != < <= > >= ~ !~ joined by && and ||; print lists of
  $N / $0 / NF / NR / string / number literals.

  Not supported (a program error, never a silent approximation): BEGIN/END,
  functions, arrays, getline, printf, variables, assignments, if/while/for.

  No OS units: this runs wherever the RTL does (the Windows target included). }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, hildi.shell.pattern;

{ Run AProgram over AInput. AFieldSep is -F ('' = whitespace runs).
  False + AError on a program error. }
function RunAwk(const AProgram, AInput, AFieldSep: string;
  out AOutput, AError: string): Boolean;

implementation

uses
  regexpr, hildi.shell.textlines;

type
  TOperandKind = (okField, okNF, okNR, okString, okNumber);

  TOperand = record
    Kind: TOperandKind;
    Index: Integer;   // okField
    Text: string;     // okString / the literal spelling
  end;

  TAtomKind = (akRegex, akCompare);

  TAtom = record
    Kind: TAtomKind;
    Re: TRegExpr;     // akRegex (on $0), or the pattern of ~ / !~
    Left, Right: TOperand;
    Op: string;
  end;

  TAndList = array of TAtom;
  TOrList = array of TAndList;

  TPrintItem = record
    Parts: array of TOperand;
  end;

  TPrintList = array of TPrintItem;

  TAwkProgram = class
  public
    Condition: TOrList;
    HasCondition: Boolean;
    Prints: TPrintList;
    HasAction: Boolean;
    destructor Destroy; override;
    function Parse(const AProgram: string; out AError: string): Boolean;
  end;


function Compile(const APattern: string; out AError: string): TRegExpr;
begin
  Result := nil;
  AError := '';
  try
    Result := TRegExpr.Create;
    Result.Expression := TranslatePattern(APattern, True, AError);
    if AError <> '' then
    begin
      FreeAndNil(Result);
      Exit;
    end;
    Result.Exec('');
  except
    on E: Exception do
    begin
      AError := E.Message;
      FreeAndNil(Result);
    end;
  end;
end;

destructor TAwkProgram.Destroy;
var
  I, J: Integer;
begin
  for I := 0 to High(Condition) do
    for J := 0 to High(Condition[I]) do
      Condition[I][J].Re.Free;
  inherited Destroy;
end;

{ --- parsing ------------------------------------------------------------ }

function TAwkProgram.Parse(const AProgram: string; out AError: string): Boolean;
var
  Text, CondText, ActText: string;
  I, Open, Close: Integer;
  Atom: TAtom;
  Op: TOperand;

  function SkipSpaces(const S: string; var P: Integer): Boolean;
  begin
    while (P <= Length(S)) and (S[P] in [' ', #9]) do
      Inc(P);
    Result := P <= Length(S);
  end;

  function ParseOperand(const S: string; var P: Integer;
    out AOp: TOperand): Boolean;
  var
    Start: Integer;
    C: Char;
  begin
    AOp := Default(TOperand);
    SkipSpaces(S, P);
    Result := False;
    if P > Length(S) then
      Exit;
    if S[P] = '$' then
    begin
      Inc(P);
      Start := P;
      while (P <= Length(S)) and (S[P] in ['0'..'9']) do
        Inc(P);
      if P = Start then
        Exit;
      AOp.Kind := okField;
      AOp.Index := StrToIntDef(Copy(S, Start, P - Start), 0);
      Exit(True);
    end;
    if (Copy(S, P, 2) = 'NF') and
      ((P + 2 > Length(S)) or not (S[P + 2] in ['a'..'z', 'A'..'Z', '0'..'9'])) then
    begin
      AOp.Kind := okNF;
      Inc(P, 2);
      Exit(True);
    end;
    if (Copy(S, P, 2) = 'NR') and
      ((P + 2 > Length(S)) or not (S[P + 2] in ['a'..'z', 'A'..'Z', '0'..'9'])) then
    begin
      AOp.Kind := okNR;
      Inc(P, 2);
      Exit(True);
    end;
    if S[P] = '"' then
    begin
      Inc(P);
      while (P <= Length(S)) and (S[P] <> '"') do
      begin
        if S[P] = '\' then
        begin
          Inc(P);
          if P > Length(S) then
            Exit;
          C := S[P];
          if C = 'n' then
            AOp.Text := AOp.Text + #10
          else if C = 't' then
            AOp.Text := AOp.Text + #9
          else
            AOp.Text := AOp.Text + C;
          Inc(P);
        end
        else
        begin
          AOp.Text := AOp.Text + S[P];
          Inc(P);
        end;
      end;
      if P > Length(S) then
        Exit;
      Inc(P);
      AOp.Kind := okString;
      Exit(True);
    end;
    if S[P] in ['-', '0'..'9'] then
    begin
      Start := P;
      if S[P] = '-' then
        Inc(P);
      while (P <= Length(S)) and (S[P] in ['0'..'9', '.']) do
        Inc(P);
      AOp.Kind := okNumber;
      AOp.Text := Copy(S, Start, P - Start);
      Exit(True);
    end;
  end;

  function ParseRegex(const S: string; var P: Integer;
    out ARe: TRegExpr): Boolean;
  var
    Pat: string;
  begin
    ARe := nil;
    Result := False;
    if (P > Length(S)) or (S[P] <> '/') then
      Exit;
    Inc(P);
    Pat := '';
    while (P <= Length(S)) and (S[P] <> '/') do
    begin
      if S[P] = '\' then
      begin
        Pat := Pat + S[P];
        Inc(P);
        if P <= Length(S) then
        begin
          Pat := Pat + S[P];
          Inc(P);
        end;
      end
      else
      begin
        Pat := Pat + S[P];
        Inc(P);
      end;
    end;
    if P > Length(S) then
      Exit;
    Inc(P);
    ARe := Compile(Pat, AError);
    Result := ARe <> nil;
  end;

  function ParseAtom(const S: string; var P: Integer;
    out AAtom: TAtom): Boolean;
  var
    OpName: string;
  begin
    AAtom := Default(TAtom);
    Result := False;
    SkipSpaces(S, P);
    if (P <= Length(S)) and (S[P] = '/') then
    begin
      AAtom.Kind := akRegex;
      Exit(ParseRegex(S, P, AAtom.Re));
    end;
    AAtom.Kind := akCompare;
    if not ParseOperand(S, P, AAtom.Left) then
      Exit;
    SkipSpaces(S, P);
    OpName := '';
    if Copy(S, P, 2) = '!~' then
    begin
      OpName := '!~';
      Inc(P, 2);
    end
    else if Copy(S, P, 2) = '==' then
    begin
      OpName := '==';
      Inc(P, 2);
    end
    else if Copy(S, P, 2) = '!=' then
    begin
      OpName := '!=';
      Inc(P, 2);
    end;
    if OpName = '' then
    begin
      if P > Length(S) then
        Exit;
      case S[P] of
        '<':
          begin
            OpName := '<';
            Inc(P);
            if (P <= Length(S)) and (S[P] = '=') then
            begin
              OpName := '<=';
              Inc(P);
            end;
          end;
        '>':
          begin
            OpName := '>';
            Inc(P);
            if (P <= Length(S)) and (S[P] = '=') then
            begin
              OpName := '>=';
              Inc(P);
            end;
          end;
        '~':
          begin
            OpName := '~';
            Inc(P);
          end;
      else
        Exit;
      end;
    end;
    AAtom.Op := OpName;
    if (OpName = '~') or (OpName = '!~') then
    begin
      SkipSpaces(S, P);
      if not ParseRegex(S, P, AAtom.Re) then
        Exit;
    end
    else if not ParseOperand(S, P, AAtom.Right) then
      Exit;
    Result := True;
  end;

  function ParseAction: Boolean;
  var
    P: Integer;
    Item: TPrintItem;
  begin
    Result := False;
    P := 1;
    while P <= Length(ActText) do
    begin
      while (P <= Length(ActText)) and (ActText[P] in [' ', #9, ';']) do
        Inc(P);
      if P > Length(ActText) then
        Break;
      if Copy(ActText, P, 5) <> 'print' then
      begin
        AError := 'unsupported awk action: ' + ActText;
        Exit;
      end;
      Inc(P, 5);
      Item := Default(TPrintItem);
      while True do
      begin
        SkipSpaces(ActText, P);
        if (P > Length(ActText)) or (ActText[P] = ';') then
          Break;
        if not ParseOperand(ActText, P, Op) then
        begin
          AError := 'unsupported awk print expression: ' +
            Copy(ActText, P, MaxInt);
          Exit;
        end;
        SetLength(Item.Parts, Length(Item.Parts) + 1);
        Item.Parts[High(Item.Parts)] := Op;
        SkipSpaces(ActText, P);
        if (P <= Length(ActText)) and (ActText[P] = ',') then
        begin
          Inc(P);
          Continue;
        end;
        Break;
      end;
      if Length(Item.Parts) = 0 then
      begin
        SetLength(Item.Parts, 1);
        Item.Parts[0].Kind := okField;
        Item.Parts[0].Index := 0;
      end;
      SetLength(Prints, Length(Prints) + 1);
      Prints[High(Prints)] := Item;
    end;
    Result := True;
  end;

begin
  AError := '';
  Condition := nil;
  Prints := nil;
  HasCondition := False;
  HasAction := False;
  Text := Trim(AProgram);
  if Text = '' then
  begin
    AError := 'empty awk program';
    Exit(False);
  end;
  Open := 0;
  for I := 1 to Length(Text) do
    if Text[I] = '{' then
    begin
      Open := I;
      Break;
    end;
  if Open > 0 then
  begin
    Close := 0;
    for I := Open + 1 to Length(Text) do
      if Text[I] = '}' then
      begin
        Close := I;
        Break;
      end;
    if Close = 0 then
    begin
      AError := 'unterminated awk action';
      Exit(False);
    end;
    CondText := Trim(Copy(Text, 1, Open - 1));
    ActText := Trim(Copy(Text, Open + 1, Close - Open - 1));
    if Trim(Copy(Text, Close + 1, MaxInt)) <> '' then
    begin
      AError := 'unsupported awk program: trailing text';
      Exit(False);
    end;
    HasAction := True;
    if not ParseAction then
      Exit(False);
  end
  else
    CondText := Text;
  if CondText <> '' then
  begin
    HasCondition := True;
    SetLength(Condition, 1);
    I := 1;
    while True do
    begin
      if not ParseAtom(CondText, I, Atom) then
      begin
        if AError = '' then
          AError := 'unsupported awk condition: ' + Copy(CondText, I, MaxInt);
        Exit(False);
      end;
      SetLength(Condition[High(Condition)],
        Length(Condition[High(Condition)]) + 1);
      Condition[High(Condition)][High(Condition[High(Condition)])] := Atom;
      SkipSpaces(CondText, I);
      if Copy(CondText, I, 2) = '&&' then
      begin
        Inc(I, 2);
        Continue;
      end;
      if Copy(CondText, I, 2) = '||' then
      begin
        Inc(I, 2);
        SetLength(Condition, Length(Condition) + 1);
        Continue;
      end;
      Break;
    end;
    if I <= Length(CondText) then
    begin
      AError := 'unsupported awk condition: ' + Copy(CondText, I, MaxInt);
      Exit(False);
    end;
  end;
  if (not HasCondition) and (not HasAction) then
  begin
    AError := 'empty awk program';
    Exit(False);
  end;
  Result := True;
end;

{ --- evaluation --------------------------------------------------------- }

function FieldsOf(const ALine, ASep: string): TStringArray;
var
  I, N, K: Integer;
  C: Char;
begin
  Result := nil;
  if ASep = ' ' then
  begin
    K := 0;
    I := 1;
    while I <= Length(ALine) do
    begin
      while (I <= Length(ALine)) and (ALine[I] in [' ', #9]) do
        Inc(I);
      N := I;
      while (N <= Length(ALine)) and (not (ALine[N] in [' ', #9])) do
        Inc(N);
      if N > I then
      begin
        SetLength(Result, K + 1);
        Result[K] := Copy(ALine, I, N - I);
        Inc(K);
      end;
      I := N;
    end;
    Exit;
  end;
  C := ASep[1];
  K := 0;
  I := 1;
  while True do
  begin
    N := I;
    while (N <= Length(ALine)) and (ALine[N] <> C) do
      Inc(N);
    SetLength(Result, K + 1);
    Result[K] := Copy(ALine, I, N - I);
    Inc(K);
    if N > Length(ALine) then
      Break;
    I := N + 1;
  end;
end;

function FieldAt(const ALine: string; const AFields: TStringArray;
  AIndex: Integer): string;
begin
  if AIndex = 0 then
    Exit(ALine);
  if (AIndex >= 1) and (AIndex <= Length(AFields)) then
    Exit(AFields[AIndex - 1]);
  Result := '';
end;

function OperandValue(const AOp: TOperand; const ALine: string;
  const AFields: TStringArray; ANR: Integer): string;
begin
  case AOp.Kind of
    okField: Result := FieldAt(ALine, AFields, AOp.Index);
    okNF: Result := IntToStr(Length(AFields));
    okNR: Result := IntToStr(ANR);
    okString: Result := AOp.Text;
    okNumber: Result := AOp.Text;
  end;
end;

function AsNumber(const S: string; out AValue: Double): Boolean;
begin
  Result := TryStrToFloat(Trim(S), AValue);
end;

function Compare(const ALeft, ARight, AOp: string): Boolean;
var
  L, R: Double;
  LN, RN: Boolean;
begin
  LN := AsNumber(ALeft, L);
  RN := AsNumber(ARight, R);
  if LN and RN then
  begin
    if AOp = '==' then Exit(L = R);
    if AOp = '!=' then Exit(L <> R);
    if AOp = '<' then Exit(L < R);
    if AOp = '<=' then Exit(L <= R);
    if AOp = '>' then Exit(L > R);
    if AOp = '>=' then Exit(L >= R);
  end
  else
  begin
    if AOp = '==' then Exit(ALeft = ARight);
    if AOp = '!=' then Exit(ALeft <> ARight);
    if AOp = '<' then Exit(ALeft < ARight);
    if AOp = '<=' then Exit(ALeft <= ARight);
    if AOp = '>' then Exit(ALeft > ARight);
    if AOp = '>=' then Exit(ALeft >= ARight);
  end;
  Result := False;
end;

function AtomMatches(const AAtom: TAtom; const ALine: string;
  const AFields: TStringArray; ANR: Integer): Boolean;
var
  LeftVal: string;
begin
  if AAtom.Kind = akRegex then
    Exit(AAtom.Re.Exec(ALine));
  LeftVal := OperandValue(AAtom.Left, ALine, AFields, ANR);
  if (AAtom.Op = '~') or (AAtom.Op = '!~') then
  begin
    Result := AAtom.Re.Exec(LeftVal);
    if AAtom.Op = '!~' then
      Result := not Result;
    Exit;
  end;
  Result := Compare(LeftVal, OperandValue(AAtom.Right, ALine, AFields, ANR),
    AAtom.Op);
end;

function ConditionMatches(const AProg: TAwkProgram; const ALine: string;
  const AFields: TStringArray; ANR: Integer): Boolean;
var
  I, J: Integer;
  AllAnd: Boolean;
begin
  if not AProg.HasCondition then
    Exit(True);
  for I := 0 to High(AProg.Condition) do
  begin
    AllAnd := True;
    for J := 0 to High(AProg.Condition[I]) do
      if not AtomMatches(AProg.Condition[I][J], ALine, AFields, ANR) then
      begin
        AllAnd := False;
        Break;
      end;
    if AllAnd then
      Exit(True);
  end;
  Result := False;
end;

function RunAwk(const AProgram, AInput, AFieldSep: string;
  out AOutput, AError: string): Boolean;
var
  Prog: TAwkProgram;
  Lines, Fields: TStringArray;
  I, J, K: Integer;
  Sep, Piece: string;
begin
  AOutput := '';
  AError := '';
  Result := False;
  Prog := TAwkProgram.Create;
  try
    if not Prog.Parse(AProgram, AError) then
      Exit(False);
    if AFieldSep = '' then
      Sep := ' '
    else
      Sep := AFieldSep;
    Lines := LinesOf(AInput);
    for I := 0 to High(Lines) do
    begin
      Fields := FieldsOf(Lines[I], Sep);
      if not ConditionMatches(Prog, Lines[I], Fields, I + 1) then
        Continue;
      if not Prog.HasAction then
      begin
        AOutput := AOutput + Lines[I] + #10;
        Continue;
      end;
      for J := 0 to High(Prog.Prints) do
      begin
        Piece := '';
        for K := 0 to High(Prog.Prints[J].Parts) do
        begin
          if K > 0 then
            Piece := Piece + ' ';
          Piece := Piece + OperandValue(Prog.Prints[J].Parts[K], Lines[I],
            Fields, I + 1);
        end;
        AOutput := AOutput + Piece + #10;
      end;
    end;
    Result := True;
  finally
    Prog.Free;
  end;
end;

end.
