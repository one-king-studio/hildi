unit test_shell_textlines;
{ The shared line splitter: the CR policy is the platform decision, and the
  explicit form lets both sides be tested here. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, hildegard.helper.shell.textlines;

type
  TShellTextLinesTest = class(TTestCase)
  published
    procedure TestPlainLines;
    procedure TestTrailingNewline;
    procedure TestCrLfExplicit;
    procedure TestPlatformDefault;
    procedure TestEmpty;
  end;

implementation

procedure TShellTextLinesTest.TestPlainLines;
var
  L: TStringArray;
begin
  L := SplitLinesEx('a' + #10 + 'b' + #10, False);
  AssertEquals('two lines', 2, Length(L));
  AssertEquals('first', 'a', L[0]);
  AssertEquals('second', 'b', L[1]);
end;

procedure TShellTextLinesTest.TestTrailingNewline;
var
  L: TStringArray;
begin
  L := SplitLinesEx('a' + #10 + 'b', False);
  AssertEquals('no phantom line', 2, Length(L));
  L := SplitLinesEx('a' + #10 + #10, False);
  AssertEquals('a blank line counts', 2, Length(L));
  AssertEquals('blank is empty', '', L[1]);
end;

procedure TShellTextLinesTest.TestCrLfExplicit;
var
  L: TStringArray;
begin
  L := SplitLinesEx('a' + #13 + #10 + 'b' + #13 + #10, True);
  AssertEquals('stripped', 'a', L[0]);
  AssertEquals('stripped too', 'b', L[1]);
  L := SplitLinesEx('a' + #13 + #10 + 'b' + #13 + #10, False);
  AssertEquals('kept', 'a' + #13, L[0]);
  AssertEquals('kept too', 'b' + #13, L[1]);
end;

procedure TShellTextLinesTest.TestPlatformDefault;
var
  L: TStringArray;
begin
  L := SplitLinesEx('a' + #13 + #10, False);
  AssertEquals('unix keeps CR', 'a' + #13, L[0]);
  {$ifdef windows}
  L := SplitLines('a' + #13 + #10);
  AssertEquals('windows strips CR', 'a', L[0]);
  {$else}
  L := SplitLines('a' + #13 + #10);
  AssertEquals('unix strips nothing', 'a' + #13, L[0]);
  {$endif}
end;

procedure TShellTextLinesTest.TestEmpty;
begin
  AssertEquals('empty input', 0, Length(SplitLinesEx('', False)));
end;

initialization
  RegisterTest(TShellTextLinesTest);
end.
