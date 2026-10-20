unit test_utf8;
{ fpcunit tests for hildegard.helper.utf8: byte caps that never split a UTF-8
  sequence, so a truncated stream ends on a character instead of a replacement
  character. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, hildegard.helper.utf8;

type
  TUtf8Test = class(TTestCase)
  published
    procedure TestPrefixKeepsWholeText;
    procedure TestPrefixCutsAscii;
    procedure TestPrefixDoesNotSplitTwoByte;
    procedure TestPrefixDoesNotSplitFourByte;
    procedure TestPrefixEmptyAndZero;
    procedure TestFromSkipsToABoundary;
  end;

implementation

const
  { 'é' = C3 A9, '🙂' = F0 9F 99 82. }
  EAcute = #$C3#$A9;
  Smile = #$F0#$9F#$99#$82;

procedure TUtf8Test.TestPrefixKeepsWholeText;
begin
  AssertEquals('under the cap', 'abc', Utf8Prefix('abc', 3));
  AssertEquals('over the length', 'abc', Utf8Prefix('abc', 99));
end;

procedure TUtf8Test.TestPrefixCutsAscii;
begin
  AssertEquals('two bytes', 'ab', Utf8Prefix('abc', 2));
end;

procedure TUtf8Test.TestPrefixDoesNotSplitTwoByte;
begin
  { 'éa' is C3 A9 61: a cap of 1 would leave C3 alone. }
  AssertEquals('mid-sequence becomes nothing', '', Utf8Prefix(EAcute + 'a', 1));
  AssertEquals('exactly the character', EAcute, Utf8Prefix(EAcute + 'a', 2));
  AssertEquals('and the rest', EAcute + 'a', Utf8Prefix(EAcute + 'a', 3));
  AssertEquals('two of them', EAcute + EAcute,
    Utf8Prefix(EAcute + EAcute, 4));
  AssertEquals('a partial second', EAcute, Utf8Prefix(EAcute + EAcute, 3));
end;

procedure TUtf8Test.TestPrefixDoesNotSplitFourByte;
begin
  AssertEquals('nothing', '', Utf8Prefix(Smile, 1));
  AssertEquals('three of four bytes is nothing', '', Utf8Prefix(Smile, 3));
  AssertEquals('the whole smile', Smile, Utf8Prefix(Smile, 4));
end;

procedure TUtf8Test.TestPrefixEmptyAndZero;
begin
  AssertEquals('empty', '', Utf8Prefix('', 10));
  AssertEquals('zero cap', '', Utf8Prefix('abc', 0));
  AssertEquals('negative cap', '', Utf8Prefix('abc', -1));
end;

procedure TUtf8Test.TestFromSkipsToABoundary;
begin
  AssertEquals('nothing skipped', 'abc', Utf8From('abc', 0));
  AssertEquals('ascii', 'bc', Utf8From('abc', 1));
  { Skipping one byte into 'é' lands on its continuation; move past it. }
  AssertEquals('past the character', 'a', Utf8From(EAcute + 'a', 1));
  AssertEquals('past the character', 'a', Utf8From(EAcute + 'a', 2));
  AssertEquals('past everything', '', Utf8From('abc', 10));
end;

initialization
  RegisterTest(TUtf8Test);
end.
