unit test_utf8;
{ fpcunit tests for hildi.utf8: byte caps that never split a UTF-8
  sequence, so a truncated stream ends on a character instead of a replacement
  character. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, hildi.utf8;

type
  TUtf8Test = class(TTestCase)
  published
    procedure TestPrefixKeepsWholeText;
    procedure TestPrefixCutsAscii;
    procedure TestPrefixDoesNotSplitTwoByte;
    procedure TestPrefixDoesNotSplitFourByte;
    procedure TestPrefixEmptyAndZero;
    procedure TestFromSkipsToABoundary;
    { The streaming fix: a raw byte window can split a multi-byte character, and
      forwarding the fragment renders it as U+FFFD. This is the pure function the
      output collector now uses. }
    procedure TestSplitAtBoundaryHoldsAnIncompleteTail;
    procedure TestSplitAtBoundaryPassesCleanTextThrough;
    procedure TestSplitAtBoundaryCarriesAPureFragment;
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

procedure TUtf8Test.TestSplitAtBoundaryHoldsAnIncompleteTail;
var
  Whole, Complete, Carry, Combined: string;
begin
  { A 3-byte character (U+2500 BOX DRAWINGS LIGHT HORIZONTAL, the kind a build
    tool streams) split after its second byte. The safe prefix ends before it, and
    the two bytes are carried. }
  Whole := 'ab' + #$E2#$94#$80 + 'cd';
  Utf8SplitAtBoundary(Copy(Whole, 1, 4), Complete, Carry);
  AssertEquals('safe prefix', 'ab', Complete);
  AssertEquals('carried tail', #$E2#$94, Carry);
  { Prepending the carry to the rest reconstructs the character exactly once.
    Through a temp: Carry is an `out` parameter, and passing it as both an input
    and the out target clears it before the argument is read. }
  Combined := Carry + Copy(Whole, 5, MaxInt);
  Utf8SplitAtBoundary(Combined, Complete, Carry);
  AssertEquals('completed', #$E2#$94#$80 + 'cd', Complete);
  AssertEquals('nothing left over', '', Carry);
end;

procedure TUtf8Test.TestSplitAtBoundaryPassesCleanTextThrough;
var
  Complete, Carry: string;
begin
  { Text ending on a whole character is forwarded in full, nothing carried. }
  Utf8SplitAtBoundary('a' + #$E2#$94#$80, Complete, Carry);
  AssertEquals('all forwarded', 'a' + #$E2#$94#$80, Complete);
  AssertEquals('nothing carried', '', Carry);
  Utf8SplitAtBoundary('', Complete, Carry);
  AssertEquals('empty', '', Complete);
  AssertEquals('empty carry', '', Carry);
end;

procedure TUtf8Test.TestSplitAtBoundaryCarriesAPureFragment;
var
  Complete, Carry: string;
begin
  { A window that happens to be nothing but continuation bytes is all fragment.
    Forwarding it would emit a replacement character before the real one. }
  Utf8SplitAtBoundary(#$94#$80, Complete, Carry);
  AssertEquals('nothing safe', '', Complete);
  AssertEquals('all carried', #$94#$80, Carry);
end;

initialization
  RegisterTest(TUtf8Test);
end.
