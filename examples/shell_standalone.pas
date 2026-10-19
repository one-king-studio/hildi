program shell_standalone;
{ The isolation smoke for the shell library. It uses ONLY src/shell: the build
  puts no harness unit on the search path, so a dependency on one fails here.

  It parses a handful of scripts (including the constructs the approval gate
  used to get wrong) and prints the outcome. }

{$mode delphi}{$H+}

uses
  SysUtils, shell.types, shell.ast, shell.parser;

procedure TryScript(const AScript: string);
var
  S: TScript;
  E: TShellParseError;
begin
  if ParseShellScript(AScript, S, E) then
  begin
    WriteLn('ok   ', StringReplace(AScript, #10, ' ', [rfReplaceAll]));
    S.Free;
  end
  else
    WriteLn('err  ', StringReplace(AScript, #10, ' ', [rfReplaceAll]),
      '  -> ', E.Message, ' (', E.Line, ':', E.Column, ')');
end;

begin
  TryScript('echo hello');
  TryScript('for f in *.pas; do grep -n TODO "$f"; done');
  TryScript('if test -f x; then rm x; fi');
  TryScript('cat <<EOF' + #10 + 'hi' + #10 + 'EOF');
  TryScript('echo "a b" | wc -l');
  TryScript('a && b || c; d &');
  TryScript('case $x in a) ls;; esac');
  TryScript('f() { echo hi; }');
  { The v1 subset gate: these name their unsupported construct. }
  TryScript('echo $(date)');
  TryScript('echo ${x:-y}');
  TryScript('echo {a,b}');
end.
