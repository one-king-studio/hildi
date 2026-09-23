unit hildegard.helper.tui.prompt;
{ A single-line prompt editor for the TUI: cursor editing by grapheme cluster,
  submit on Enter, and Up/Down history. Width-aware, so combining marks and wide
  characters count for what they display.}

{$mode delphi}{$H+}

interface

uses
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget;

type
  TPromptSubmittedEvent = procedure(const AText: string) of object;
  TPromptIntArray = array of Integer;

  { A leaf widget: a prompt marker followed by an editable line. The cursor
    position is a grapheme-cluster index; the view scrolls horizontally so the
    cursor stays visible. When inactive it ignores input and renders dimmed. }
  TPromptLine = class(TWidget)
  private
    FText: UnicodeString;
    FCursor: Integer;
    FHistory: array of string;
    FHistoryPos: Integer;
    FHistoryDraft: UnicodeString;
    FPrompt: UnicodeString;
    FActive: Boolean;
    FAttr: TAttr;
    FOnSubmit: TPromptSubmittedEvent;
    procedure SetActive(AValue: Boolean);
    function ClusterStarts: TPromptIntArray;
    procedure InsertText(const ACh: UnicodeString);
    procedure Backspace;
    procedure DeleteForward;
    procedure MoveLeft;
    procedure MoveRight;
    procedure RecallHistory(ADelta: Integer);
    procedure Submit;
  public
    constructor Create(const APrompt: string = '> ');
    { Clears the text and cursor; history is kept. }
    procedure Clear;
    procedure AddHistory(const AText: string);
    function Text: string;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;

    property Active: Boolean read FActive write SetActive;
    property Prompt: UnicodeString read FPrompt write FPrompt;
    property Attr: TAttr read FAttr write FAttr;
    property OnSubmit: TPromptSubmittedEvent read FOnSubmit write FOnSubmit;
  end;

implementation

uses
  SysUtils, graphemebreakproperty, eastasianwidth;

function FirstCodePoint(const ACluster: UnicodeString): UCS4Char;
var
  C1, C2: UCS4Char;
begin
  Result := 0;
  if Length(ACluster) = 0 then
    Exit;
  C1 := UCS4Char(ACluster[1]);
  if (C1 >= $D800) and (C1 <= $DBFF) and (Length(ACluster) >= 2) then
  begin
    C2 := UCS4Char(ACluster[2]);
    if (C2 >= $DC00) and (C2 <= $DFFF) then
      Result := $10000 + ((C1 - $D800) shl 10) or (C2 - $DC00)
    else
      Result := C1;
  end
  else
    Result := C1;
end;

function ClusterWidth(const ACluster: UnicodeString): Integer;
begin
  if Length(ACluster) = 0 then
    Exit(0);
  case GetEastAsianWidth(FirstCodePoint(ACluster)) of
    eawW, eawF:
      Result := 2;
  else
    Result := 1;
  end;
end;

function StringWidth(const S: UnicodeString): Integer;
var
  E: TUnicodeStringExtendedGraphemeClustersEnumerator;
begin
  Result := 0;
  E := TUnicodeStringExtendedGraphemeClustersEnumerator.Create(S);
  try
    while E.MoveNext do
      Inc(Result, ClusterWidth(E.Current));
  finally
    E.Free;
  end;
end;

type
  TPromptCell = record
    Ch: UnicodeString;
    Attr: TAttr;
    Width: Integer;
  end;
  TPromptCellArray = array of TPromptCell;

function AsCell(const C: TPromptCell): TCell;
begin
  Result := Default(TCell);
  Result.Ch := C.Ch;
  Result.Attr := C.Attr;
end;

procedure AddCells(var ACells: TPromptCellArray; const S: UnicodeString;
  const AAttr: TAttr);
var
  E: TUnicodeStringExtendedGraphemeClustersEnumerator;
  Cell: TPromptCell;
begin
  E := TUnicodeStringExtendedGraphemeClustersEnumerator.Create(S);
  try
    while E.MoveNext do
    begin
      Cell := Default(TPromptCell);
      Cell.Ch := E.Current;
      Cell.Attr := AAttr;
      Cell.Width := ClusterWidth(E.Current);
      SetLength(ACells, Length(ACells) + 1);
      ACells[High(ACells)] := Cell;
    end;
  finally
    E.Free;
  end;
end;

constructor TPromptLine.Create(const APrompt: string);
begin
  inherited Create;
  FPrompt := UnicodeString(APrompt);
  FAttr := DefaultAttr;
  FActive := True;
  FHistoryPos := 0;
  Clear;
end;

procedure TPromptLine.Clear;
begin
  FText := '';
  FCursor := 0;
  FHistoryPos := Length(FHistory);
  FHistoryDraft := '';
  if FBounds.W > 0 then
    FVisible := True;
end;

function TPromptLine.Text: string;
begin
  Result := string(FText);
end;

procedure TPromptLine.SetActive(AValue: Boolean);
begin
  FActive := AValue;
end;

procedure TPromptLine.AddHistory(const AText: string);
begin
  SetLength(FHistory, Length(FHistory) + 1);
  FHistory[High(FHistory)] := AText;
  FHistoryPos := Length(FHistory);
  FHistoryDraft := '';
end;

function TPromptLine.ClusterStarts: TPromptIntArray;
var
  E: TUnicodeStringExtendedGraphemeClustersEnumerator;
  Pos: Integer;
begin
  Result := nil;
  Pos := 1;
  E := TUnicodeStringExtendedGraphemeClustersEnumerator.Create(FText);
  try
    while E.MoveNext do
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Pos;
      Inc(Pos, Length(E.Current));
    end;
  finally
    E.Free;
  end;
end;

procedure TPromptLine.InsertText(const ACh: UnicodeString);
var
  Starts: TPromptIntArray;
  CodePos: Integer;
begin
  Starts := ClusterStarts;
  if FCursor < Length(Starts) then
    CodePos := Starts[FCursor]
  else
    CodePos := Length(FText) + 1;
  FText := Copy(FText, 1, CodePos - 1) + ACh +
    Copy(FText, CodePos, Length(FText) - CodePos + 1);
  Inc(FCursor);
end;

procedure TPromptLine.Backspace;
var
  Starts: TPromptIntArray;
  StartPos, EndPos: Integer;
begin
  if FCursor <= 0 then
    Exit;
  Starts := ClusterStarts;
  StartPos := Starts[FCursor - 1];
  if FCursor < Length(Starts) then
    EndPos := Starts[FCursor]
  else
    EndPos := Length(FText) + 1;
  FText := Copy(FText, 1, StartPos - 1) +
    Copy(FText, EndPos, Length(FText) - EndPos + 1);
  Dec(FCursor);
end;

procedure TPromptLine.DeleteForward;
var
  Starts: TPromptIntArray;
  StartPos, EndPos: Integer;
begin
  Starts := ClusterStarts;
  if FCursor >= Length(Starts) then
    Exit;
  StartPos := Starts[FCursor];
  if FCursor + 1 < Length(Starts) then
    EndPos := Starts[FCursor + 1]
  else
    EndPos := Length(FText) + 1;
  FText := Copy(FText, 1, StartPos - 1) +
    Copy(FText, EndPos, Length(FText) - EndPos + 1);
end;

procedure TPromptLine.MoveLeft;
begin
  if FCursor > 0 then
    Dec(FCursor);
end;

procedure TPromptLine.MoveRight;
begin
  if FCursor < Length(ClusterStarts) then
    Inc(FCursor);
end;

procedure TPromptLine.RecallHistory(ADelta: Integer);
var
  NewPos: Integer;
begin
  if Length(FHistory) = 0 then
    Exit;
  if FHistoryPos > Length(FHistory) then
    FHistoryPos := Length(FHistory);
  NewPos := FHistoryPos + ADelta;
  if NewPos < 0 then
    NewPos := 0;
  if NewPos > Length(FHistory) then
    NewPos := Length(FHistory);
  if (ADelta < 0) and (FHistoryPos = Length(FHistory)) then
    FHistoryDraft := FText;
  if NewPos = Length(FHistory) then
    FText := FHistoryDraft
  else
    FText := UnicodeString(FHistory[NewPos]);
  FHistoryPos := NewPos;
  FCursor := Length(ClusterStarts);
end;

procedure TPromptLine.Submit;
var
  Submitted: string;
begin
  Submitted := Trim(string(FText));
  if Submitted = '' then
    Exit;
  AddHistory(Submitted);
  Clear;
  if Assigned(FOnSubmit) then
    FOnSubmit(Submitted);
end;

function TPromptLine.Measure(const AAvail: TSize): TSize;
begin
  Result := Default(TSize);
  Result.W := StringWidth(FPrompt) + StringWidth(FText) + 1;
  if Result.W > AAvail.W then
    Result.W := AAvail.W;
  Result.H := 1;
end;

procedure TPromptLine.Render(const S: ISurface);
var
  PromptCells, TextCells: TPromptCellArray;
  TextAttr, CursorAttr: TAttr;
  I, PromptW, CursorCol, Total, StartCol, Col, X: Integer;
  Cell: TCell;
begin
  if (FBounds.W <= 0) or (FBounds.H <= 0) then
    Exit;
  TextAttr := FAttr;
  if not FActive then
    Include(TextAttr.Style, sfDim);
  PromptCells := nil;
  TextCells := nil;
  AddCells(PromptCells, FPrompt, FAttr);
  AddCells(TextCells, FText, TextAttr);

  PromptW := 0;
  for I := 0 to High(PromptCells) do
    Inc(PromptW, PromptCells[I].Width);
  CursorCol := PromptW;
  for I := 0 to FCursor - 1 do
    if I <= High(TextCells) then
      Inc(CursorCol, TextCells[I].Width);
  Total := PromptW;
  for I := 0 to High(TextCells) do
    Inc(Total, TextCells[I].Width);

  if CursorCol >= FBounds.W then
    StartCol := CursorCol - FBounds.W + 1
  else if Total >= FBounds.W then
    StartCol := Total - FBounds.W + 1
  else
    StartCol := 0;
  if StartCol < 0 then
    StartCol := 0;

  CursorAttr := FAttr;
  Include(CursorAttr.Style, sfReverse);

  S.PushClip(FBounds);
  Col := 0;
  for I := 0 to High(PromptCells) do
  begin
    if (Col >= StartCol) and (Col - StartCol < FBounds.W) then
      S.Put(FBounds.X + (Col - StartCol), FBounds.Y, AsCell(PromptCells[I]));
    Inc(Col, PromptCells[I].Width);
  end;
  for I := 0 to High(TextCells) do
  begin
    if (Col >= StartCol) and (Col - StartCol < FBounds.W) then
      if FActive and (I = FCursor) then
      begin
        Cell := Default(TCell);
        Cell.Ch := TextCells[I].Ch;
        Cell.Attr := CursorAttr;
        S.Put(FBounds.X + (Col - StartCol), FBounds.Y, Cell);
      end
      else
        S.Put(FBounds.X + (Col - StartCol), FBounds.Y, AsCell(TextCells[I]));
    Inc(Col, TextCells[I].Width);
  end;
  if FActive and (FCursor > High(TextCells)) and (Col >= StartCol) and
    (Col - StartCol < FBounds.W) then
  begin
    Cell := Default(TCell);
    Cell.Ch := ' ';
    Cell.Attr := CursorAttr;
    X := FBounds.X + (Col - StartCol);
    S.Put(X, FBounds.Y, Cell);
  end;
  S.PopClip;
end;

function TPromptLine.HandleEvent(const E: TInputEvent): Boolean;
begin
  if not FActive then
    Exit(False);
  if E.Kind <> ikKey then
    Exit(False);
  case E.Key.Kind of
    kkChar:
      begin
        InsertText(E.Key.Ch);
        Exit(True);
      end;
    kkBackspace:
      begin
        Backspace;
        Exit(True);
      end;
    kkDelete:
      begin
        DeleteForward;
        Exit(True);
      end;
    kkLeft:
      begin
        MoveLeft;
        Exit(True);
      end;
    kkRight:
      begin
        MoveRight;
        Exit(True);
      end;
    kkHome:
      begin
        FCursor := 0;
        Exit(True);
      end;
    kkEnd:
      begin
        FCursor := Length(ClusterStarts);
        Exit(True);
      end;
    kkUp:
      begin
        RecallHistory(-1);
        Exit(True);
      end;
    kkDown:
      begin
        RecallHistory(1);
        Exit(True);
      end;
    kkEnter:
      begin
        Submit;
        Exit(True);
      end;
  else
    ;
  end;
  Result := False;
end;

end.
