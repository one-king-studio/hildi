unit shell.ast;
{ The shell AST. Every node is owned by the TScript arena, so the tree has one
  owner: free the script and the whole tree goes. Nodes never free children. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections;

type
  TWordPartKind = (wpLiteral, wpVariable, wpSpecial, wpTilde, wpGlob);

  TWordPart = record
    Kind: TWordPartKind;
    Text: string;
    Quoted: Boolean;
  end;
  TWordPartArray = array of TWordPart;

  { A word: a sequence of parts. Quoted parts are literal; an unquoted glob part
    makes the word a glob candidate; an unquoted variable is subject to field
    splitting. }
  TWord = class
  public
    Parts: TWordPartArray;
    constructor Create;
    function IsEmpty: Boolean;
  end;

  TRedirectOp = (roRead, roWrite, roAppend, roReadWrite, roDupIn, roDupOut,
    roHeredoc, roHeredocStrip, roHereString);

  TRedirect = class
  public
    FD: Integer;          // -1 = the op's default
    Op: TRedirectOp;
    Target: TWord;
    Body: string;         // here-doc body, raw
    ExpandBody: Boolean;
    constructor Create;
  end;

  TAssignment = class
  public
    Name: string;
    Value: TWord;
    constructor Create;
  end;

  TCommandKind = (ckSimple, ckIf, ckFor, ckWhile, ckUntil, ckCase, ckGroup,
    ckSubshell, ckFunction);

  TStatement = class;
  TCommand = class;
  TPipeline = class;
  TAndOr = class;

  TIfClause = record
    Condition: TStatement;
    Body: TStatement;
  end;
  TIfClauseArray = array of TIfClause;

  TCaseItem = record
    Patterns: array of TWord;
    Body: TStatement;
  end;
  TCaseItemArray = array of TCaseItem;

  TCommand = class
  public
    Kind: TCommandKind;
    { The construct's span in the source, 1-based bytes, Len 0 when unknown.
      A simple command covers its words and redirects (not the operator that
      introduced it); a compound command is not spanned. }
    Start, Len: Integer;
    { simple }
    Assignments: array of TAssignment;
    Words: array of TWord;
    Redirects: array of TRedirect;
    { compound }
    Clauses: TIfClauseArray;       // if/elif
    ElseBody: TStatement;          // if
    LoopBody: TStatement;          // for/while/until
    Condition: TStatement;         // while/until
    ForVar: string;
    ForItems: array of TWord;
    CaseWord: TWord;
    CaseItems: TCaseItemArray;
    Group: TStatement;             // { } / ( )
    FuncName: string;
    FuncBody: TCommand;            // the body command
    constructor Create;
  end;

  TPipeline = class
  public
    Commands: array of TCommand;
    Negated: Boolean;
    constructor Create;
  end;

  TAndOrOp = (aoAnd, aoOr);
  TAndOr = class
  public
    Pipelines: array of TPipeline;
    Ops: array of TAndOrOp;
    constructor Create;
  end;

  TStatementOp = (soSeq, soBackground);
  TStatement = class
  public
    Items: array of TAndOr;
    Ops: array of TStatementOp;
    constructor Create;
  end;

  { The parsed script and the arena that owns every node. }
  TScript = class
  private
    FNodes: TObjectList<TObject>;
  public
    Root: TStatement;
    constructor Create;
    destructor Destroy; override;
    function NewWord: TWord;
    function NewRedirect: TRedirect;
    function NewAssignment: TAssignment;
    function NewCommand(AKind: TCommandKind = ckSimple): TCommand;
    function NewPipeline: TPipeline;
    function NewAndOr: TAndOr;
    function NewStatement: TStatement;
  end;

implementation

constructor TWord.Create;
begin
  inherited Create;
  Parts := nil;
end;

function TWord.IsEmpty: Boolean;
begin
  Result := Length(Parts) = 0;
end;

constructor TRedirect.Create;
begin
  inherited Create;
  FD := -1;
  ExpandBody := True;
end;

constructor TAssignment.Create;
begin
  inherited Create;
end;

constructor TCommand.Create;
begin
  inherited Create;
  Kind := ckSimple;
end;

constructor TPipeline.Create;
begin
  inherited Create;
end;

constructor TAndOr.Create;
begin
  inherited Create;
end;

constructor TStatement.Create;
begin
  inherited Create;
end;

constructor TScript.Create;
begin
  inherited Create;
  FNodes := TObjectList<TObject>.Create(True);
end;

destructor TScript.Destroy;
begin
  { One owner: every node is in the arena, so nodes never free children. }
  FNodes.Free;
  inherited Destroy;
end;

function TScript.NewWord: TWord;
begin
  Result := TWord.Create;
  FNodes.Add(Result);
end;

function TScript.NewRedirect: TRedirect;
begin
  Result := TRedirect.Create;
  FNodes.Add(Result);
end;

function TScript.NewAssignment: TAssignment;
begin
  Result := TAssignment.Create;
  FNodes.Add(Result);
end;

function TScript.NewCommand(AKind: TCommandKind): TCommand;
begin
  Result := TCommand.Create;
  Result.Kind := AKind;
  FNodes.Add(Result);
end;

function TScript.NewPipeline: TPipeline;
begin
  Result := TPipeline.Create;
  FNodes.Add(Result);
end;

function TScript.NewAndOr: TAndOr;
begin
  Result := TAndOr.Create;
  FNodes.Add(Result);
end;

function TScript.NewStatement: TStatement;
begin
  Result := TStatement.Create;
  FNodes.Add(Result);
end;

end.
