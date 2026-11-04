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
  TUISurface, TUITheme, TUIWidget,
  TUIGrapheme,
  TUISelection;

type
  TSelectable = class(TWidget)
  private
    FSelection: TSelection;
    FDragging: Boolean;
    FTheme: TTheme;
    { Surface coordinates of content cell (0, 0). A widget inside a scrolled
      container sets this once per frame so the highlight lands on the cells it
      actually painted. }
    FContentX, FContentY: Integer;
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
  public
    constructor Create(const ATheme: TTheme);
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
    function HandleEvent(const E: TInputEvent): Boolean; override;
    property Selection: TSelection read FSelection;
    property Dragging: Boolean read FDragging;
  end;

implementation

constructor TSelectable.Create(const ATheme: TTheme);
begin
  inherited Create;
  FTheme := ATheme;
  FSelection := Default(TSelection);
  FContentX := 0;
  FContentY := 0;
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

procedure TSelectable.SetContentOrigin(AX, AY: Integer);
begin
  FContentX := AX;
  FContentY := AY;
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

procedure TSelectable.RenderSelection(const S: ISurface);
var
  Span: TTextSpan;
  Row, FirstCol, LastCol, Col, Y: Integer;
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
    Col := 0;
    { Walk the cells so a wide character is highlighted as a whole. Reading the
      cell back rather than assuming a width keeps the highlight on the cells
      the renderer actually painted. }
    while Col < LastCol do
    begin
      C := S.Get(FContentX + Col, Y);
      if (Col >= FirstCol) and (Col < LastCol) then
      begin
        C.Attr := FTheme.AccentSoft;
        S.Put(FContentX + Col, Y, C);
        { A wide cluster occupies two cells; paint its continuation to keep the
          background seamless, since Put on the first cell owns the glyph. }
        if (StringWidth(C.Ch) = 2) and (Col + 1 < LastCol) then
        begin
          C.Ch := '';
          S.Put(FContentX + Col + 1, Y, C);
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
