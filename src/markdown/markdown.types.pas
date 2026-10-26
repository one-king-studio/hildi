unit markdown.types;
{ The markdown AST: blocks of styled spans.

  No presentation, no colour, no theme, no I/O, no terminal. This unit compiles
  against the RTL alone, which is the point of src/markdown/ - a consumer may
  render these into cells, HTML or plain text without inheriting a theme.

  The shape is deliberately UNCHANGED from the parser this was extracted from
  (hildegard.helper.markdown). A new shape would silently change behaviour, so
  the extraction's acceptance bar is that every existing assertion passes with
  import changes only; any assertion that had to change is a regression and is
  justified individually.

  TMdBlock is a value type: records with managed fields, no pointers, no
  ownership protocol. A consumer may copy one freely. }

{$mode delphi}{$H+}

interface

type
  TMdBlockKind = (
    mbBlank,       { a run of blank lines separates blocks; v1 does not emit it }
    mbParagraph,
    mbHeading,
    mbListItem,
    mbCodeFence,
    mbQuote,
    mbRule,
    mbTable);      { a GFM pipe table }

  TMdInlineStyle = (misBold, misItalic, misCode, misStrike, misLink);
  TMdInlineStyles = set of TMdInlineStyle;

  { A run of text with inline styling. Link carries the target for misLink. }
  TMdSpan = record
    Text: UnicodeString;
    Styles: TMdInlineStyles;
    Link: UnicodeString;
  end;

  TMdSpanArray = array of TMdSpan;

  { A table column's alignment, from the delimiter row. }
  TMdAlign = (maNone, maLeft, maCenter, maRight);
  TMdAlignArray = array of TMdAlign;

  { One table row: a run of spans per column. }
  TMdTableRow = array of TMdSpanArray;
  TMdTableRows = array of TMdTableRow;

  { A parsed block. Level is the heading level (1..6), list depth, or quote
    depth as applicable. Language is the code fence info string. Ordered and
    Ordinal record an ordered list item's marker so it renders as written. Head,
    Align, and Rows are set for mbTable only; every row carries exactly
    Length(Align) cells. }
  TMdBlock = record
    Kind: TMdBlockKind;
    Level: Integer;
    Language: UnicodeString;
    Ordered: Boolean;
    Ordinal: Integer;
    Spans: TMdSpanArray;
    Head: TMdTableRow;
    Align: TMdAlignArray;
    Rows: TMdTableRows;
  end;

  TMdBlockArray = array of TMdBlock;

implementation

end.
