unit tui.widgets.mdtheme;
{ The markdown theme: AST styles mapped to cell attributes.

  This lived inside the parser (hildi.markdown), which is why that
  unit could not be consumed by anything without a terminal. The parser produces
  spans; deciding what colour bold is belongs to the view. So the theme lives
  here, in the TUI layer, and the AST never carries a TAttr.

  One identifier changed in the move: StyleFor became MdAttrFor, because
  `StyleFor` is too generic for a unit that anything may `uses`. Callers change
  that one name and nothing else. }

{$mode delphi}{$H+}

interface

uses
  markdown.types,
  tui.base;

type
  { Block kinds and inline styles mapped to cell attributes. Bold, Italic, and
    Strike carry the emphasis colour; Code carries the chip foreground (its
    background comes from CodeBackdrop). }
  TMdTheme = record
    Heading: array[1..6] of TAttr;
    Paragraph: TAttr;
    ListBullet: TAttr;
    Quote: TAttr;
    Code: TAttr;         { inline code foreground; the chip bg is CodeBackdrop }
    CodeBackdrop: TAttr; { fenced code surface, and the inline code chip }
    Link: TAttr;
    Rule: TAttr;
    Bold: TAttr;
    Italic: TAttr;
    Strike: TAttr;
    Muted: TAttr;        { code fence language, and other quiet chrome }
  end;

{ The default theme (no terminal dependency; caller may override). }
function DefaultMdTheme: TMdTheme;

{ Resolve a span's attributes from its inline styles and the theme. }
function MdAttrFor(const AStyles: TMdInlineStyles; const ATheme: TMdTheme): TAttr;

{ Resolve the base attributes for a block kind and level. }
function MdBlockAttr(AKind: TMdBlockKind; ALevel: Integer; const ATheme: TMdTheme): TAttr;

implementation

function MdAttr(AFg: Byte; AStyle: TStyle): TAttr;
begin
  Result := DefaultAttr;
  Result.Fg := AFg;
  Result.Style := AStyle + [sfScreenBg];
end;

function DefaultMdTheme: TMdTheme;
begin
  Result := Default(TMdTheme);
  { Emphasis carries a colour so it survives a terminal that ignores italic or
    maps bold to the bright colour: bold is gold, italic cyan, and bold+italic
    takes the cool cyan in bold. Headings use the bold gold. Inline code is a
    violet chip on the sunken surface; the tan is the list marker. }
  Result.Heading[1] := MdAttr(222, [sfBold]);
  Result.Heading[2] := MdAttr(222, [sfBold]);
  Result.Heading[3] := MdAttr(222, [sfBold]);
  Result.Heading[4] := MdAttr(222, [sfBold]);
  Result.Heading[5] := MdAttr(222, [sfBold]);
  Result.Heading[6] := MdAttr(222, [sfBold]);
  Result.Paragraph := MdAttr(250, []);
  Result.ListBullet := MdAttr(180, []);
  Result.Quote := MdAttr(245, [sfDim]);
  Result.Code := MdAttr(140, []);
  Result.CodeBackdrop := MdAttr(252, []);
  Result.CodeBackdrop.Bg := 233;
  Exclude(Result.CodeBackdrop.Style, sfScreenBg);
  Result.Link := MdAttr(75, [sfUnderline]);
  Result.Rule := MdAttr(240, []);
  Result.Bold := MdAttr(222, [sfBold]);
  Result.Italic := MdAttr(116, [sfItalic]);
  Result.Strike := MdAttr(250, [sfStrike]);
  Result.Muted := MdAttr(245, []);
end;

function MdAttrFor(const AStyles: TMdInlineStyles; const ATheme: TMdTheme): TAttr;
begin
  { Code and link replace the colour; code also carries the chip background.
    Bold+italic takes the cool (italic) colour in bold, so it stays distinct
    from plain bold even when the italic rendition is not available. }
  if misCode in AStyles then
  begin
    Result := ATheme.Code;
    Result.Bg := ATheme.CodeBackdrop.Bg;
    Exclude(Result.Style, sfScreenBg);
  end
  else if misLink in AStyles then
    Result := ATheme.Link
  else if misItalic in AStyles then
    Result := ATheme.Italic
  else if misBold in AStyles then
    Result := ATheme.Bold
  else
    Result := ATheme.Paragraph;
  if misBold in AStyles then
    Result.Style := Result.Style + [sfBold];
  if misItalic in AStyles then
    Result.Style := Result.Style + [sfItalic];
  if misStrike in AStyles then
    Result.Style := Result.Style + [sfStrike];
end;

function MdBlockAttr(AKind: TMdBlockKind; ALevel: Integer;
  const ATheme: TMdTheme): TAttr;
begin
  case AKind of
    mbHeading:
      if (ALevel >= 1) and (ALevel <= 6) then
        Result := ATheme.Heading[ALevel]
      else
        Result := ATheme.Heading[1];
    mbQuote:
      Result := ATheme.Quote;
    mbCodeFence:
      Result := ATheme.CodeBackdrop;
    mbRule:
      Result := ATheme.Rule;
    mbListItem:
      Result := ATheme.ListBullet;
  else
    Result := ATheme.Paragraph;
  end;
end;

end.
