unit hildegard.helper.tui.edit;
{ A caret-aware multi-line editor for the TUI toolkit.

  The buffer is a UnicodeString (#10 separates logical lines) and the caret is
  an extended-grapheme-cluster index, so navigation and deletion never split a
  combining mark or a surrogate pair. Display rows are derived from the buffer
  and a width; the caret is mapped onto them for painting and for vertical
  movement. Cluster and width handling comes from hildegard.helper.tui.grapheme. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils, Classes,
  hildegard.helper.tui.base, hildegard.helper.tui.grapheme,
  hildegard.helper.tui.input, hildegard.helper.tui.surface,
  hildegard.helper.tui.widget, hildegard.helper.tui.text;

const
  { The caret toggles every 530 ms; 250 ms keeps the app ticking slowly enough
    to catch the blink without the 100 Hz frame cadence. }
  CaretBlinkIntervalMs = 250;

type
  { A display row: the clusters it shows and their total display width. }
  TDisplayRow = record
    First: Integer;   { first cluster shown, inclusive }
    Count: Integer;   { clusters shown }
    Width: Integer;   { display columns }
  end;
  TDisplayRowArray = array of TDisplayRow;

  { A leaf widget: a caret-aware multi-line editor over a UnicodeString.
    The caret is a cluster index in 0..ClusterCount; #10 separates logical
    lines. }
  TTextEdit = class(TWidget)
  private
    FText: UnicodeString;
    FCaret: Integer;
    FWrap: TWrapMode;
    FActive: Boolean;
    FBlinkIntervalMs: Integer;
    FAttr: TAttr;
    FCaretAttr: TAttr;
    FBlinkOn: Boolean;
    FBlinking: Boolean;
    FGoalCol: Integer;
    FGoalEnd: Boolean;
    FSelAnchor: Integer;
    FSelAttr: TAttr;
    FTopRow: Integer;
    FLastWidth: Integer;
    FOnChange: TNotifyEvent;
    procedure SetActive(AValue: Boolean);
    function ClusterCount: Integer;
    function Width: Integer;
    function CaretAt(ARow, ACol: Integer; const ARows: TDisplayRowArray): Integer;
    function WordLeftIndex: Integer;
    function WordRightIndex: Integer;
    procedure BeginMove(AExtend: Boolean);
    procedure DeleteRange(AFrom, ATo: Integer);
    procedure EnsureVisible(AViewportRows: Integer);
    procedure Changed;
  public
    constructor Create(AWrap: TWrapMode = wmWord);
    destructor Destroy; override;

    { Buffer and caret. SetText resets the caret to the end. }
    procedure SetText(const AText: UnicodeString);
    function Text: UnicodeString;
    function CaretIndex: Integer;
    procedure SetCaret(AIndex: Integer);

    { Editing. All of these fire OnChange. }
    procedure InsertText(const AText: UnicodeString);
    procedure Backspace;        { delete the cluster before the caret }
    procedure DeleteForward;    { delete the cluster at the caret }
    procedure Clear;
    { Clear the logical line the caret is on; no-op on an empty line. }
    procedure ClearLine;

    { Caret movement. All of these fire OnChange. AExtend keeps (or starts) a
      selection from the anchor instead of dropping it. }
    procedure MoveLeft(AExtend: Boolean = False);
    procedure MoveRight(AExtend: Boolean = False);
    procedure MoveUp(AExtend: Boolean = False);
    procedure MoveDown(AExtend: Boolean = False);
    procedure MoveHome(AExtend: Boolean = False);   { logical line start }
    procedure MoveEnd(AExtend: Boolean = False);    { logical line end }

    { Word motion. A word is a maximal run of non-whitespace clusters. }
    procedure MoveWordLeft(AExtend: Boolean = False);
    procedure MoveWordRight(AExtend: Boolean = False);
    procedure DeleteWordBack;        { delete the word before the caret }
    procedure DeleteWordForward;     { delete the word after the caret }

    { The selection between an anchor and the caret; empty when there is none. }
    function HasSelection: Boolean;
    function SelectionStart: Integer;
    function SelectionEnd: Integer;
    procedure SelectAll;
    procedure ClearSelection;

    { The display rows for AWidth, the same split Render uses. }
    function Rows(AWidth: Integer): TDisplayRowArray;
    { The caret's display row and column for AWidth. }
    procedure CaretCell(AWidth: Integer; out ARow, ACol: Integer);

    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;

    property Wrap: TWrapMode read FWrap write FWrap;
    property Active: Boolean read FActive write SetActive;
    { False holds the caret solid (the terminal is unfocused); the caret is still
      drawn, it just stops toggling. }
    property Blinking: Boolean read FBlinking write FBlinking;
    property Attr: TAttr read FAttr write FAttr;              { text rendition }
    property CaretAttr: TAttr read FCaretAttr write FCaretAttr;
    { The rendition of a selected cluster. }
    property SelAttr: TAttr read FSelAttr write FSelAttr;
    { The rendition the caret paints over a cluster: the caret colour with its
      foreground and background swapped. Hosts use it so a selection matches the
      cursor exactly. }
    function CaretOverlay: TAttr;
    { Top visible display row; clamped to the row count on every layout. }
    property TopRow: Integer read FTopRow;
    { Fired after the buffer or the caret changed, so the host can re-layout. }
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

implementation

{ A word is a maximal run of clusters that are not whitespace. }
function IsWordChar(const ACluster: UnicodeString): Boolean;
begin
  Result := (ACluster <> '') and (ACluster <> ' ') and (ACluster <> #9) and
    (ACluster <> #10) and (ACluster <> #13);
end;

constructor TTextEdit.Create(AWrap: TWrapMode);
begin
  inherited Create;
  FWrap := AWrap;
  FText := '';
  FCaret := 0;
  FActive := True;
  FBlinkIntervalMs := CaretBlinkIntervalMs;
  FAttr := DefaultAttr;
  FCaretAttr := DefaultAttr;
  FBlinkOn := True;
  FBlinking := True;
  FGoalCol := -1;
  FGoalEnd := False;
  FSelAnchor := -1;
  FTopRow := 0;
  { The caret blinks while the box is active; register it so the app ticks at
    the caret's rate, not the frame cadence. }
  SetAnimation(FBlinkIntervalMs);
end;

procedure TTextEdit.SetActive(AValue: Boolean);
begin
  if AValue = FActive then
    Exit;
  FActive := AValue;
  if FActive then
    SetAnimation(FBlinkIntervalMs)
  else
    ClearAnimation;
end;

destructor TTextEdit.Destroy;
begin
  ClearAnimation;
  inherited Destroy;
end;

function TTextEdit.ClusterCount: Integer;
begin
  Result := Length(Clusters(FText));
end;

procedure TTextEdit.Changed;
begin
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

function TTextEdit.Text: UnicodeString;
begin
  Result := FText;
end;

function TTextEdit.CaretIndex: Integer;
begin
  Result := FCaret;
end;

procedure TTextEdit.SetText(const AText: UnicodeString);
begin
  FText := AText;
  FCaret := ClusterCount;
  FGoalCol := -1;
  FTopRow := 0;
  Changed;
end;

procedure TTextEdit.SetCaret(AIndex: Integer);
var
  N: Integer;
begin
  N := ClusterCount;
  if AIndex < 0 then
    AIndex := 0;
  if AIndex > N then
    AIndex := N;
  if AIndex = FCaret then
    Exit;
  FCaret := AIndex;
  FGoalCol := -1;
  Changed;
end;

procedure TTextEdit.InsertText(const AText: UnicodeString);
var
  Starts: TClusterOffsetArray;
  CodePos, Target, I: Integer;
begin
  if HasSelection then
  begin
    DeleteRange(SelectionStart, SelectionEnd);
    FCaret := SelectionStart;
    FSelAnchor := -1;
  end;
  Starts := ClusterStarts(FText);
  if FCaret < Length(Starts) then
    CodePos := Starts[FCaret]
  else
    CodePos := Length(FText) + 1;
  FText := Copy(FText, 1, CodePos - 1) + AText +
    Copy(FText, CodePos, Length(FText) - CodePos + 1);
  { The caret lands after the inserted text, but an inserted combining mark
    merges into the cluster before it, so recompute the caret from the target
    code-unit offset instead of counting the inserted clusters. }
  Target := CodePos + Length(AText);
  Starts := ClusterStarts(FText);
  FCaret := 0;
  for I := 0 to High(Starts) do
  begin
    if Starts[I] >= Target then
      Break;
    Inc(FCaret);
  end;
  FGoalCol := -1;
  Changed;
end;

procedure TTextEdit.Backspace;
begin
  if HasSelection then
  begin
    DeleteRange(SelectionStart, SelectionEnd);
    FCaret := SelectionStart;
    FSelAnchor := -1;
    FGoalCol := -1;
    FGoalEnd := False;
    Changed;
    Exit;
  end;
  if FCaret <= 0 then
    Exit;
  DeleteRange(FCaret - 1, FCaret);
  Dec(FCaret);
  FGoalCol := -1;
  FGoalEnd := False;
  Changed;
end;

procedure TTextEdit.DeleteForward;
begin
  if HasSelection then
  begin
    DeleteRange(SelectionStart, SelectionEnd);
    FCaret := SelectionStart;
    FSelAnchor := -1;
    FGoalCol := -1;
    FGoalEnd := False;
    Changed;
    Exit;
  end;
  if FCaret >= ClusterCount then
    Exit;
  DeleteRange(FCaret, FCaret + 1);
  FGoalCol := -1;
  FGoalEnd := False;
  Changed;
end;

procedure TTextEdit.DeleteRange(AFrom, ATo: Integer);
var
  Starts: TClusterOffsetArray;
  StartPos, EndPos: Integer;
begin
  if (ATo <= AFrom) or (AFrom < 0) then
    Exit;
  Starts := ClusterStarts(FText);
  if AFrom > High(Starts) then
    Exit;
  StartPos := Starts[AFrom];
  if ATo < Length(Starts) then
    EndPos := Starts[ATo]
  else
    EndPos := Length(FText) + 1;
  FText := Copy(FText, 1, StartPos - 1) +
    Copy(FText, EndPos, Length(FText) - EndPos + 1);
end;

procedure TTextEdit.BeginMove(AExtend: Boolean);
begin
  if AExtend then
  begin
    if FSelAnchor < 0 then
      FSelAnchor := FCaret;
  end
  else
    FSelAnchor := -1;
end;

function TTextEdit.WordLeftIndex: Integer;
var
  C: TClusterArray;
  I: Integer;
begin
  C := Clusters(FText);
  I := FCaret;
  while (I > 0) and (not IsWordChar(C[I - 1])) do
    Dec(I);
  while (I > 0) and IsWordChar(C[I - 1]) do
    Dec(I);
  Result := I;
end;

function TTextEdit.WordRightIndex: Integer;
var
  C: TClusterArray;
  I, N: Integer;
begin
  C := Clusters(FText);
  N := Length(C);
  I := FCaret;
  while (I < N) and IsWordChar(C[I]) do
    Inc(I);
  while (I < N) and (not IsWordChar(C[I])) do
    Inc(I);
  Result := I;
end;

procedure TTextEdit.Clear;
begin
  FText := '';
  FCaret := 0;
  FGoalCol := -1;
  FTopRow := 0;
  Changed;
end;

procedure TTextEdit.ClearLine;
var
  C: TClusterArray;
  I, N, LineStart, LineEnd: Integer;
begin
  C := Clusters(FText);
  N := Length(C);
  LineStart := FCaret;
  while (LineStart > 0) and (C[LineStart - 1] <> #10) do
    Dec(LineStart);
  LineEnd := FCaret;
  while (LineEnd < N) and (C[LineEnd] <> #10) do
    Inc(LineEnd);
  if LineEnd <= LineStart then
    Exit;   { the line is already empty }
  DeleteRange(LineStart, LineEnd);
  FCaret := LineStart;
  FSelAnchor := -1;
  FGoalCol := -1;
  FGoalEnd := False;
  Changed;
end;

function TTextEdit.Width: Integer;
begin
  if FBounds.W > 0 then
    Result := FBounds.W
  else
    Result := FLastWidth;
  if Result < 1 then
    Result := 1;
end;

function TTextEdit.Rows(AWidth: Integer): TDisplayRowArray;
var
  C: TClusterArray;
  RowStart, CurW, I, CW, S, K: Integer;

  procedure Add(ACount, ARowWidth: Integer);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].First := RowStart;
    Result[High(Result)].Count := ACount;
    Result[High(Result)].Width := ARowWidth;
  end;

  function SpanWidth(AFrom, ATo: Integer): Integer;
  var
    J: Integer;
  begin
    Result := 0;
    for J := AFrom to ATo do
      Inc(Result, ClusterWidth(C[J]));
  end;

begin
  if AWidth < 1 then
    AWidth := 1;
  Result := nil;
  C := Clusters(FText);
  RowStart := 0;
  CurW := 0;
  I := 0;
  while I <= High(C) do
  begin
    if C[I] = #10 then
    begin
      Add(I - RowStart, CurW);
      RowStart := I + 1;
      CurW := 0;
      Inc(I);
      Continue;
    end;
    CW := ClusterWidth(C[I]);
    if (FWrap <> wmNone) and (CurW + CW > AWidth) and (I > RowStart) then
    begin
      { Prefer the last space in the row; the space stays at the end of the
        upper row so the rows tile the buffer exactly. }
      S := -1;
      if FWrap = wmWord then
        for K := I - 1 downto RowStart do
          if C[K] = ' ' then
          begin
            S := K;
            Break;
          end;
      if S >= RowStart then
      begin
        Add(S - RowStart + 1, SpanWidth(RowStart, S));
        RowStart := S + 1;
        CurW := SpanWidth(RowStart, I - 1);
      end
      else
      begin
        Add(I - RowStart, CurW);
        RowStart := I;
        CurW := 0;
      end;
    end;
    Inc(CurW, CW);
    Inc(I);
  end;
  Add(Length(C) - RowStart, CurW);
  { The caret needs a cell of its own when the text exactly fills the last
    row, otherwise it would fall off the end of the viewport. }
  if (Length(C) > 0) and (C[High(C)] <> #10) and (FWrap <> wmNone) and
    (Result[High(Result)].Width = AWidth) then
    Add(0, 0);
end;

procedure TTextEdit.CaretCell(AWidth: Integer; out ARow, ACol: Integer);
var
  R: TDisplayRowArray;
  C: TClusterArray;
  I, J: Integer;
begin
  R := Rows(AWidth);
  C := Clusters(FText);
  { The last row that contains the caret: at a soft-wrap boundary this is the
    continuation row, which is where the caret can actually be drawn. }
  ARow := 0;
  for I := 0 to High(R) do
    if (R[I].First <= FCaret) and (FCaret <= R[I].First + R[I].Count) then
      ARow := I;
  ACol := 0;
  for J := R[ARow].First to FCaret - 1 do
    if J <= High(C) then
      Inc(ACol, ClusterWidth(C[J]));
end;

function TTextEdit.CaretAt(ARow, ACol: Integer;
  const ARows: TDisplayRowArray): Integer;
var
  C: TClusterArray;
  I, W: Integer;
begin
  C := Clusters(FText);
  Result := ARows[ARow].First + ARows[ARow].Count;
  W := 0;
  for I := ARows[ARow].First to ARows[ARow].First + ARows[ARow].Count - 1 do
  begin
    if W >= ACol then
    begin
      Result := I;
      Exit;
    end;
    Inc(W, ClusterWidth(C[I]));
  end;
end;

procedure TTextEdit.MoveLeft(AExtend: Boolean);
begin
  BeginMove(AExtend);
  if FCaret <= 0 then
    Exit;
  Dec(FCaret);
  FGoalCol := -1;
  FGoalEnd := False;
  Changed;
end;

procedure TTextEdit.MoveRight(AExtend: Boolean);
begin
  BeginMove(AExtend);
  if FCaret >= ClusterCount then
    Exit;
  Inc(FCaret);
  FGoalCol := -1;
  FGoalEnd := False;
  Changed;
end;

procedure TTextEdit.MoveWordLeft(AExtend: Boolean);
var
  I: Integer;
begin
  BeginMove(AExtend);
  I := WordLeftIndex;
  if I = FCaret then
    Exit;
  FCaret := I;
  FGoalCol := -1;
  FGoalEnd := False;
  Changed;
end;

procedure TTextEdit.MoveWordRight(AExtend: Boolean);
var
  I: Integer;
begin
  BeginMove(AExtend);
  I := WordRightIndex;
  if I = FCaret then
    Exit;
  FCaret := I;
  FGoalCol := -1;
  FGoalEnd := False;
  Changed;
end;

procedure TTextEdit.DeleteWordBack;
var
  I: Integer;
begin
  if HasSelection then
  begin
    Backspace;
    Exit;
  end;
  I := WordLeftIndex;
  if I = FCaret then
    Exit;
  DeleteRange(I, FCaret);
  FCaret := I;
  FGoalCol := -1;
  FGoalEnd := False;
  Changed;
end;

procedure TTextEdit.DeleteWordForward;
var
  I: Integer;
begin
  if HasSelection then
  begin
    DeleteForward;
    Exit;
  end;
  I := WordRightIndex;
  if I = FCaret then
    Exit;
  DeleteRange(FCaret, I);
  FGoalCol := -1;
  FGoalEnd := False;
  Changed;
end;

procedure TTextEdit.MoveUp(AExtend: Boolean);
var
  R: TDisplayRowArray;
  Row, Col: Integer;
begin
  BeginMove(AExtend);
  R := Rows(Width);
  CaretCell(Width, Row, Col);
  if FGoalCol < 0 then
  begin
    FGoalCol := Col;
    { Starting at the end of a row keeps "end of row" as the goal, so a longer
      row below still lands at its end. }
    FGoalEnd := Col >= R[Row].Width;
  end;
  if Row <= 0 then
    Exit;
  if FGoalEnd then
    FCaret := R[Row - 1].First + R[Row - 1].Count
  else
    FCaret := CaretAt(Row - 1, FGoalCol, R);
  Changed;
end;

procedure TTextEdit.MoveDown(AExtend: Boolean);
var
  R: TDisplayRowArray;
  Row, Col: Integer;
begin
  BeginMove(AExtend);
  R := Rows(Width);
  CaretCell(Width, Row, Col);
  if FGoalCol < 0 then
  begin
    FGoalCol := Col;
    FGoalEnd := Col >= R[Row].Width;
  end;
  if Row >= High(R) then
    Exit;
  if FGoalEnd then
    FCaret := R[Row + 1].First + R[Row + 1].Count
  else
    FCaret := CaretAt(Row + 1, FGoalCol, R);
  Changed;
end;

procedure TTextEdit.MoveHome(AExtend: Boolean);
var
  C: TClusterArray;
  I: Integer;
begin
  BeginMove(AExtend);
  C := Clusters(FText);
  I := FCaret;
  while (I > 0) and (C[I - 1] <> #10) do
    Dec(I);
  FGoalCol := -1;
  FGoalEnd := False;
  if I = FCaret then
    Exit;
  FCaret := I;
  Changed;
end;

procedure TTextEdit.MoveEnd(AExtend: Boolean);
var
  C: TClusterArray;
  I, N: Integer;
begin
  BeginMove(AExtend);
  C := Clusters(FText);
  N := Length(C);
  I := FCaret;
  while (I < N) and (C[I] <> #10) do
    Inc(I);
  FGoalCol := -1;
  FGoalEnd := False;
  if I = FCaret then
    Exit;
  FCaret := I;
  Changed;
end;

function TTextEdit.HasSelection: Boolean;
begin
  Result := (FSelAnchor >= 0) and (FSelAnchor <> FCaret);
end;

function TTextEdit.SelectionStart: Integer;
begin
  if not HasSelection then
    Exit(0);
  if FSelAnchor < FCaret then
    Result := FSelAnchor
  else
    Result := FCaret;
end;

function TTextEdit.SelectionEnd: Integer;
begin
  if not HasSelection then
    Exit(0);
  if FSelAnchor > FCaret then
    Result := FSelAnchor
  else
    Result := FCaret;
end;

procedure TTextEdit.SelectAll;
begin
  FSelAnchor := 0;
  FCaret := ClusterCount;
  FGoalCol := -1;
  FGoalEnd := False;
  Changed;
end;

procedure TTextEdit.ClearSelection;
begin
  if FSelAnchor < 0 then
    Exit;
  FSelAnchor := -1;
  Changed;
end;

function TTextEdit.Measure(const AAvail: TSize): TSize;
begin
  FLastWidth := AAvail.W;
  Result := Default(TSize);
  Result.W := AAvail.W;
  Result.H := Length(Rows(AAvail.W));
  if Result.H < 1 then
    Result.H := 1;
end;

function TTextEdit.CaretOverlay: TAttr;
begin
  Result := FCaretAttr;
  Result.Fg := FCaretAttr.Bg;
  Result.Bg := FCaretAttr.Fg;
end;

procedure TTextEdit.EnsureVisible(AViewportRows: Integer);
var
  Row, Col, RowCount: Integer;
begin
  if AViewportRows < 1 then
    AViewportRows := 1;
  RowCount := Length(Rows(FBounds.W));
  CaretCell(FBounds.W, Row, Col);
  if Row < FTopRow then
    FTopRow := Row;
  if Row >= FTopRow + AViewportRows then
    FTopRow := Row - AViewportRows + 1;
  if FTopRow > RowCount - AViewportRows then
    FTopRow := RowCount - AViewportRows;
  if FTopRow < 0 then
    FTopRow := 0;
end;

procedure TTextEdit.Render(const S: ISurface);
var
  R: TDisplayRowArray;
  C: TClusterArray;
  I, J, X, CW, Row, Col: Integer;
  Y: Integer;
  SelFrom, SelTo: Integer;
  Cell: TCell;
begin
  if (FBounds.W <= 0) or (FBounds.H <= 0) then
    Exit;
  R := Rows(FBounds.W);
  C := Clusters(FText);
  { The visible window follows the caret; there is no manual scrolling yet. }
  EnsureVisible(FBounds.H);
  CaretCell(FBounds.W, Row, Col);
  SelFrom := SelectionStart;
  SelTo := SelectionEnd;

  S.PushClip(FBounds);
  for I := FTopRow to High(R) do
  begin
    Y := FBounds.Y + (I - FTopRow);
    if Y >= FBounds.Y + FBounds.H then
      Break;
    X := FBounds.X;
    for J := R[I].First to R[I].First + R[I].Count - 1 do
    begin
      CW := ClusterWidth(C[J]);
      if X + CW > FBounds.X + FBounds.W then
        Break;
      Cell := Default(TCell);
      Cell.Ch := C[J];
      Cell.Attr := FAttr;
      if (J >= SelFrom) and (J < SelTo) then
        Cell.Attr := FSelAttr
      else if FActive and (FBlinkOn or HasSelection) and (I = Row) and
        (X - FBounds.X = Col) then
      begin
        { Over a cluster the caret swaps the caret colour's foreground and
          background, so the cluster stays readable on a solid block. }
        Cell.Attr := CaretOverlay;
      end;
      S.Put(X, Y, Cell);
      Inc(X, CW);
    end;
  end;

  { Past the end of its row the caret has no cluster: a filled block while the
    editor is active, a hollow box when it is not. }
  Y := FBounds.Y + (Row - FTopRow);
  if (Y >= FBounds.Y) and (Y < FBounds.Y + FBounds.H) and
    (Col >= R[Row].Width) and (FBounds.X + Col < FBounds.X + FBounds.W) then
  begin
    if FActive and (FBlinkOn or HasSelection) then
    begin
      Cell := Default(TCell);
      Cell.Ch := '█';
      Cell.Attr := FCaretAttr;
      S.Put(FBounds.X + Col, Y, Cell);
    end
    else if not FActive then
    begin
      Cell := Default(TCell);
      Cell.Ch := '▯';
      Cell.Attr := FCaretAttr;
      S.Put(FBounds.X + Col, Y, Cell);
    end;
  end;
  S.PopClip;
end;

function TTextEdit.HandleEvent(const E: TInputEvent): Boolean;
var
  Extend, Word: Boolean;
begin
  if not FActive then
    Exit(False);
  if E.Kind = ikPaste then
  begin
    { A bracketed paste arrives whole; insert it literally, newlines and all. }
    if E.Text <> '' then
      InsertText(E.Text);
    Exit(True);
  end;
  if E.Kind <> ikKey then
    Exit(False);
  Extend := moShift in E.Key.Mods;
  Word := moAlt in E.Key.Mods;
  if (E.Key.Kind = kkChar) and (moCtrl in E.Key.Mods) then
  begin
    if (E.Key.Ch = 'a') or (E.Key.Ch = 'A') then
    begin
      SelectAll;
      Exit(True);
    end;
    if (E.Key.Ch = 'u') or (E.Key.Ch = 'U') then
    begin
      ClearLine;
      Exit(True);
    end;
    if (E.Key.Ch = 'c') or (E.Key.Ch = 'C') then
    begin
      { Clear the box, but report unhandled when it is already empty, so the
        shell's Ctrl+C falls through to quit. }
      if FText <> '' then
      begin
        Clear;
        Exit(True);
      end;
      Exit(False);
    end;
    Exit(False);
  end;
  Result := True;
  case E.Key.Kind of
    kkChar:
      InsertText(E.Key.Ch);
    kkEnter:
      InsertText(#10);
    kkBackspace:
      if Word then
        DeleteWordBack
      else
        Backspace;
    kkDelete:
      if Word then
        DeleteWordForward
      else
        DeleteForward;
    kkLeft:
      if Word then
        MoveWordLeft(Extend)
      else
        MoveLeft(Extend);
    kkRight:
      if Word then
        MoveWordRight(Extend)
      else
        MoveRight(Extend);
    kkUp:
      MoveUp(Extend);
    kkDown:
      MoveDown(Extend);
    kkHome:
      MoveHome(Extend);
    kkEnd:
      MoveEnd(Extend);
  else
    Result := False;
  end;
end;

function TTextEdit.Advance(const ANowMs: Int64): Boolean;
var
  On2: Boolean;
begin
  { A non-blinking caret (the terminal is unfocused) stays solid. }
  if not FBlinking then
    On2 := True
  else
    On2 := ((ANowMs div 530) mod 2) = 0;
  Result := On2 <> FBlinkOn;
  FBlinkOn := On2;
end;

function TTextEdit.Animating: Boolean;
begin
  Result := FActive;
end;

end.
