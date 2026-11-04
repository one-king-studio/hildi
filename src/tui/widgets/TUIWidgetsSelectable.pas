unit TUIWidgetsSelectable;
{ The widget half of text selection: drag handling and the highlight.

  This is a CONVENIENCE base, not the mechanism. The arithmetic lives in
  TUISelection and knows nothing about widgets; this class supplies the three
  things a widget needs on top of it:

    - a drag state machine driven by TMouseEvent.Action
    - the selected text, read from the widget's own rows
    - a highlight painted over cells that are already drawn

  A subclass supplies its rows (RowCount/RowTextAt/RowWrapsAt) and draws its own
  text, then calls RenderSelection. Widgets that cannot re-parent compose a
  TSelection field and call the same TUISelection functions - one implementation
  of the span logic, two adoption paths.

  Selection is PER WIDGET. A drag that leaves this widget clamps to its edge
  rather than continuing into a neighbour. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils,
  TUIBase, TUIInput,
  TUISurface, TUIWidget,
  TUIGrapheme,
  TUISelection;

type
  TSelectable = class(TWidget)
  private
    FSelection: TSelection;
    FDragging: Boolean;
    { Surface coordinates of content cell (0, 0). Defaults to the widget's own
      top-left after Arrange - which is right for a plain leaf AND for a child of
      a scrolling container, since such a child is arranged at its scrolled
      position. A composite that insets its content (a bordered panel) overrides
      it with SetContentOrigin. }
    FContentX, FContentY: Integer;
    FHighlight: TAttr;
    FSelectable: Boolean;
    function PosAt(AX, AY: Integer): TTextPos;
    procedure ClearStale;
  protected
    { The rows this widget currently draws. A subclass must answer these in the
      same units its Render used, or the highlight and the copy will disagree. }
    function RowCount: Integer; virtual;
    function RowTextAt(ARow: Integer): UnicodeString; virtual;
    { True when ARow ended by wrapping rather than at a line break. Decides
      whether a copy joins that row to the next with a newline. }
    function RowWrapsAt(ARow: Integer): Boolean; virtual;
    { The surface X of display column 0 on AIndex. A block with a hanging indent
      or a centred alignment does not start at its own Bounds.X, so the
      highlight must ask rather than assume. Default: the widget's left edge. }
    function RowOriginX(ARow: Integer): Integer; virtual;
  public
    procedure Arrange(const ABounds: TRect); override;
    { No theme: selection is a behaviour, not a look. The host sets Highlight, so
      a widget that already owns a theme does not have to hand one over. }
    constructor Create;
    { Opt-in. Default False, so re-parenting an existing leaf does not silently
      make every one of them swallow left-clicks. }
    property Selectable: Boolean read FSelectable write FSelectable;
    { The attribute painted over a selected cell. Defaults to reverse video, so
      a host that sets nothing still gets a visible selection. }
    property Highlight: TAttr read FHighlight write FHighlight;
    { Where content cell (0,0) sits on the surface. }
    procedure SetContentOrigin(AX, AY: Integer);
    { Paint the highlight over the cells already drawn for this selection. Must
      be called AFTER the row's text, or the text will paint over it. }
    procedure RenderSelection(const S: ISurface);
    { Drop the selection. Safe to call when there is none. }
    procedure ClearSelection;
    { The widget's content changed under the selection: mark it stale so the
      owner drops it rather than copying text that no longer exists. }
    procedure ContentChanged;
    { The selected text, or '' when nothing usable is selected. }
    function SelectedText: string;
    { Put the selection on the terminal clipboard and say whether anything was
      copied. False means there was nothing usable - the caller shows nothing,
      rather than reporting an error for a no-op. }
    function CopySelection(const S: ISurface): Boolean; override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    property Selection: TSelection read FSelection;
    property Dragging: Boolean read FDragging;
  end;

implementation

constructor TSelectable.Create;
begin
  inherited Create;
  FSelection := Default(TSelection);
  FContentX := 0;
  FContentY := 0;
  FSelectable := False;
  { Reverse video: readable on any theme, and visible even when a host forgets
    to set one. A host that wants the softer accent assigns Highlight. }
  FHighlight := Default(TAttr);
  FHighlight.Style := [sfReverse];
end;

function TSelectable.RowCount: Integer;
begin
  Result := 0;
end;

function TSelectable.RowTextAt(ARow: Integer): UnicodeString;
begin
  Result := '';
end;

function TSelectable.RowWrapsAt(ARow: Integer): Boolean;
begin
  Result := False;
end;

function TSelectable.RowOriginX(ARow: Integer): Integer;
begin
  Result := FBounds.X;
end;

procedure TSelectable.SetContentOrigin(AX, AY: Integer);
begin
  FContentX := AX;
  FContentY := AY;
end;

procedure TSelectable.Arrange(const ABounds: TRect);
begin
  inherited Arrange(ABounds);
  { Content starts where the widget does unless someone says otherwise. Leaving
    this at 0,0 was a real bug: a widget at surface Y=50 mapped a click to row
    50 and painted its highlight 50 rows above its own text. }
  FContentX := ABounds.X;
  FContentY := ABounds.Y;
end;

function TSelectable.PosAt(AX, AY: Integer): TTextPos;
var
  Row, W: Integer;
begin
  Result := Default(TTextPos);
  Row := AY - FContentY;
  if Row < 0 then
    Row := 0;
  if (RowCount > 0) and (Row > RowCount - 1) then
    Row := RowCount - 1;
  if RowCount = 0 then
    Row := 0;
  W := StringWidth(RowTextAt(Row));
  Result := ClampPos(Result, W, RowCount);
  Result.Row := Row;
  Result.Col := AX - FContentX;
  Result := ClampPos(Result, W, RowCount);
end;

procedure TSelectable.ClearStale;
begin
  if FSelection.Stale then
  begin
    FSelection := Default(TSelection);
    FDragging := False;
  end;
end;

procedure TSelectable.ClearSelection;
begin
  FSelection := Default(TSelection);
  FDragging := False;
end;

procedure TSelectable.ContentChanged;
begin
  if FSelection.Active then
    FSelection.Stale := True;
end;

function TSelectable.SelectedText: string;
var
  I: Integer;
  Lines: TStringArray;
  Wraps: TBoolArray;
  Span: TTextSpan;
begin
  Result := '';
  ClearStale;
  if not SelectionIsUsable(FSelection) then
    Exit;
  SetLength(Lines, RowCount);
  SetLength(Wraps, RowCount);
  for I := 0 to RowCount - 1 do
  begin
    Lines[I] := string(RowTextAt(I));
    Wraps[I] := RowWrapsAt(I);
  end;
  Span := SelectionSpan(FSelection);
  Result := SelectionText(Span, Lines, Wraps);
end;

function TSelectable.CopySelection(const S: ISurface): Boolean;
var
  T: string;
begin
  T := SelectedText;
  Result := T <> '';
  if Result then
    S.SetClipboard(UnicodeString(T));
end;

procedure TSelectable.RenderSelection(const S: ISurface);
var
  Span: TTextSpan;
  Row, FirstCol, LastCol, Col, Y, OriginX: Integer;
  C: TCell;
  Line: UnicodeString;
begin
  ClearStale;
  if not SelectionIsUsable(FSelection) then
    Exit;
  Span := SelectionSpan(FSelection);
  for Row := Span.Start.Row to Span.Stop.Row do
  begin
    if (Row < 0) or (Row >= RowCount) then
      Continue;
    Line := RowTextAt(Row);
    if Row = Span.Start.Row then
      FirstCol := Span.Start.Col
    else
      FirstCol := 0;
    if Row = Span.Stop.Row then
      LastCol := Span.Stop.Col
    else
      LastCol := StringWidth(Line);
    if FirstCol < 0 then
      FirstCol := 0;
    Y := FContentY + Row;
    OriginX := RowOriginX(Row);
    Col := 0;
    { Walk the cells so a wide character is highlighted as a whole. Reading the
      cell back rather than assuming a width keeps the highlight on the cells
      the renderer actually painted. }
    while Col < LastCol do
    begin
      C := S.Get(OriginX + Col, Y);
      if (Col >= FirstCol) and (Col < LastCol) then
      begin
        C.Attr := FHighlight;
        S.Put(OriginX + Col, Y, C);
        { A wide cluster occupies two cells; paint its continuation to keep the
          background seamless, since Put on the first cell owns the glyph. }
        if (StringWidth(C.Ch) = 2) and (Col + 1 < LastCol) then
        begin
          C.Ch := '';
          S.Put(OriginX + Col + 1, Y, C);
          Inc(Col);
        end;
      end;
      Inc(Col);
    end;
  end;
end;

function TSelectable.HandleEvent(const E: TInputEvent): Boolean;
var
  P: TTextPos;
begin
  Result := False;
  if E.Kind <> ikMouse then
    Exit;
  { Opt-in. A leaf that adopted this base must not swallow presses unless the
    host asked for selection. }
  if not FSelectable then
    Exit;
  { Shift+click is the terminal's own selection. Consuming it would take
    Shift+drag away from the operator, which is the documented bypass. }
  if moShift in E.Mouse.Mods then
    Exit;

  case E.Mouse.Action of
    maPress:
      begin
        if E.Mouse.Button <> mbLeft then
          Exit;
        if not HitTest(E.Mouse.X, E.Mouse.Y) then
          Exit;
        P := PosAt(E.Mouse.X, E.Mouse.Y);
        FSelection := Default(TSelection);
        FSelection.Active := True;
        FSelection.Anchor := P;
        FSelection.Caret := P;
        FDragging := True;
        Result := True;
      end;
    maMotion:
      begin
        if not FDragging then
          Exit;
        { Clamp to the widget's own content: a drag that leaves the widget ends
          at its edge rather than extending into a neighbour. }
        FSelection.Caret := PosAt(E.Mouse.X, E.Mouse.Y);
        Result := True;
      end;
    maRelease:
      begin
        if not FDragging then
          Exit;
        FDragging := False;
        Result := True;
      end;
  end;
end;

end.
