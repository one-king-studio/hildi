program shell_ast_dump;
{ A developer demo: parse shell input with the Shell Library and print the AST
  it produced - statements, and-or lists, pipelines, commands, words (with
  their literal/quoted/variable/glob parts), redirects and here-docs.

  Uses ONLY src/shell plus the RTL (the same isolation rule as
  shell_standalone). Run `make shell-ast`, or pass a script:
    build/bin/shell-ast-dump 'for f in *.pas; do echo $f; done' }

{$mode delphi}{$H+}

uses
  SysUtils, Classes, StrUtils,
  ShellTypes, ShellAST, ShellParser;

var
  Rendered: TStringList;

function Vis(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
  Result := StringReplace(Result, #9, '\t', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
end;

function Ind(AIndent: Integer): string;
begin
  Result := StringOfChar(' ', AIndent);
end;

procedure DumpWord(const ALabel: string; const AW: TWord; AIndent: Integer);
var
  I: Integer;
  P: TWordPart;
  Kind, Quoted: string;
begin
  Rendered.Add(Ind(AIndent) + ALabel + ' (' + IntToStr(Length(AW.Parts)) +
    ' part' + IfThen(Length(AW.Parts) = 1, '', 's') + ')');
  for I := 0 to High(AW.Parts) do
  begin
    P := AW.Parts[I];
    case P.Kind of
      wpLiteral: Kind := 'literal';
      wpVariable: Kind := 'variable';
      wpSpecial: Kind := 'special';
      wpTilde: Kind := 'tilde';
      wpGlob: Kind := 'glob';
    end;
    if P.Quoted then
      Quoted := ' quoted'
    else
      Quoted := '';
    if P.Kind = wpVariable then
      Rendered.Add(Ind(AIndent + 2) + Kind + Quoted + '  $' + P.Text)
    else if P.Kind = wpSpecial then
      Rendered.Add(Ind(AIndent + 2) + Kind + Quoted + '  $' + P.Text)
    else
      Rendered.Add(Ind(AIndent + 2) + Kind + Quoted + '  "' + Vis(P.Text) + '"');
  end;
end;

procedure DumpStatement(const ASt: TStatement; AIndent: Integer); forward;
procedure DumpCommand(const AC: TCommand; AIndent: Integer); forward;

procedure DumpRedirect(const AR: TRedirect; AIndent: Integer);
var
  OpName, FD: string;
begin
  case AR.Op of
    roRead: OpName := '<';
    roWrite: OpName := '>';
    roAppend: OpName := '>>';
    roReadWrite: OpName := '<>';
    roDupIn: OpName := '<&';
    roDupOut: OpName := '>&';
    roHeredoc: OpName := '<<';
    roHeredocStrip: OpName := '<<-';
    roHereString: OpName := '<<<';
  end;
  if AR.FD >= 0 then
    FD := IntToStr(AR.FD)
  else
    FD := 'default';
  Rendered.Add(Ind(AIndent) + 'REDIRECT fd=' + FD + ' op=' + OpName);
  if AR.Target <> nil then
    DumpWord('  target', AR.Target, AIndent + 2);
  if AR.Op in [roHeredoc, roHeredocStrip] then
  begin
    Rendered.Add(Ind(AIndent + 2) + 'body (expand=' +
      IfThen(AR.ExpandBody, 'yes', 'no') + '): "' + Vis(AR.Body) + '"');
  end;
end;

procedure DumpPipeline(const AP: TPipeline; AIndent: Integer);
var
  I: Integer;
begin
  if AP.Negated then
    Rendered.Add(Ind(AIndent) + 'PIPELINE (negated with !)')
  else
    Rendered.Add(Ind(AIndent) + 'PIPELINE');
  for I := 0 to High(AP.Commands) do
  begin
    Rendered.Add(Ind(AIndent + 2) + 'STAGE ' + IntToStr(I + 1));
    DumpCommand(AP.Commands[I], AIndent + 4);
  end;
end;

procedure DumpAndOr(const AA: TAndOr; AIndent: Integer);
var
  I: Integer;
  OpName: string;
begin
  Rendered.Add(Ind(AIndent) + 'AND-OR (left-associative)');
  for I := 0 to High(AA.Pipelines) do
  begin
    if I > 0 then
    begin
      if AA.Ops[I - 1] = aoAnd then
        OpName := '&&'
      else
        OpName := '||';
      Rendered.Add(Ind(AIndent + 2) + 'then ' + OpName);
    end;
    DumpPipeline(AA.Pipelines[I], AIndent + 2);
  end;
end;

procedure DumpStatement(const ASt: TStatement; AIndent: Integer);
var
  I: Integer;
  Sep: string;
begin
  Rendered.Add(Ind(AIndent) + 'STATEMENT (' + IntToStr(Length(ASt.Items)) +
    ' item' + IfThen(Length(ASt.Items) = 1, '', 's') + ')');
  for I := 0 to High(ASt.Items) do
  begin
    if ASt.Ops[I] = soBackground then
      Sep := '& (background)'
    else
      Sep := ';';
    Rendered.Add(Ind(AIndent + 2) + 'ITEM ' + IntToStr(I + 1) + ' sep=' + Sep);
    DumpAndOr(ASt.Items[I], AIndent + 4);
  end;
end;

procedure DumpCommand(const AC: TCommand; AIndent: Integer);
var
  I, J: Integer;
begin
  case AC.Kind of
    ckSimple:
      begin
        Rendered.Add(Ind(AIndent) + 'SIMPLE');
        for I := 0 to High(AC.Assignments) do
        begin
          Rendered.Add(Ind(AIndent + 2) + 'ASSIGNMENT ' +
            AC.Assignments[I].Name + '=');
          DumpWord('  value', AC.Assignments[I].Value, AIndent + 4);
        end;
        for I := 0 to High(AC.Words) do
          DumpWord('WORD ' + IntToStr(I + 1), AC.Words[I], AIndent + 2);
        for I := 0 to High(AC.Redirects) do
          DumpRedirect(AC.Redirects[I], AIndent + 2);
      end;
    ckGroup:
      begin
        Rendered.Add(Ind(AIndent) + 'GROUP { ...; }');
        DumpStatement(AC.Group, AIndent + 2);
      end;
    ckSubshell:
      begin
        Rendered.Add(Ind(AIndent) + 'SUBSHELL ( ... )');
        DumpStatement(AC.Group, AIndent + 2);
      end;
    ckIf:
      begin
        Rendered.Add(Ind(AIndent) + 'IF (' + IntToStr(Length(AC.Clauses)) +
          ' clause' + IfThen(Length(AC.Clauses) = 1, '', 's') + ')');
        for I := 0 to High(AC.Clauses) do
        begin
          if I = 0 then
            Rendered.Add(Ind(AIndent + 2) + 'CONDITION')
          else
            Rendered.Add(Ind(AIndent + 2) + 'ELIF ' + IntToStr(I) + ' CONDITION');
          DumpStatement(AC.Clauses[I].Condition, AIndent + 4);
          Rendered.Add(Ind(AIndent + 2) + 'THEN');
          DumpStatement(AC.Clauses[I].Body, AIndent + 4);
        end;
        if AC.ElseBody <> nil then
        begin
          Rendered.Add(Ind(AIndent + 2) + 'ELSE');
          DumpStatement(AC.ElseBody, AIndent + 4);
        end;
      end;
    ckFor:
      begin
        Rendered.Add(Ind(AIndent) + 'FOR var=' + AC.ForVar);
        Rendered.Add(Ind(AIndent + 2) + 'ITEMS (' +
          IntToStr(Length(AC.ForItems)) + ')');
        for I := 0 to High(AC.ForItems) do
          DumpWord('  item ' + IntToStr(I + 1), AC.ForItems[I], AIndent + 4);
        Rendered.Add(Ind(AIndent + 2) + 'BODY');
        DumpStatement(AC.LoopBody, AIndent + 4);
      end;
    ckWhile, ckUntil:
      begin
        if AC.Kind = ckWhile then
          Rendered.Add(Ind(AIndent) + 'WHILE')
        else
          Rendered.Add(Ind(AIndent) + 'UNTIL');
        Rendered.Add(Ind(AIndent + 2) + 'CONDITION');
        DumpStatement(AC.Condition, AIndent + 4);
        Rendered.Add(Ind(AIndent + 2) + 'BODY');
        DumpStatement(AC.LoopBody, AIndent + 4);
      end;
    ckCase:
      begin
        Rendered.Add(Ind(AIndent) + 'CASE (' + IntToStr(Length(AC.CaseItems)) +
          ' item' + IfThen(Length(AC.CaseItems) = 1, '', 's') + ')');
        DumpWord('  word', AC.CaseWord, AIndent + 2);
        for I := 0 to High(AC.CaseItems) do
        begin
          Rendered.Add(Ind(AIndent + 2) + 'ITEM ' + IntToStr(I + 1) + ' PATTERNS');
          for J := 0 to High(AC.CaseItems[I].Patterns) do
            DumpWord('  pattern ' + IntToStr(J + 1),
              AC.CaseItems[I].Patterns[J], AIndent + 4);
          Rendered.Add(Ind(AIndent + 2) + 'BODY');
          DumpStatement(AC.CaseItems[I].Body, AIndent + 4);
        end;
      end;
    ckFunction:
      begin
        Rendered.Add(Ind(AIndent) + 'FUNCTION ' + AC.FuncName);
        if AC.FuncBody <> nil then
          DumpCommand(AC.FuncBody, AIndent + 2);
      end;
  end;
end;

procedure Demo(const ASource: string);
var
  S: TScript;
  E: TShellParseError;
begin
  WriteLn('================================================================');
  WriteLn('$ ', Vis(ASource));
  WriteLn('================================================================');
  if not ParseShellScript(ASource, S, E) then
  begin
    WriteLn('PARSE ERROR at line ', E.Line, ', column ', E.Column,
      ' (offset ', E.Offset, '):');
    WriteLn('  ', E.Message);
    WriteLn;
    Exit;
  end;
  try
    Rendered.Clear;
    Rendered.Add('SCRIPT');
    DumpStatement(S.Root, 2);
    WriteLn(Rendered.Text);
  finally
    S.Free;
  end;
end;

var
  I: Integer;
const
  Demos: array[0..10] of string = (
    'echo hello world',
    'X=1 Y="a b" grep -n TODO src/*.pas > out.txt 2>&1',
    'for f in *.pas; do grep -n TODO "$f"; done',
    'if test -f x; then rm -r sub; elif true; then echo yes; else echo no; fi',
    'case "$x" in *.md) echo md;; *) echo other;; esac',
    'cat <<''EOF'' > notes.txt' + #10 + 'hello $USER' + #10 + 'EOF',
    'a && b | c || d; e &',
    'f() { echo hi; }; ( cd sub; pwd )',
    '! grep -q x file',
    'export PATH=$HOME/bin:$PATH; unset X',
    'echo $(date)');
begin
  Rendered := TStringList.Create;
  try
    if ParamCount >= 1 then
      Demo(ParamStr(1))
    else
      for I := 0 to High(Demos) do
        Demo(Demos[I]);
  finally
    Rendered.Free;
  end;
end.
