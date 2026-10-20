unit shell.parser;
{ Recursive-descent shell parser: source -> shell.ast.TScript.

  v1 subset: simple commands (assignments, words, redirects), pipelines, and-or
  lists, statement lists, compound commands (if/for/while/until/case/groups/
  subshells), function definitions, and here-docs. Anything outside the subset
  is a precise error naming the construct. No regex, no backtracking. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, shell.types, shell.ast, shell.lexer, shell.words;

type
  TShellParser = class
  private
    FLexer: TLexer;
    FScript: TScript;
    FCur: TToken;
    FNext: TToken;
    FPendingHere: array of TRedirect;
    FError: TShellParseError;
    FHasError: Boolean;
    { The source end of the most recently consumed token. }
    FLastEnd: Integer;
    procedure Advance;
    procedure Fail(const AMsg: string; const ATok: TToken);
    procedure FailWord(const AMsg: string);
    function CurOp(AOp: TOpKind): Boolean;
    function CurIsWord(const AText: string): Boolean;
    function IsListStop(const AStops: TStringArray): Boolean;
    function IsTerminator: Boolean;
    function ParseWordFrom(const ATok: TToken; out AWord: TWord): Boolean;
    function ExpectWord(const AText: string): Boolean;
    function ExpectOp(AOp: TOpKind): Boolean;
    procedure SkipSeparators;
    function ParseStatementList(const AStops: TStringArray): TStatement;
    function ParseAndOr: TAndOr;
    function ParsePipeline: TPipeline;
    function ParseCommand: TCommand;
    function ParseSimple: TCommand;
    function ParseRedirect(out ARedirect: TRedirect): Boolean;
    function ParseIf: TCommand;
    function ParseFor: TCommand;
    function ParseWhile(AUntil: Boolean): TCommand;
    function ParseCase: TCommand;
    function ParseGroup(ASubshell: Boolean): TCommand;
    function ParseFunction(const AName: string): TCommand;
    procedure ConsumeHereDocs(const ATok: TToken);
    procedure AddPendingHere(ARedirect: TRedirect);
  public
    constructor Create(const ASource: string);
    destructor Destroy; override;
    { Parse. On success AScript is owned by the caller; on failure it is nil and
      AError carries the first error. }
    function Parse(out AScript: TScript; out AError: TShellParseError): Boolean;
  end;

function ParseShellScript(const ASource: string; out AScript: TScript;
  out AError: TShellParseError): Boolean;

implementation

function WordHasQuotedParts(const AWord: TWord): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(AWord.Parts) do
    if AWord.Parts[I].Quoted then
      Exit(True);
end;

function IsAssignmentWord(const ARaw: string; out AName, ARawValue: string): Boolean;
begin
  Result := SplitAssignment(ARaw, AName, ARawValue);
end;

constructor TShellParser.Create(const ASource: string);
begin
  inherited Create;
  FLexer := TLexer.Create(ASource);
  FScript := TScript.Create;
  FCur := FLexer.Next;
  FNext := FLexer.Next;
  if FLexer.HasError then
  begin
    FHasError := True;
    FError := FLexer.Error;
  end;
end;

destructor TShellParser.Destroy;
begin
  FLexer.Free;
  FScript.Free;
  inherited Destroy;
end;

procedure TShellParser.Advance;
begin
  if (FCur.Offset > 0) and (FCur.EndOffset >= FCur.Offset) then
    FLastEnd := FCur.EndOffset;
  FCur := FNext;
  FNext := FLexer.Next;
  ConsumeHereDocs(FCur);
  if FLexer.HasError and (not FHasError) then
  begin
    FHasError := True;
    FError := FLexer.Error;
  end;
end;

procedure TShellParser.ConsumeHereDocs(const ATok: TToken);
var
  I: Integer;
begin
  if (ATok.Kind <> tkNewline) or (Length(ATok.HereDocs) = 0) then
    Exit;
  for I := 0 to High(ATok.HereDocs) do
    if I <= High(FPendingHere) then
      FPendingHere[I].Body := ATok.HereDocs[I];
  FPendingHere := nil;
end;

procedure TShellParser.AddPendingHere(ARedirect: TRedirect);
var
  N: Integer;
begin
  N := Length(FPendingHere);
  SetLength(FPendingHere, N + 1);
  FPendingHere[N] := ARedirect;
end;

procedure TShellParser.Fail(const AMsg: string; const ATok: TToken);
begin
  if FHasError then
    Exit;
  FHasError := True;
  FError := Default(TShellParseError);
  FError.Offset := ATok.Offset;
  FError.Line := ATok.Line;
  FError.Column := ATok.Column;
  FError.Message := AMsg;
end;

procedure TShellParser.FailWord(const AMsg: string);
begin
  Fail(AMsg, FCur);
end;

function TShellParser.CurOp(AOp: TOpKind): Boolean;
begin
  Result := (FCur.Kind = tkOp) and (FCur.Op = AOp);
end;

function TShellParser.CurIsWord(const AText: string): Boolean;
begin
  Result := (FCur.Kind = tkWord) and (FCur.Text = AText);
end;

function TShellParser.IsTerminator: Boolean;
begin
  Result := False;
  if FCur.Kind <> tkWord then
    Exit;
  Result := (FCur.Text = 'then') or (FCur.Text = 'elif') or (FCur.Text = 'else') or
    (FCur.Text = 'fi') or (FCur.Text = 'do') or (FCur.Text = 'done') or
    (FCur.Text = 'esac') or (FCur.Text = '}');
end;

function TShellParser.IsListStop(const AStops: TStringArray): Boolean;
var
  I: Integer;
begin
  Result := True;
  if FCur.Kind = tkEOF then
    Exit;
  if FCur.Kind = tkOp then
  begin
    Result := FCur.Op in [opRParen, opDSemi, opSemiAnd, opDSemiAnd];
    Exit;
  end;
  if FCur.Kind = tkWord then
    for I := 0 to High(AStops) do
      if FCur.Text = AStops[I] then
        Exit;
  Result := False;
end;

function TShellParser.ParseWordFrom(const ATok: TToken; out AWord: TWord): Boolean;
var
  Parts: TWordPartArray;
  Err: TShellParseError;
begin
  Result := False;
  AWord := nil;
  if not ParseWordParts(ATok.Text, ATok.Offset, ATok.Line, ATok.Column, Parts, Err) then
  begin
    if not FHasError then
    begin
      FHasError := True;
      FError := Err;
    end;
    Exit;
  end;
  AWord := FScript.NewWord;
  AWord.Parts := Parts;
  Result := True;
end;

function TShellParser.ExpectWord(const AText: string): Boolean;
begin
  Result := False;
  if CurIsWord(AText) then
  begin
    Advance;
    Result := True;
  end
  else
    FailWord('expected ' + AText);
end;

function TShellParser.ExpectOp(AOp: TOpKind): Boolean;
begin
  Result := False;
  if CurOp(AOp) then
  begin
    Advance;
    Result := True;
  end
  else
    FailWord('unexpected token');
end;

procedure TShellParser.SkipSeparators;
begin
  while (FCur.Kind = tkNewline) or CurOp(opSemi) do
    Advance;
end;

function TShellParser.ParseStatementList(const AStops: TStringArray): TStatement;
var
  AO: TAndOr;
  Op: TStatementOp;
  N: Integer;

  procedure Append(AItem: TAndOr; AOp: TStatementOp);
  var
    K: Integer;
  begin
    K := Length(Result.Items);
    SetLength(Result.Items, K + 1);
    SetLength(Result.Ops, K + 1);
    Result.Items[K] := AItem;
    Result.Ops[K] := AOp;
  end;

begin
  Result := FScript.NewStatement;
  SkipSeparators;
  while (not FHasError) and (not IsListStop(AStops)) do
  begin
    AO := ParseAndOr;
    if FHasError then
      Exit;
    Op := soSeq;
    if FCur.Kind = tkNewline then
      Advance
    else if CurOp(opSemi) then
      Advance
    else if CurOp(opAmp) then
    begin
      Op := soBackground;
      Advance;
    end;
    Append(AO, Op);
    SkipSeparators;
  end;
end;

function TShellParser.ParseAndOr: TAndOr;
var
  P: TPipeline;
  Op: TAndOrOp;
  N: Integer;
begin
  Result := FScript.NewAndOr;
  P := ParsePipeline;
  N := Length(Result.Pipelines);
  SetLength(Result.Pipelines, N + 1);
  Result.Pipelines[N] := P;
  while (not FHasError) and (CurOp(opAnd) or CurOp(opOr)) do
  begin
    if CurOp(opAnd) then
      Op := aoAnd
    else
      Op := aoOr;
    Advance;
    while FCur.Kind = tkNewline do
      Advance;
    P := ParsePipeline;
    if FHasError then
      Exit;
    N := Length(Result.Pipelines);
    SetLength(Result.Pipelines, N + 1);
    SetLength(Result.Ops, N);
    Result.Ops[N - 1] := Op;
    Result.Pipelines[N] := P;
  end;
end;

function TShellParser.ParsePipeline: TPipeline;
var
  C: TCommand;
  N: Integer;
begin
  Result := FScript.NewPipeline;
  if CurIsWord('!') then
  begin
    Result.Negated := True;
    Advance;
  end;
  C := ParseCommand;
  if FHasError then
    Exit;
  N := Length(Result.Commands);
  SetLength(Result.Commands, N + 1);
  Result.Commands[N] := C;
  while (not FHasError) and (CurOp(opPipe) or CurOp(opPipeErr)) do
  begin
    Advance;
    while FCur.Kind = tkNewline do
      Advance;
    C := ParseCommand;
    if FHasError then
      Exit;
    N := Length(Result.Commands);
    SetLength(Result.Commands, N + 1);
    Result.Commands[N] := C;
  end;
end;

function TShellParser.ParseCommand: TCommand;
var
  Name: string;
begin
  Result := nil;
  if FCur.Kind = tkWord then
  begin
    if FCur.Text = 'if' then
      Exit(ParseIf);
    if FCur.Text = 'for' then
      Exit(ParseFor);
    if FCur.Text = 'while' then
      Exit(ParseWhile(False));
    if FCur.Text = 'until' then
      Exit(ParseWhile(True));
    if FCur.Text = 'case' then
      Exit(ParseCase);
    if FCur.Text = 'function' then
    begin
      Advance;
      if FCur.Kind <> tkWord then
      begin
        FailWord('expected a function name');
        Exit;
      end;
      Name := FCur.Text;
      Advance;
      if CurOp(opLParen) then
      begin
        Advance;
        if not ExpectOp(opRParen) then
          Exit;
      end;
      Exit(ParseFunction(Name));
    end;
    if FCur.Text = '{' then
      Exit(ParseGroup(False));
    if IsTerminator then
    begin
      FailWord('unexpected ' + FCur.Text);
      Exit;
    end;
    { A function definition: name() followed by its body. }
    if (FNext.Kind = tkOp) and (FNext.Op = opLParen) then
    begin
      Name := FCur.Text;
      Advance;   { '(' }
      Advance;   { ')' }
      if not CurOp(opRParen) then
      begin
        FailWord('expected )');
        Exit;
      end;
      Advance;
      Exit(ParseFunction(Name));
    end;
  end
  else if CurOp(opLParen) then
    Exit(ParseGroup(True));
  Result := ParseSimple;
end;

function TShellParser.ParseSimple: TCommand;
var
  W: TWord;
  A: TAssignment;
  R: TRedirect;
  Name, RawValue: string;
  InAssignment: Boolean;
  N: Integer;
  StartOff: Integer;

  procedure AppendWord(AW: TWord);
  var
    K: Integer;
  begin
    K := Length(Result.Words);
    SetLength(Result.Words, K + 1);
    Result.Words[K] := AW;
  end;

  procedure AppendAssignment(AA: TAssignment);
  var
    K: Integer;
  begin
    K := Length(Result.Assignments);
    SetLength(Result.Assignments, K + 1);
    Result.Assignments[K] := AA;
  end;

  procedure AppendRedirect(AR: TRedirect);
  var
    K: Integer;
  begin
    K := Length(Result.Redirects);
    SetLength(Result.Redirects, K + 1);
    Result.Redirects[K] := AR;
  end;

begin
  Result := FScript.NewCommand(ckSimple);
  StartOff := FCur.Offset;
  InAssignment := True;
  while not FHasError do
  begin
    if FCur.Kind = tkWord then
    begin
      if InAssignment and IsAssignmentWord(FCur.Text, Name, RawValue) then
      begin
        A := FScript.NewAssignment;
        A.Name := Name;
        A.Value := FScript.NewWord;
        if not ParseWordParts(RawValue, FCur.Offset + Length(Name) + 1,
          FCur.Line, FCur.Column, A.Value.Parts, FError) then
        begin
          FHasError := True;
          Exit;
        end;
        AppendAssignment(A);
        Advance;
        Continue;
      end;
      InAssignment := False;
      if not ParseWordFrom(FCur, W) then
        Exit;
      AppendWord(W);
      Advance;
      Continue;
    end;
    if FCur.Kind = tkOp then
    begin
      if FCur.Op in [opLess, opGreat, opDGreat, opDLess, opDLessDash, opTLess,
        opLessAnd, opGreatAnd, opLessGreat, opGreatPipe, opAndGreat, opAndDGreat] then
      begin
        if not ParseRedirect(R) then
          Exit;
        AppendRedirect(R);
        Continue;
      end;
    end;
    Break;
  end;
  if FHasError then
    Exit;
  N := Length(Result.Words) + Length(Result.Assignments) + Length(Result.Redirects);
  if N = 0 then
    FailWord('expected a command');
  Result.Start := StartOff;
  if FLastEnd >= StartOff then
    Result.Len := FLastEnd - StartOff + 1
  else
    Result.Len := 0;
end;

function TShellParser.ParseRedirect(out ARedirect: TRedirect): Boolean;
var
  Op: TOpKind;
begin
  Result := False;
  Op := FCur.Op;
  ARedirect := FScript.NewRedirect;
  ARedirect.FD := FCur.FD;
  Advance;
  if FCur.Kind <> tkWord then
  begin
    FailWord('expected a redirect target');
    Exit;
  end;
  if not ParseWordFrom(FCur, ARedirect.Target) then
    Exit;
  if Op = opDLessDash then
  begin
    ARedirect.Op := roHeredocStrip;
    AddPendingHere(ARedirect);
    ARedirect.ExpandBody := not WordHasQuotedParts(ARedirect.Target);
  end
  else if Op = opDLess then
  begin
    ARedirect.Op := roHeredoc;
    AddPendingHere(ARedirect);
    ARedirect.ExpandBody := not WordHasQuotedParts(ARedirect.Target);
  end
  else if Op = opTLess then
    ARedirect.Op := roHereString
  else if Op = opLess then
    ARedirect.Op := roRead
  else if Op = opGreat then
    ARedirect.Op := roWrite
  else if Op = opDGreat then
    ARedirect.Op := roAppend
  else if Op = opLessGreat then
    ARedirect.Op := roReadWrite
  else if Op = opLessAnd then
    ARedirect.Op := roDupIn
  else if Op = opGreatAnd then
    ARedirect.Op := roDupOut
  else if Op = opGreatPipe then
    ARedirect.Op := roWrite
  else if Op = opAndGreat then
  begin
    { &> file: both streams to one file. FD 1 + a marker for 2. }
    ARedirect.Op := roWrite;
    ARedirect.FD := 1;
  end
  else if Op = opAndDGreat then
  begin
    ARedirect.Op := roAppend;
    ARedirect.FD := 1;
  end
  else
  begin
    Fail('unsupported redirect', FCur);
    Exit;
  end;
  Advance;
  Result := True;
end;

function TShellParser.ParseIf: TCommand;
var
  Clause: TIfClause;

  procedure AppendClause(const AC: TIfClause);
  var
    K: Integer;
  begin
    K := Length(Result.Clauses);
    SetLength(Result.Clauses, K + 1);
    Result.Clauses[K] := AC;
  end;

begin
  Result := FScript.NewCommand(ckIf);
  Advance;   { past 'if' }
  Clause := Default(TIfClause);
  Clause.Condition := ParseStatementList(['then']);
  if FHasError then
    Exit;
  if not ExpectWord('then') then
    Exit;
  Clause.Body := ParseStatementList(['elif', 'else', 'fi']);
  if FHasError then
    Exit;
  AppendClause(Clause);
  while (not FHasError) and CurIsWord('elif') do
  begin
    Advance;
    Clause := Default(TIfClause);
    Clause.Condition := ParseStatementList(['then']);
    if FHasError then
      Exit;
    if not ExpectWord('then') then
      Exit;
    Clause.Body := ParseStatementList(['elif', 'else', 'fi']);
    if FHasError then
      Exit;
    AppendClause(Clause);
  end;
  if FHasError then
    Exit;
  if CurIsWord('else') then
  begin
    Advance;
    Result.ElseBody := ParseStatementList(['fi']);
    if FHasError then
      Exit;
  end;
  ExpectWord('fi');
end;

function TShellParser.ParseFor: TCommand;
var
  W: TWord;
  N: Integer;
begin
  Result := FScript.NewCommand(ckFor);
  Advance;   { past 'for' }
  if CurOp(opLParen) then
  begin
    FailWord('arithmetic for is not supported');
    Exit;
  end;
  if FCur.Kind <> tkWord then
  begin
    FailWord('expected a loop variable');
    Exit;
  end;
  Result.ForVar := FCur.Text;
  Advance;
  if CurIsWord('in') then
  begin
    Advance;
    while (not FHasError) and (FCur.Kind = tkWord) do
    begin
      if not ParseWordFrom(FCur, W) then
        Exit;
      N := Length(Result.ForItems);
      SetLength(Result.ForItems, N + 1);
      Result.ForItems[N] := W;
      Advance;
    end;
  end;
  SkipSeparators;
  if not ExpectWord('do') then
    Exit;
  Result.LoopBody := ParseStatementList(['done']);
  if FHasError then
    Exit;
  ExpectWord('done');
end;

function TShellParser.ParseWhile(AUntil: Boolean): TCommand;
begin
  if AUntil then
    Result := FScript.NewCommand(ckUntil)
  else
    Result := FScript.NewCommand(ckWhile);
  Advance;   { past 'while'/'until' }
  Result.Condition := ParseStatementList(['do']);
  if FHasError then
    Exit;
  if not ExpectWord('do') then
    Exit;
  Result.LoopBody := ParseStatementList(['done']);
  if FHasError then
    Exit;
  ExpectWord('done');
end;

function TShellParser.ParseCase: TCommand;
var
  Item: TCaseItem;
  W: TWord;
  N: Integer;

  procedure AppendItem(const AI: TCaseItem);
  var
    K: Integer;
  begin
    K := Length(Result.CaseItems);
    SetLength(Result.CaseItems, K + 1);
    Result.CaseItems[K] := AI;
  end;

  function AppendPattern(AW: TWord): Integer;
  var
    K: Integer;
  begin
    K := Length(Item.Patterns);
    SetLength(Item.Patterns, K + 1);
    Item.Patterns[K] := AW;
    Result := K;
  end;

begin
  Result := FScript.NewCommand(ckCase);
  Advance;   { past 'case' }
  if FCur.Kind <> tkWord then
  begin
    FailWord('expected a case word');
    Exit;
  end;
  if not ParseWordFrom(FCur, Result.CaseWord) then
    Exit;
  Advance;
  SkipSeparators;
  if not ExpectWord('in') then
    Exit;
  while (not FHasError) and (not CurIsWord('esac')) do
  begin
    SkipSeparators;
    if CurIsWord('esac') then
      Break;
    Item := Default(TCaseItem);
    { Patterns separated by '|', terminated by ')'. }
    while (not FHasError) and (FCur.Kind = tkWord) and
      (not CurIsWord('esac')) do
    begin
      if not ParseWordFrom(FCur, W) then
        Exit;
      AppendPattern(W);
      Advance;
      if CurOp(opPipe) then
        Advance;
    end;
    if FHasError then
      Exit;
    if not ExpectOp(opRParen) then
      Exit;
    Item.Body := ParseStatementList(['esac']);
    if FHasError then
      Exit;
    AppendItem(Item);
    if CurOp(opDSemi) or CurOp(opSemiAnd) or CurOp(opDSemiAnd) then
      Advance
    else if not CurIsWord('esac') then
    begin
      FailWord('expected ;; or esac');
      Exit;
    end;
  end;
  ExpectWord('esac');
end;

function TShellParser.ParseGroup(ASubshell: Boolean): TCommand;
begin
  if ASubshell then
  begin
    Result := FScript.NewCommand(ckSubshell);
    Advance;   { '(' }
    Result.Group := ParseStatementList(nil);
    if FHasError then
      Exit;
    if not ExpectOp(opRParen) then
      Exit;
  end
  else
  begin
    Result := FScript.NewCommand(ckGroup);
    Advance;   { the opening brace }
    Result.Group := ParseStatementList(['}']);
    if FHasError then
      Exit;
    if not ExpectWord('}') then
      Exit;
  end;
end;

function TShellParser.ParseFunction(const AName: string): TCommand;
begin
  Result := FScript.NewCommand(ckFunction);
  Result.FuncName := AName;
  while FCur.Kind = tkNewline do
    Advance;
  if FHasError then
    Exit;
  Result.FuncBody := ParseCommand;
end;

function TShellParser.Parse(out AScript: TScript; out AError: TShellParseError): Boolean;
var
  Root: TStatement;
begin
  AScript := nil;
  AError := Default(TShellParseError);
  Root := ParseStatementList(nil);
  if FHasError then
  begin
    AError := FError;
    Result := False;
    Exit;
  end;
  if FCur.Kind <> tkEOF then
  begin
    FailWord('unexpected token');
    AError := FError;
    Result := False;
    Exit;
  end;
  FScript.Root := Root;
  AScript := FScript;
  FScript := nil;
  Result := True;
end;

function ParseShellScript(const ASource: string; out AScript: TScript;
  out AError: TShellParseError): Boolean;
var
  P: TShellParser;
begin
  P := TShellParser.Create(ASource);
  try
    Result := P.Parse(AScript, AError);
  finally
    P.Free;
  end;
end;

end.
