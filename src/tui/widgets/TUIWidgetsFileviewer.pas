unit TUIWidgetsFileviewer;
{ A read-only file viewer: one file, rendered as text, scrollable.

  v1 READS. No editing, no search, no jump-to-heading, no syntax highlighting
  inside fences. That is a scope decision from the spec, not an omission, and the
  acceptance criteria name only reads.

  Two kinds, chosen by extension: `.md`/`.markdown` render as a document, anything
  else renders as plain lines. A file that cannot be read renders the ERROR AS
  TEXT rather than raising - a viewer that cannot open a file must still draw, or
  the pane shows a blank rectangle with no explanation.

  ponytail: the markdown path renders through MarkdownRender.RenderTree, which
  produces PLAIN lines - so markdown here is unstyled. That is deliberate for v1:
  the styled path already exists in TUIWidgetsMarkdownView, and wiring this pane
  to it is a separate piece of work (it needs a scroll offset threaded through
  that widget). The ceiling is stated so nobody assumes styling was forgotten.

  Scroll is clamped so content shorter than the view cannot scroll into blank
  space: a viewer that scrolls past its own end looks broken. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils,
  MarkdownTypes, MarkdownTree, MarkdownStream, MarkdownRender,
  TUIBase, TUIWidget, TUIInput, TUISurface, TUIGrapheme,
  TUIWidgetsMdtheme, TUIWidgetsMarkdownView, TUIWidgetsScroll;
  { TUISurface already exports PutText, which measures clusters - the reason the
    viewer composes with it rather than writing cells itself. }

type
  TFileViewKind = (fvMarkdown, fvPlain);

  TFileViewer = class(TWidget)
  public
    const
      { A file larger than this is truncated with a notice rather than loaded
        whole. Refusing to open would be worse: a 20 MB log is still readable at
        its top. }
      DefaultMaxBytes = 512 * 1024;
  private
    FPath: string;
    FKind: TFileViewKind;
    FLines: TStringArray;     { the rendered lines, already wrapped }
    FRaw: TStringArray;       { unwrapped source lines, for re-wrapping }
    FScrollY: Integer;
    FError: string;
    FTruncated: Boolean;
    FMaxBytes: Integer;
    FLoaded: Boolean;
    { For markdown, the STYLED path: a markdownview inside a scroll container.
      Composed rather than threaded: TScrollContainer measures any child, so the
      viewer gains styled rendering without markdownview needing to learn about
      scroll offsets. Nil for plain files. }
    FStyled: TWidget;
    FMarkdown: TMarkdownView;   { the child inside FStyled, kept typed }
    function ReadFile(const APath: string; out AText: string;
      out ATruncated: Boolean): Boolean;
    procedure BuildLines(AWidth: Integer);
    function BodyHeight: Integer;
    procedure ClampScroll;
    function WrapLine(const ALine: string; AWidth: Integer): TStringArray;
  public
    constructor Create;
    destructor Destroy; override;
    { Load a path. Markdown by extension, plain otherwise. A read failure renders
      the error as text rather than raising. }
    procedure Open(const APath: string);
    procedure Reload;
    { Scroll by a delta, clamped. }
    procedure ScrollBy(ADelta: Integer);
    procedure ScrollTo(AY: Integer);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    property Kind: TFileViewKind read FKind;
    property Path: string read FPath;
    property ScrollY: Integer read FScrollY;
    property Truncated: Boolean read FTruncated;
    { The error text drawn instead of content, or '' when the file loaded. }
    property ErrorText: string read FError;
    { The rendered lines. Exposed so a test can assert content without a surface. }
    function LineCount: Integer;
    function LineAt(AIndex: Integer): string;
    property MaxBytes: Integer read FMaxBytes write FMaxBytes;
  end;

{ The kind a path maps to, by extension. Exposed for tests. }
function KindOfPath(const APath: string): TFileViewKind;

implementation

const
  { Text attributes resolved per render, so the viewer carries no theme. }
  ColBody = 250;
  ColNotice = 222;

function LowerExt(const APath: string): string;
begin
  Result := LowerCase(ExtractFileExt(APath));
end;

function KindOfPath(const APath: string): TFileViewKind;
var
  E: string;
begin
  E := LowerExt(APath);
  if (E = '.md') or (E = '.markdown') or (E = '.mdown') then
    Result := fvMarkdown
  else
    Result := fvPlain;
end;

destructor TFileViewer.Destroy;
begin
  FStyled.Free;
  inherited Destroy;
end;

constructor TFileViewer.Create;
begin
  inherited Create;
  FPath := '';
  FKind := fvPlain;
  FScrollY := 0;
  FError := '';
  FTruncated := False;
  FMaxBytes := DefaultMaxBytes;
  FLoaded := False;
end;

function TFileViewer.ReadFile(const APath: string; out AText: string;
  out ATruncated: Boolean): Boolean;
var
  Stream: TFileStream;
  Size, ToRead: Int64;
begin
  Result := False;
  AText := '';
  ATruncated := False;
  try
    Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  except
    { A viewer that cannot open a file must still draw; the caller renders the
      error. Catching here rather than letting it escape is the whole point. }
    Exit(False);
  end;
  try
    Size := Stream.Size;
    if Size > FMaxBytes then
    begin
      ToRead := FMaxBytes;
      ATruncated := True;
    end
    else
      ToRead := Size;
    SetLength(AText, ToRead);
    if ToRead > 0 then
      Stream.ReadBuffer(AText[1], ToRead);
    Result := True;
  finally
    Stream.Free;
  end;
end;

procedure TFileViewer.Open(const APath: string);
var
  Text: string;
  Doc: TMdDocument;
  Rendered: TMdLineArray;
  I: Integer;
  Src: TStringArray;
  P, From: Integer;
  Line: string;
begin
  FPath := APath;
  FKind := KindOfPath(APath);
  FScrollY := 0;
  FTruncated := False;
  FError := '';
  FRaw := nil;
  FLines := nil;
  FLoaded := False;
  { The container owns its child, so freeing it frees the view; drop both
    references together or FMarkdown dangles. }
  FStyled.Free;
  FStyled := nil;
  FMarkdown := nil;

  if APath = '' then
  begin
    FError := 'no file';
    Exit;
  end;
  if not FileExists(APath) then
  begin
    FError := 'cannot open ' + ExtractFileName(APath);
    Exit;
  end;
  if not ReadFile(APath, Text, FTruncated) then
  begin
    FError := 'cannot read ' + ExtractFileName(APath);
    Exit;
  end;

  if FKind = fvMarkdown then
  begin
    Doc := ParseTree(Text);
    try
      { AWidth 0 means "do not wrap": the viewer wraps to the pane width at
        Arrange time, and remembers the source lines so a resize re-wraps. }
      Rendered := RenderTree(Doc, 0);
    finally
      Doc.Free;
    end;
    SetLength(FRaw, Length(Rendered));
    for I := 0 to High(Rendered) do
      FRaw[I] := Rendered[I];
    { The STYLED view: a markdownview inside a scroll container, composed rather
      than threaded. The plain lines stay as the text form that LineAt reports and
      the tests assert, so one file has both a styled rendering and an addressable
      text form. }
    FMarkdown := TMarkdownView.Create;
    FMarkdown.SetSource(Text);
    FStyled := TScrollContainer.Create(FMarkdown);
  end
  else
  begin
    { Plain: split on newlines, keeping blank lines as blank lines. }
    Src := nil;
    From := 1;
    while From <= Length(Text) do
    begin
      P := Pos(#10, Copy(Text, From, Length(Text)));
      if P = 0 then
      begin
        Line := Copy(Text, From, Length(Text));
        SetLength(Src, Length(Src) + 1);
        Src[High(Src)] := Line;
        Break;
      end;
      Line := Copy(Text, From, P - 1);
      if (Line <> '') and (Line[Length(Line)] = #13) then
        SetLength(Line, Length(Line) - 1);
      SetLength(Src, Length(Src) + 1);
      Src[High(Src)] := Line;
      From := From + P;
    end;
    FRaw := Src;
  end;

  FLoaded := True;
  BuildLines(Bounds.W);
end;

procedure TFileViewer.Reload;
var
  P: string;
  Y: Integer;
begin
  P := FPath;
  Y := FScrollY;
  if P = '' then
    Exit;
  Open(P);
  { A reload keeps the reader's place, clamped to the new content. }
  FScrollY := Y;
  ClampScroll;
end;

function TFileViewer.WrapLine(const ALine: string; AWidth: Integer): TStringArray;
var
  U: UnicodeString;
  I, Start, Taken: Integer;
  Piece: UnicodeString;
begin
  Result := nil;
  if ALine = '' then
  begin
    SetLength(Result, 1);
    Result[0] := '';
    Exit;
  end;
  if AWidth <= 0 then
  begin
    SetLength(Result, 1);
    Result[0] := ALine;
    Exit;
  end;
  { Width is measured in DISPLAY CELLS via TUIGrapheme, not bytes or codepoints:
    a CJK glyph is two cells wide, and wrapping by length would overflow the pane
    for exactly the documents most likely to need wrapping. }
  U := UnicodeString(ALine);
  Start := 1;
  while Start <= Length(U) do
  begin
    Taken := 0;
    I := Start;
    Piece := '';
    while I <= Length(U) do
    begin
      Taken := StringWidth(UnicodeString(U[I]));
      if (Piece <> '') and
        (StringWidth(Piece) + Taken > AWidth) then
        Break;
      Piece := Piece + U[I];
      Inc(I);
    end;
    if Piece = '' then
    begin
      { A single glyph wider than the pane: emit it anyway rather than loop. }
      Piece := U[Start];
      Inc(Start);
    end
    else
      Start := I;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := UTF8Encode(Piece);
  end;
end;

procedure TFileViewer.BuildLines(AWidth: Integer);
var
  I, J: Integer;
  Wrapped: TStringArray;
begin
  FLines := nil;
  for I := 0 to High(FRaw) do
  begin
    Wrapped := WrapLine(FRaw[I], AWidth);
    for J := 0 to High(Wrapped) do
    begin
      SetLength(FLines, Length(FLines) + 1);
      FLines[High(FLines)] := Wrapped[J];
    end;
  end;
  ClampScroll;
end;

function TFileViewer.BodyHeight: Integer;
begin
  Result := Bounds.H;
  if Result < 0 then
    Result := 0;
end;

function TFileViewer.LineCount: Integer;
begin
  if FError <> '' then
    Result := 1
  else
    Result := Length(FLines);
end;

function TFileViewer.LineAt(AIndex: Integer): string;
begin
  if FError <> '' then
  begin
    if AIndex = 0 then
      Result := FError
    else
      Result := '';
    Exit;
  end;
  if (AIndex >= 0) and (AIndex <= High(FLines)) then
    Result := FLines[AIndex]
  else
    Result := '';
end;

procedure TFileViewer.ClampScroll;
var
  MaxTop: Integer;
begin
  { Content shorter than the view cannot scroll: a viewer that scrolls past its
    own end looks broken. }
  MaxTop := Length(FLines) - BodyHeight;
  if MaxTop < 0 then
    MaxTop := 0;
  if FScrollY > MaxTop then
    FScrollY := MaxTop;
  if FScrollY < 0 then
    FScrollY := 0;
end;

procedure TFileViewer.ScrollBy(ADelta: Integer);
begin
  FScrollY := FScrollY + ADelta;
  ClampScroll;
end;

procedure TFileViewer.ScrollTo(AY: Integer);
begin
  FScrollY := AY;
  ClampScroll;
end;

function TFileViewer.Measure(const AAvail: TSize): TSize;
var
  I, Widest: Integer;
begin
  { A file viewer fills what it is given; its content extent is reported so an
    auto track can size to the longest line rather than the widest possible. }
  Widest := 0;
  for I := 0 to High(FRaw) do
    if StringWidth(UnicodeString(FRaw[I])) > Widest then
      Widest := StringWidth(UnicodeString(FRaw[I]));
  if FError <> '' then
    Widest := StringWidth(UnicodeString(FError));
  if (AAvail.W > 0) and (Widest > AAvail.W) then
    Widest := AAvail.W;
  Result.W := Widest;
  Result.H := Length(FLines);
end;

procedure TFileViewer.Arrange(const ABounds: TRect);
var
  OldWidth: Integer;
begin
  OldWidth := Bounds.W;
  inherited Arrange(ABounds);
  { Re-wrap when the pane width changes, so a resize is honoured without
    re-reading the file. }
  if (ABounds.W <> OldWidth) and FLoaded then
    BuildLines(ABounds.W);
  ClampScroll;
  if FStyled <> nil then
    FStyled.Arrange(ABounds);
end;

procedure TFileViewer.Render(const S: ISurface);
var
  I, Row, Last: Integer;
  A: TAttr;
  Text: string;
begin
  if not Visible then
    Exit;

  if FError <> '' then
  begin
    A := DefaultAttr;
    A.Fg := ColNotice;
    PutText(S, Bounds.X, Bounds.Y, UTF8Decode(FError), A);
    Exit;
  end;

  { A markdown file draws through the styled widget. }
  if FStyled <> nil then
  begin
    FStyled.Render(S);
    Exit;
  end;

  Row := 0;
  Last := FScrollY + BodyHeight - 1;
  if Last > High(FLines) then
    Last := High(FLines);
  A := DefaultAttr;
  A.Fg := ColBody;
  for I := FScrollY to Last do
  begin
    Text := FLines[I];
    if Text <> '' then
      PutText(S, Bounds.X, Bounds.Y + Row, UTF8Decode(Text), A);
    Inc(Row);
  end;

  if FTruncated then
  begin
    A := DefaultAttr;
    A.Fg := ColNotice;
    PutText(S, Bounds.X, Bounds.Y + BodyHeight - 1,
      UTF8Decode('(truncated at ' + IntToStr(FMaxBytes) + ' bytes)'), A);
  end;
end;

function TFileViewer.HandleEvent(const E: TInputEvent): Boolean;
begin
  { Every non-navigation key is CONSUMED while the viewer is up: the transcript
    underneath must not receive input it cannot show. So this always returns True
    and only navigation changes the state. }
  Result := True;
  { The styled path owns its own navigation - a scroll container handles the keys
    it was built for, so delegating keeps one implementation of scrolling. }
  if FStyled <> nil then
    Exit(FStyled.HandleEvent(E));
  if E.Kind <> ikKey then
    Exit;
  case E.Key.Kind of
    kkUp:
      ScrollBy(-1);
    kkDown:
      ScrollBy(1);
    kkPageUp:
      ScrollBy(-BodyHeight);
    kkPageDown:
      ScrollBy(BodyHeight);
    kkHome:
      ScrollTo(0);
    kkEnd:
      ScrollTo(Length(FLines));
  else
    ;
  end;
end;

end.
