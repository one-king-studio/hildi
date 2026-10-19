unit shell.lexer;
{ The shell lexer: source text -> tokens. It finds word boundaries respecting
  quotes, command substitution, braced expansions, backticks and escapes, and
  folds an fd prefix into a redirect operator (2> is fd 2; "2 >" is the word 2
  and a redirect).

  Here-docs are the one interaction with the parser: when the parser sees << it
  registers the delimiter; the lexer collects the body when it reaches the next
  newline and attaches it to that newline token. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, shell.types;

type
  TTokenKind = (tkWord, tkNewline, tkEOF, tkOp);

  TOpKind = (opPipe, opPipeErr, opAnd, opOr, opSemi, opDSemi, opSemiAnd,
    opDSemiAnd, opAmp, opLParen, opRParen,
    opLess, opGreat, opDGreat, opDLess, opDLessDash, opTLess,
    opLessAnd, opGreatAnd, opLessGreat, opGreatPipe, opAndGreat, opAndDGreat);

  THereDocSpec = record
    Delimiter: string;
    Strip: Boolean;
    Quoted: Boolean;      // the delimiter was quoted: no body expansion
  end;
  THereDocSpecArray = array of THereDocSpec;

  TToken = record
    Kind: TTokenKind;
    Op: TOpKind;
    Text: string;              // raw word text (quotes kept)
    FD: Integer;               // a redirect's fd prefix; -1 = none
    HasSpaceBefore: Boolean;
    Offset, Line, Column: Integer;
    HereDocs: array of string; // bodies for the newline that closes the line
  end;

  TLexer = class
  private
    FSource: string;
    FPos: Integer;             // 1-based; Length+1 is EOF
    FLine: Integer;
    FCol: Integer;
    FPending: THereDocSpecArray;
    FHereNext: Boolean;         // the next word is a here-doc delimiter
    FHereStripNext: Boolean;
    FError: TShellParseError;
    FHasError: Boolean;
    function Peek(AOffset: Integer): Char;
    procedure Advance;
    procedure Fail(const AMsg: string; AOffset, ALine, ACol: Integer);
    function TryOp(out AOp: TOpKind; out AFD: Integer): Boolean;
    function ScanWordRaw: string;
    procedure SkipParenGroup;
    procedure SkipBraceGroup;
    procedure RegisterDelimiter(const ARaw: string);
    procedure CollectHereDocs(var AToken: TToken);
  public
    constructor Create(const ASource: string);
    { The next token. A lexical error is sticky: after it, every call is EOF and
      HasError is True. }
    function Next: TToken;
    property Error: TShellParseError read FError;
    property HasError: Boolean read FHasError;
    property Line: Integer read FLine;
    property Column: Integer read FCol;
  end;

implementation

constructor TLexer.Create(const ASource: string);
begin
  inherited Create;
  FSource := ASource;
  FPos := 1;
  FLine := 1;
  FCol := 1;
end;

function TLexer.Peek(AOffset: Integer): Char;
var
  P: Integer;
begin
  P := FPos + AOffset;
  if (P < 1) or (P > Length(FSource)) then
    Result := #0
  else
    Result := FSource[P];
end;

procedure TLexer.Advance;
begin
  if FPos > Length(FSource) then
    Exit;
  if FSource[FPos] = #10 then
  begin
    Inc(FLine);
    FCol := 1;
  end
  else
    Inc(FCol);
  Inc(FPos);
end;

procedure TLexer.Fail(const AMsg: string; AOffset, ALine, ACol: Integer);
begin
  if FHasError then
    Exit;
  FHasError := True;
  FError := Default(TShellParseError);
  FError.Offset := AOffset;
  FError.Line := ALine;
  FError.Column := ACol;
  FError.Message := AMsg;
end;

procedure TLexer.RegisterDelimiter(const ARaw: string);
var
  I, N: Integer;
  Text: string;
  Quoted: Boolean;
  C: Char;
begin
  Text := '';
  Quoted := False;
  I := 1;
  while I <= Length(ARaw) do
  begin
    C := ARaw[I];
    if (C = '''') or (C = '"') then
    begin
      Quoted := True;
      Inc(I);
      while (I <= Length(ARaw)) and (ARaw[I] <> C) do
      begin
        Text := Text + ARaw[I];
        Inc(I);
      end;
      if I <= Length(ARaw) then
        Inc(I);
    end
    else if C = '\' then
    begin
      Quoted := True;
      Inc(I);
      if I <= Length(ARaw) then
      begin
        Text := Text + ARaw[I];
        Inc(I);
      end;
    end
    else
    begin
      Text := Text + C;
      Inc(I);
    end;
  end;
  N := Length(FPending);
  SetLength(FPending, N + 1);
  FPending[N] := Default(THereDocSpec);
  FPending[N].Delimiter := Text;
  FPending[N].Strip := FHereStripNext;
  FPending[N].Quoted := Quoted;
end;

procedure TLexer.CollectHereDocs(var AToken: TToken);
var
  I, N: Integer;
  Body: string;
  Line: string;
  LineText: string;
  Done: Boolean;
begin
  for I := 0 to High(FPending) do
  begin
    Body := '';
    while True do
    begin
      { Read one raw line from the current position. }
      Line := '';
      while (Peek(0) <> #0) and (Peek(0) <> #10) do
      begin
        Line := Line + Peek(0);
        Advance;
      end;
      if Peek(0) = #10 then
        Advance;
      Done := Peek(0) = #0;
      LineText := Line;
      if FPending[I].Strip then
      begin
        while (LineText <> '') and (LineText[1] = #9) do
          Delete(LineText, 1, 1);
      end;
      if LineText = FPending[I].Delimiter then
        Break;
      if Done and (Line = '') then
      begin
        Fail('unterminated here-document: ' + FPending[I].Delimiter,
          FPos, FLine, FCol);
        Exit;
      end;
      Body := Body + LineText + #10;
    end;
    N := Length(AToken.HereDocs);
    SetLength(AToken.HereDocs, N + 1);
    AToken.HereDocs[N] := Body;
  end;
  FPending := nil;
end;

{ Skip a balanced $( ... ) group. Starts with FPos at '$'. }
procedure TLexer.SkipParenGroup;
var
  Depth: Integer;
  Mode: (qmNone, qmSingle, qmDouble);
  C: Char;
begin
  Advance;   // $
  if Peek(0) = '(' then
    Advance;
  if Peek(0) = '(' then
    Advance;
  Depth := 1;
  Mode := qmNone;
  while (Peek(0) <> #0) and (Depth > 0) do
  begin
    C := Peek(0);
    case Mode of
      qmNone:
        begin
          if C = '''' then
            Mode := qmSingle
          else if C = '"' then
            Mode := qmDouble
          else if C = '\' then
            Advance
          else if C = '(' then
            Inc(Depth)
          else if C = ')' then
            Dec(Depth);
        end;
      qmSingle:
        if C = '''' then
          Mode := qmNone;
      qmDouble:
        begin
          if C = '"' then
            Mode := qmNone
          else if C = '\' then
            Advance;
        end;
    end;
    Advance;
  end;
end;

{ Skip a balanced dollar-brace group. Starts with FPos at the dollar. }
procedure TLexer.SkipBraceGroup;
var
  Depth: Integer;
begin
  Advance;   // $
  if Peek(0) = '{' then
    Advance;
  Depth := 1;
  while (Peek(0) <> #0) and (Depth > 0) do
  begin
    if Peek(0) = '\' then
      Advance
    else if Peek(0) = '{' then
      Inc(Depth)
    else if Peek(0) = '}' then
      Dec(Depth);
    Advance;
  end;
end;

function TLexer.ScanWordRaw: string;
var
  Start: Integer;
  C: Char;
begin
  Result := '';
  Start := FPos;
  while True do
  begin
    C := Peek(0);
    if C = #0 then
      Break;
    if (C = ' ') or (C = #9) or (C = #10) or (C = #13) then
      Break;
    if (C = ';') or (C = '&') or (C = '|') or (C = '<') or (C = '>') or
       (C = '(') or (C = ')') then
      Break;
    if C = '''' then
    begin
      Advance;
      while (Peek(0) <> #0) and (Peek(0) <> '''') do
        Advance;
      if Peek(0) = '''' then
        Advance
      else
      begin
        Fail('unterminated single quote', Start, FLine, FCol);
        Exit;
      end;
      Continue;
    end;
    if C = '"' then
    begin
      Advance;
      while (Peek(0) <> #0) and (Peek(0) <> '"') do
      begin
        if Peek(0) = '\' then
          Advance
        else if (Peek(0) = '$') and (Peek(1) = '(') then
          SkipParenGroup
        else if (Peek(0) = '$') and (Peek(1) = '{') then
          SkipBraceGroup;
        Advance;
      end;
      if Peek(0) = '"' then
        Advance
      else
      begin
        Fail('unterminated double quote', Start, FLine, FCol);
        Exit;
      end;
      Continue;
    end;
    if C = '`' then
    begin
      Advance;
      while (Peek(0) <> #0) and (Peek(0) <> '`') do
        Advance;
      if Peek(0) = '`' then
        Advance
      else
      begin
        Fail('unterminated backquote', Start, FLine, FCol);
        Exit;
      end;
      Continue;
    end;
    if C = '\' then
    begin
      Advance;
      if Peek(0) <> #0 then
        Advance;
      Continue;
    end;
    if C = '$' then
    begin
      if Peek(1) = '(' then
        SkipParenGroup
      else if Peek(1) = '{' then
        SkipBraceGroup
      else
        Advance;
      Continue;
    end;
    Advance;
  end;
  Result := Copy(FSource, Start, FPos - Start);
end;

function TLexer.TryOp(out AOp: TOpKind; out AFD: Integer): Boolean;
var
  C, D, E: Char;
begin
  Result := False;
  AFD := -1;
  C := Peek(0);
  D := Peek(1);
  E := Peek(2);

  { An fd prefix: digits immediately followed by a redirect operator. }
  if (C >= '0') and (C <= '9') and ((D = '<') or (D = '>')) then
  begin
    AFD := 0;
    while (Peek(0) >= '0') and (Peek(0) <= '9') do
    begin
      AFD := AFD * 10 + (Ord(Peek(0)) - Ord('0'));
      Advance;
    end;
    C := Peek(0);
    D := Peek(1);
    E := Peek(2);
  end;

  if (C = '&') and (D = '&') then
  begin
    AOp := opAnd; Advance; Advance; Exit(True);
  end;
  if (C = '&') and (D = '>') then
  begin
    if E = '>' then
    begin
      AOp := opAndDGreat; Advance; Advance; Advance; Exit(True);
    end;
    AOp := opAndGreat; Advance; Advance; Exit(True);
  end;
  if C = '&' then
  begin
    AOp := opAmp; Advance; Exit(True);
  end;

  if (C = ';') and (D = ';') and (E = '&') then
  begin
    AOp := opDSemiAnd; Advance; Advance; Advance; Exit(True);
  end;
  if (C = ';') and (D = ';') then
  begin
    AOp := opDSemi; Advance; Advance; Exit(True);
  end;
  if (C = ';') and (D = '&') then
  begin
    AOp := opSemiAnd; Advance; Advance; Exit(True);
  end;
  if C = ';' then
  begin
    AOp := opSemi; Advance; Exit(True);
  end;

  if (C = '|') and (D = '|') then
  begin
    AOp := opOr; Advance; Advance; Exit(True);
  end;
  if (C = '|') and (D = '&') then
  begin
    AOp := opPipeErr; Advance; Advance; Exit(True);
  end;
  if C = '|' then
  begin
    AOp := opPipe; Advance; Exit(True);
  end;

  if (C = '<') and (D = '<') and (E = '-') then
  begin
    AOp := opDLessDash; Advance; Advance; Advance; Exit(True);
  end;
  if (C = '<') and (D = '<') and (E = '<') then
  begin
    AOp := opTLess; Advance; Advance; Advance; Exit(True);
  end;
  if (C = '<') and (D = '<') then
  begin
    AOp := opDLess; Advance; Advance; Exit(True);
  end;
  if (C = '<') and (D = '>') then
  begin
    AOp := opLessGreat; Advance; Advance; Exit(True);
  end;
  if (C = '<') and (D = '&') then
  begin
    AOp := opLessAnd; Advance; Advance; Exit(True);
  end;
  if C = '<' then
  begin
    AOp := opLess; Advance; Exit(True);
  end;

  if (C = '>') and (D = '>') then
  begin
    AOp := opDGreat; Advance; Advance; Exit(True);
  end;
  if (C = '>') and (D = '&') then
  begin
    AOp := opGreatAnd; Advance; Advance; Exit(True);
  end;
  if (C = '>') and (D = '|') then
  begin
    AOp := opGreatPipe; Advance; Advance; Exit(True);
  end;
  if C = '>' then
  begin
    AOp := opGreat; Advance; Exit(True);
  end;

  if C = '(' then
  begin
    AOp := opLParen; Advance; Exit(True);
  end;
  if C = ')' then
  begin
    AOp := opRParen; Advance; Exit(True);
  end;
end;

function TLexer.Next: TToken;
var
  StartLine, StartCol, StartPos: Integer;
  C: Char;
  Op: TOpKind;
  FD: Integer;
begin
  Result := Default(TToken);
  Result.FD := -1;

  if FHasError then
  begin
    Result.Kind := tkEOF;
    Exit;
  end;

  while True do
  begin
    { Blanks. }
    while (Peek(0) = ' ') or (Peek(0) = #9) do
    begin
      Result.HasSpaceBefore := True;
      Advance;
    end;
    { A carriage return before a newline is swallowed. }
    if (Peek(0) = #13) and (Peek(1) = #10) then
      Advance;
    { Line continuation. }
    if (Peek(0) = '\') and (Peek(1) = #10) then
    begin
      Advance;
      Advance;
      Continue;
    end;
    { Comment to end of line. }
    if Peek(0) = '#' then
    begin
      while (Peek(0) <> #0) and (Peek(0) <> #10) do
        Advance;
      Continue;
    end;
    Break;
  end;

  StartPos := FPos;
  StartLine := FLine;
  StartCol := FCol;
  C := Peek(0);

  if C = #0 then
  begin
    Result.Kind := tkEOF;
    Result.Offset := StartPos;
    Result.Line := StartLine;
    Result.Column := StartCol;
    Exit;
  end;

  if C = #10 then
  begin
    Advance;
    Result.Kind := tkNewline;
    Result.Offset := StartPos;
    Result.Line := StartLine;
    Result.Column := StartCol;
    CollectHereDocs(Result);
    Exit;
  end;

  if ((C = '<') or (C = '>')) and (Peek(1) = '(') then
  begin
    Fail('process substitution is not supported', StartPos, StartLine, StartCol);
    Result.Kind := tkEOF;
    Exit;
  end;

  if TryOp(Op, FD) then
  begin
    Result.Kind := tkOp;
    Result.Op := Op;
    Result.FD := FD;
    Result.Offset := StartPos;
    Result.Line := StartLine;
    Result.Column := StartCol;
    if (Op = opDLess) or (Op = opDLessDash) then
    begin
      FHereNext := True;
      FHereStripNext := Op = opDLessDash;
    end
    else
      FHereNext := False;
    Exit;
  end;

  Result.Text := ScanWordRaw;
  if FHasError then
  begin
    Result.Kind := tkEOF;
    Exit;
  end;
  if Result.Text = '' then
  begin
    { Defensive: an unmatchable character is a lexical error, not a loop. }
    Fail('unexpected character', StartPos, StartLine, StartCol);
    Result.Kind := tkEOF;
    Exit;
  end;
  Result.Kind := tkWord;
  Result.Offset := StartPos;
  Result.Line := StartLine;
  Result.Column := StartCol;
  if FHereNext then
  begin
    RegisterDelimiter(Result.Text);
    FHereNext := False;
  end;
end;

end.
