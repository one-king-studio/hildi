unit test_htmlentities;
{ HTML entity decoding for tool arguments: the model writes &lt;/&gt;/&amp;
  assuming markdown, and the shell must see the characters. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, hildi.htmlentities;

type
  THtmlEntitiesTest = class(TTestCase)
  published
    procedure TestNamedEntities;
    procedure TestNumericEntities;
    procedure TestSinglePass;
    procedure TestEscapedEntityIsKept;
    procedure TestUnknownAndUnterminated;
    procedure TestPlainText;
  end;

implementation

procedure THtmlEntitiesTest.TestNamedEntities;
begin
  AssertEquals('lt', 'a < b', DecodeHtmlEntities('a &lt; b'));
  AssertEquals('gt', 'a > b', DecodeHtmlEntities('a &gt; b'));
  AssertEquals('amp', 'a & b', DecodeHtmlEntities('a &amp; b'));
  AssertEquals('and-and', 'a && b', DecodeHtmlEntities('a &amp;&amp; b'));
  AssertEquals('quot', '"hi"', DecodeHtmlEntities('&quot;hi&quot;'));
  AssertEquals('apos', '''hi''', DecodeHtmlEntities('&apos;hi&apos;'));
  AssertEquals('nbsp', 'a' + #$C2 + #$A0 + 'b',
    DecodeHtmlEntities('a&nbsp;b'));
end;

procedure THtmlEntitiesTest.TestNumericEntities;
begin
  AssertEquals('decimal', 'A', DecodeHtmlEntities('&#65;'));
  AssertEquals('hex', 'A', DecodeHtmlEntities('&#x41;'));
  AssertEquals('hex upper', 'A', DecodeHtmlEntities('&#X41;'));
  AssertEquals('apostrophe', '''', DecodeHtmlEntities('&#39;'));
  AssertEquals('two-byte', #$C2 + #$A0, DecodeHtmlEntities('&#160;'));
end;

procedure THtmlEntitiesTest.TestSinglePass;
begin
  AssertEquals('decoded once', '&lt;', DecodeHtmlEntities('&amp;lt;'));
end;

procedure THtmlEntitiesTest.TestEscapedEntityIsKept;
begin
  AssertEquals('backslash defuses it', '\&lt;',
    DecodeHtmlEntities('\&lt;'));
end;

procedure THtmlEntitiesTest.TestUnknownAndUnterminated;
begin
  AssertEquals('unknown named', '&foo;', DecodeHtmlEntities('&foo;'));
  AssertEquals('unterminated', '&lt', DecodeHtmlEntities('&lt'));
  AssertEquals('bare amp', 'a & b', DecodeHtmlEntities('a & b'));
  AssertEquals('bad numeric', '&#xZZ;', DecodeHtmlEntities('&#xZZ;'));
end;

procedure THtmlEntitiesTest.TestPlainText;
begin
  AssertEquals('nothing to do', 'echo a < b && cat f',
    DecodeHtmlEntities('echo a < b && cat f'));
end;

initialization
  RegisterTest(THtmlEntitiesTest);
end.
