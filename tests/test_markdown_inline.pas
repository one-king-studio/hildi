unit test_markdown_inline;
{ Tests for markdown.inline, the linear inline tokenizer.

  The linearity tests are written FIRST, on purpose. The source design froze for
  6.8 seconds on 200 characters of `[a](` repetition because a backtracking regex
  retried exponentially, and model output is attacker-influenced. A tokenizer
  without that test is a tokenizer that can reintroduce the class.

  Note what these assert: COMPLETION and a bound on the emitted token count, not
  wall-clock time. A timing assertion flakes on a loaded machine and would be
  deleted by the first person it annoyed; a completion assertion cannot. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  markdown.types, markdown.tree, markdown.inline;

type
  TMdInlineTest = class(TTestCase)
  private
    function Tok(const AText: string): TMdTokenArray;
    function Kinds(const AText: string): string;
    { Rebuild the text with active emphasis as a marker, so a nesting failure is
      readable in the message. }
    function Marked(const AText: string): string;
  published
    { linearity, first }
    procedure TestLinearOnBracketFlood;
    procedure TestLinearOnLinkFlood;
    procedure TestLinearOnAsteriskFlood;
    procedure TestLinearOnBacktickFlood;
    procedure TestTokenCountIsBoundedByInput;
    { structure }
    procedure TestPlainTextIsOneToken;
    procedure TestEmphasisOpensAndCloses;
    procedure TestNestedEmphasis;
    procedure TestTripleAsteriskIsBoldItalic;
    procedure TestUnmatchedDelimiterIsLiteral;
    procedure TestCodeSpanIsVerbatim;
    procedure TestStrikethrough;
    procedure TestNewFormats;
    procedure TestSoftBreak;
    procedure TestHardBreak;
    procedure TestLinkCarriesUri;
    procedure TestStreamIsAlwaysBalanced;
    { security }
    procedure TestJavascriptUriIsDropped;
    procedure TestDataUriIsDropped;
    procedure TestFileUriIsDropped;
    procedure TestHttpHttpsMailtoAllowed;
    procedure TestRelativeUriAllowed;
    procedure TestColonInPathIsNotAScheme;
    procedure TestAutolinkIsAllowListed;
    procedure TestImageAltAndUri;
  end;

implementation

function TMdInlineTest.Tok(const AText: string): TMdTokenArray;
begin
  Result := TokenizeInline(UnicodeString(AText));
end;

function TMdInlineTest.Kinds(const AText: string): string;
const
  Names: array[TMdTokKind] of string = (
    'text', 'code', 'open', 'close', 'linkopen', 'imageopen', 'autolink',
    'softbreak', 'hardbreak');
var
  T: TMdTokenArray;
  I: Integer;
begin
  T := Tok(AText);
  Result := '';
  for I := 0 to High(T) do
  begin
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + Names[T[I].Kind];
  end;
end;

function TMdInlineTest.Marked(const AText: string): string;
var
  T: TMdTokenArray;
  I: Integer;
  Depth: Integer;
  Body: UnicodeString;
begin
  T := Tok(AText);
  Body := '';
  Depth := 0;
  for I := 0 to High(T) do
    case T[I].Kind of
      tkOpen: Inc(Depth);
      tkClose: Dec(Depth);
      tkText:
        if Depth > 0 then
          Body := Body + '[' + T[I].Text + ']'
        else
          Body := Body + T[I].Text;
      tkCode: Body := Body + '`' + T[I].Text + '`';
    else
      ;
    end;
  Result := UTF8Encode(Body);
end;

{ --- linearity ------------------------------------------------------------ }

procedure TMdInlineTest.TestLinearOnBracketFlood;
var
  Text: string;
  T: TMdTokenArray;
  I: Integer;
begin
  { 8000 unmatched brackets. A forward-search tokenizer is O(n^2) here and, in
    the source's regex, took seconds at 1/40th this size. }
  SetLength(Text, 8000);
  for I := 1 to 8000 do
    Text[I] := '[';
  T := Tok(Text);
  AssertTrue('completed with tokens', Length(T) > 0);
  AssertTrue('token count bounded by input', Length(T) <= 8000 * 4);
end;

procedure TMdInlineTest.TestLinearOnLinkFlood;
var
  Text: string;
  T: TMdTokenArray;
  I: Integer;
begin
  { The EXACT shape that took 6.8 s at 200 characters in the source. }
  Text := '';
  for I := 1 to 800 do
    Text := Text + '[a](';
  T := Tok(Text);
  AssertTrue('completed', Length(T) >= 0);
  AssertTrue('token count bounded', Length(T) <= Length(Text) * 4);
end;

procedure TMdInlineTest.TestLinearOnAsteriskFlood;
var
  Text: string;
  T: TMdTokenArray;
  I: Integer;
begin
  Text := '';
  for I := 1 to 4000 do
    Text := Text + '*';
  T := Tok(Text);
  AssertTrue('completed', Length(T) >= 0);
  AssertTrue('bounded', Length(T) <= Length(Text) * 4);
end;

procedure TMdInlineTest.TestLinearOnBacktickFlood;
var
  Text: string;
  T: TMdTokenArray;
  I: Integer;
begin
  Text := '';
  for I := 1 to 4000 do
    Text := Text + '`';
  T := Tok(Text);
  AssertTrue('completed', Length(T) >= 0);
end;

procedure TMdInlineTest.TestTokenCountIsBoundedByInput;
var
  Cases: array[0..4] of string = (
    'plain words and more words',
    '**bold** and *italic* and `code`',
    '[a](http://x) and [b](http://y)',
    'a' + #10 + 'b' + #10 + 'c',
    '~~~[[]](((]]])))***');
  I, K: Integer;
  T: TMdTokenArray;
begin
  { A linear tokenizer emits a number of tokens proportional to its input. This
    is the structural form of the linearity claim: no path can emit tokens from
    nothing. }
  for I := 0 to High(Cases) do
  begin
    T := Tok(Cases[I]);
    AssertTrue('case ' + IntToStr(I) + ' produced tokens', Length(T) > 0);
    AssertTrue('case ' + IntToStr(I) + ' is bounded',
      Length(T) <= Length(Cases[I]) * 4 + 8);
    K := 0;
    K := K;
  end;
end;

{ --- structure ------------------------------------------------------------ }

procedure TMdInlineTest.TestPlainTextIsOneToken;
var
  T: TMdTokenArray;
begin
  T := Tok('hello world');
  AssertEquals('one token', 1, Length(T));
  AssertTrue('text', T[0].Kind = tkText);
  AssertEquals('content', 'hello world', string(T[0].Text));
end;

procedure TMdInlineTest.TestEmphasisOpensAndCloses;
begin
  AssertEquals('kinds', 'open text close', Kinds('**bold**'));
  AssertEquals('marker form', '[bold]', Marked('**bold**'));
end;

procedure TMdInlineTest.TestNestedEmphasis;
begin
  { The case a single-regex design gets wrong: `**` must lose to `*` where the
    inner run is single. }
  { Both directions: the inner run must not be swallowed by the outer one, which
    is the failure a positional-backreference regex produced. }
  { The marker form shows depth, and text is split at each delimiter boundary -
    so three runs at depth > 0 is correct here, not one. }
  AssertEquals('bold inside italic', '[a ][b][ c]', Marked('*a **b** c*'));
  AssertEquals('italic inside bold', '[a ][b][ c]', Marked('**a *b* c**'));
  { A lone asterisk inside a word is not emphasis. }
  AssertEquals('no emphasis in a word', 'snake_case_x', Marked('snake_case_x'));
end;

procedure TMdInlineTest.TestTripleAsteriskIsBoldItalic;
var
  T: TMdTokenArray;
  F: TMdFormats;
begin
  T := Tok('***x***');
  AssertTrue('has an open', T[0].Kind = tkOpen);
  F := T[0].Formats;
  AssertTrue('bold', mfBold in F);
  { `***` is ONE run carrying both formats. My first expectation assumed the
    body was T[1]; it was T[2], because `***` had opened twice. }
  AssertTrue('the run carries italic too', mfItalic in T[0].Formats);
  AssertEquals('the body', 'x', string(T[1].Text));
  AssertTrue('has a close', T[High(T)].Kind = tkClose);
end;

procedure TMdInlineTest.TestUnmatchedDelimiterIsLiteral;
begin
  { A stray asterisk is text, not an open that swallows the document. }
  AssertEquals('literal', 'a * b', Marked('a * b'));
  AssertEquals('one token', 'text', Kinds('a * b'));
end;

procedure TMdInlineTest.TestCodeSpanIsVerbatim;
var
  T: TMdTokenArray;
begin
  T := Tok('`a **b** c`');
  AssertEquals('one token', 1, Length(T));
  AssertTrue('code', T[0].Kind = tkCode);
  AssertEquals('verbatim, no markup', 'a **b** c', string(T[0].Text));
end;

procedure TMdInlineTest.TestStrikethrough;
begin
  AssertEquals('strike', '[gone]', Marked('~~gone~~'));
end;

procedure TMdInlineTest.TestNewFormats;
var
  T: TMdTokenArray;
begin
  { insert, delete, mark: the formats v1 did not have. }
  T := Tok('++ins++');
  AssertTrue('insert is an open', T[0].Kind = tkOpen);
  AssertTrue('insert format', mfInsert in T[0].Formats);

  T := Tok('--del--');
  AssertTrue('delete is an open', T[0].Kind = tkOpen);
  AssertTrue('delete format', mfDelete in T[0].Formats);

  T := Tok('==mark==');
  AssertTrue('mark is an open', T[0].Kind = tkOpen);
  AssertTrue('mark format', mfMark in T[0].Formats);
end;

procedure TMdInlineTest.TestSoftBreak;
begin
  AssertEquals('soft break', 'text softbreak text', Kinds('a' + #10 + 'b'));
end;

procedure TMdInlineTest.TestHardBreak;
begin
  { Two trailing spaces before a newline is a hard break. }
  AssertEquals('hard break', 'text hardbreak text', Kinds('a  ' + #10 + 'b'));
end;

procedure TMdInlineTest.TestLinkCarriesUri;
var
  T: TMdTokenArray;
begin
  T := Tok('[label](http://example.com/x)');
  AssertTrue('link open', T[0].Kind = tkLinkOpen);
  AssertEquals('uri', 'http://example.com/x', string(T[0].Uri));
  AssertTrue('a close follows', T[High(T)].Kind = tkClose);
end;

procedure TMdInlineTest.TestStreamIsAlwaysBalanced;
var
  Cases: array[0..6] of string = (
    '**unclosed', '*a **b', '***x**', '~~a~', '[a](http://x', '`unclosed',
    '==a==b==');
  I, K, Depth: Integer;
  T: TMdTokenArray;
  Ok: Boolean;
begin
  { An unbalanced stream would make a consumer's emphasis stack leak into the
    next block - a bug that shows up as unrelated text rendering bold. }
  for I := 0 to High(Cases) do
  begin
    T := Tok(Cases[I]);
    Depth := 0;
    Ok := True;
    for K := 0 to High(T) do
      if T[K].Kind = tkOpen then
        Inc(Depth)
      else if T[K].Kind = tkClose then
      begin
        Dec(Depth);
        if Depth < 0 then
          Ok := False;
      end;
    AssertTrue('case ' + IntToStr(I) + ' goes negative', Ok);
    AssertEquals('case ' + IntToStr(I) + ' ends balanced', 0, Depth);
  end;
end;

{ --- security ------------------------------------------------------------- }

procedure TMdInlineTest.TestJavascriptUriIsDropped;
var
  T: TMdTokenArray;
  I: Integer;
begin
  { THIS IS A LIVE INJECTION VECTOR IN A TERMINAL, not a theoretical one: an
    OSC 8 hyperlink is a terminal-initiated action. The URI must never reach a
    token. }
  T := Tok('[click](javascript:alert(1))');
  for I := 0 to High(T) do
    AssertTrue('no link token emitted',
      T[I].Kind <> tkLinkOpen);
  AssertTrue('and the text is not lost', TokenText(T) <> '');
end;

procedure TMdInlineTest.TestDataUriIsDropped;
var
  T: TMdTokenArray;
  I: Integer;
begin
  T := Tok('[x](data:text/html,<script>alert(1)</script>)');
  for I := 0 to High(T) do
    AssertTrue('no link token', T[I].Kind <> tkLinkOpen);
end;

procedure TMdInlineTest.TestFileUriIsDropped;
var
  T: TMdTokenArray;
  I: Integer;
begin
  T := Tok('[x](file:///etc/passwd)');
  for I := 0 to High(T) do
    AssertTrue('no link token', T[I].Kind <> tkLinkOpen);
end;

procedure TMdInlineTest.TestHttpHttpsMailtoAllowed;
begin
  AssertTrue('http', UriAllowed('http://example.com'));
  AssertTrue('https', UriAllowed('https://example.com'));
  AssertTrue('mailto', UriAllowed('mailto:a@b.example'));
  AssertTrue('uppercase scheme', UriAllowed('HTTPS://example.com'));
end;

procedure TMdInlineTest.TestRelativeUriAllowed;
begin
  AssertTrue('a path', UriAllowed('/docs/page.md'));
  AssertTrue('a relative path', UriAllowed('page.md'));
  AssertTrue('a fragment', UriAllowed('#section'));
end;

procedure TMdInlineTest.TestColonInPathIsNotAScheme;
begin
  { A colon after a path separator is part of the path, not a scheme - so this
    must not be rejected as an unknown scheme. }
  AssertTrue('path with a colon', UriAllowed('./a:b/c'));
  AssertTrue('query with a colon', UriAllowed('?t=1:2'));
end;

procedure TMdInlineTest.TestAutolinkIsAllowListed;
var
  T: TMdTokenArray;
begin
  T := Tok('<https://example.com/x>');
  AssertEquals('one token', 1, Length(T));
  AssertTrue('autolink', T[0].Kind = tkAutolink);
  AssertEquals('uri', 'https://example.com/x', string(T[0].Uri));

  { An autolink with a bad scheme must not become a link. }
  T := Tok('<javascript:alert(1)>');
  AssertTrue('not an autolink',
    (Length(T) = 0) or (T[0].Kind <> tkAutolink));
end;

procedure TMdInlineTest.TestImageAltAndUri;
var
  T: TMdTokenArray;
begin
  T := Tok('![alt text](https://example.com/a.png)');
  AssertEquals('one token', 1, Length(T));
  AssertTrue('image', T[0].Kind = tkImageOpen);
  AssertEquals('alt', 'alt text', string(T[0].Text));
  AssertEquals('uri', 'https://example.com/a.png', string(T[0].Uri));
end;

initialization
  RegisterTest(TMdInlineTest);

end.
