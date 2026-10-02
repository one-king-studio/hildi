unit hildegard.helper.tui.chat;
{ The chat stream: a scrolling column of message blocks for the harness UI.

  A block is a raised user bubble, plain assistant text, a dimmed collapsible
  thought block, a sunken collapsible tool block, or the animated thinking
  indicator. Blocks are mutable, so a turn can stream into one in place.

  The stream bleeds one column into the panel's right border so the scrollbar
  occupies that border column: its track is not painted (the border reads as the
  track) and only the thumb shows. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.text, hildegard.helper.tui.scroll,
  hildegard.helper.tui.theme;

type
  TChatKind = (ckUser, ckAssistant, ckError, ckThought, ckTool, ckThinking);

  { One block in the stream. Mutable, so a stream can append into it. }
  TChatItem = class(TWidget)
  private
    FKind: TChatKind;
    FLabel: string;
    FBody: string;
    FText: TTextBlock;
    FExpanded: Boolean;
    FTheme: TTheme;
    FOnToggle: TNotifyEvent;
    FOnChange: TNotifyEvent;
    FSpark: Integer;
    function Inset: Integer;
    function BodyAttr: TAttr;
    procedure Rebuild;
    procedure BodyRows(AWidth: Integer; out ATextRows, ALines: Integer);
    function Boxed: Boolean;
  public
    constructor Create(AKind: TChatKind; const ALabel, AText: string;
      const ATheme: TTheme);
    destructor Destroy; override;
    { Replace or append the body text (streaming); both fire OnChange. }
    procedure SetText(const AText: string);
    procedure AppendText(const AText: string);
    function Text: string;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
    property Kind: TChatKind read FKind;
    property Label_: string read FLabel write FLabel;
    property Expanded: Boolean read FExpanded write FExpanded;
    property OnToggle: TNotifyEvent read FOnToggle write FOnToggle;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { A vertical stack of blocks, measured at the available width. }
  TChatStack = class(TWidget)
  private
    FItems: array of TChatItem;
    FTheme: TTheme;
    FGap: Integer;
    FBottomInset: Integer;
    FOnToggle: TNotifyEvent;
    FOnChange: TNotifyEvent;
    function Count: Integer;
    function ItemAt(AIndex: Integer): TChatItem;
  public
    constructor Create(const ATheme: TTheme);
    destructor Destroy; override;
    function Add(AKind: TChatKind; const ALabel, AText: string): TChatItem;
    procedure Clear;
    { Drop and free one block, e.g. the thinking indicator once text arrives. }
    procedure Remove(AItem: TChatItem);
    { Rows at the bottom of the viewport that something else covers (the compose
      overlay). The stack keeps room for them, so the last block still shows its
      two blank pad rows above the overlay. }
    property BottomInset: Integer read FBottomInset write FBottomInset;
    { Assign a callback to every block, including ones added earlier. }
    procedure SetOnToggle(AValue: TNotifyEvent);
    procedure SetOnChange(AValue: TNotifyEvent);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
  end;

  { The scrolling stream of blocks, sticky to the bottom. }
  TChatStream = class(TWidget)
  private
    FStack: TChatStack;
    FScroll: TScrollContainer;
    FFollow: Boolean;
    FOnToggle: TNotifyEvent;
    FOnChange: TNotifyEvent;
    FBottomInset: Integer;
    procedure SetOnToggle(AValue: TNotifyEvent);
    procedure SetOnChange(AValue: TNotifyEvent);
    procedure SetBottomInset(AValue: Integer);
    procedure ItemChanged(Sender: TObject);
    procedure ItemToggled(Sender: TObject);
  public
    constructor Create(const ATheme: TTheme);
    destructor Destroy; override;
    { Append a block and stick the view to it. }
    function Add(AKind: TChatKind; const ALabel, AText: string): TChatItem;
    procedure Clear;
    function Count: Integer;
    function ItemAt(AIndex: Integer): TChatItem;
    { The newest block, or nil when empty. }
    function Last: TChatItem;
    { Drop and free one block, e.g. the thinking indicator once text arrives. }
    procedure Remove(AItem: TChatItem);
    { Re-stick the view to the newest block. }
    procedure FollowBottom;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
    property OnToggle: TNotifyEvent read FOnToggle write SetOnToggle;
    { Fired when a block's text changes, so the host re-arranges. }
    property OnChange: TNotifyEvent read FOnChange write SetOnChange;
    { Rows at the bottom of the viewport covered by the compose overlay; the
      stream keeps room for them so the last block keeps its pad rows visible. }
    property BottomInset: Integer read FBottomInset write SetBottomInset;
  end;

implementation

const
  { A collapsed thought or tool block shows this many body rows. }
  CollapsedLines = 3;
  { Blank rows kept below the last block, so it does not sit flush against the
    compose overlay. }
  ContentBottomPad = 2;
  Sparkles: array[0..12] of UnicodeString =
    ('∙', '•', '●', '◉', '❂', '✴', '✵', '✶', '✷', '✸', '✹', '✺', '❋');

function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function Rep(const ACh: UnicodeString; ACount: Integer): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to ACount do
    Result := Result + ACh;
end;

{ TChatItem }

constructor TChatItem.Create(AKind: TChatKind; const ALabel, AText: string;
  const ATheme: TTheme);
begin
  inherited Create;
  FKind := AKind;
  FLabel := ALabel;
  FBody := AText;
  FTheme := ATheme;
  FExpanded := (AKind = ckUser) or (AKind = ckAssistant) or
    (AKind = ckError) or (AKind = ckThinking);
  FText := TTextBlock.Create([], wmWord);
  Rebuild;
end;

destructor TChatItem.Destroy;
begin
  FText.Free;
  inherited Destroy;
end;

function TChatItem.BodyAttr: TAttr;
begin
  case FKind of
    ckUser:
      Result := OnBg(FTheme.Text, FTheme.RaisedBg);
    ckTool:
      Result := OnBg(FTheme.Text, FTheme.SunkenBg);
    ckThought:
      Result := FTheme.Muted;
    ckError:
      Result := FTheme.Error;
  else
    Result := FTheme.Text;
  end;
end;

procedure TChatItem.Rebuild;
var
  One: TSpan;
begin
  One := Default(TSpan);
  One.Text := UnicodeString(FBody);
  One.Attr := BodyAttr;
  FText.SetSpans([One]);
end;

procedure TChatItem.SetText(const AText: string);
begin
  if AText = FBody then
    Exit;
  FBody := AText;
  Rebuild;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TChatItem.AppendText(const AText: string);
begin
  if AText = '' then
    Exit;
  FBody := FBody + AText;
  Rebuild;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

function TChatItem.Text: string;
begin
  Result := FBody;
end;

function TChatItem.Inset: Integer;
begin
  if (FKind = ckUser) or ((FKind in [ckThought, ckTool]) and FExpanded) then
    Result := 4
  else if (FKind = ckAssistant) or (FKind = ckError) then
    Result := 1
  else
    Result := 0;
end;

function TChatItem.Boxed: Boolean;
begin
  Result := (FKind = ckUser) or ((FKind in [ckThought, ckTool]) and FExpanded);
end;

procedure TChatItem.BodyRows(AWidth: Integer; out ATextRows, ALines: Integer);
var
  InnerW: Integer;
begin
  InnerW := AWidth - Inset;
  if InnerW < 1 then
    InnerW := 1;
  FText.WrapWidth := InnerW;
  ALines := FText.Measure(Default(TSize)).H;
  if (not FExpanded) and (ALines > CollapsedLines) then
    ATextRows := CollapsedLines
  else
    ATextRows := ALines;
end;

function TChatItem.Measure(const AAvail: TSize): TSize;
var
  TextRows, Lines: Integer;
begin
  Result := Default(TSize);
  Result.W := AAvail.W;
  if AAvail.W < 1 then
    Exit;
  case FKind of
    ckUser:
      begin
        BodyRows(AAvail.W, TextRows, Lines);
        Result.H := TextRows + 2;   { top border, body, heavy bottom }
      end;
    ckAssistant, ckError:
      begin
        BodyRows(AAvail.W, TextRows, Lines);
        Result.H := TextRows;
      end;
    ckThinking:
      Result.H := 1;
    ckThought, ckTool:
      if FExpanded then
      begin
        BodyRows(AAvail.W, TextRows, Lines);
        Result.H := TextRows + 2;   { top border, body, bottom border }
      end
      else
        Result.H := 1;              { collapsed rule line }
  end;
  if Result.H < 1 then
    Result.H := 1;
end;

procedure TChatItem.Arrange(const ABounds: TRect);
var
  TextRows, Lines, InnerW: Integer;
begin
  inherited Arrange(ABounds);
  if Boxed then
  begin
    InnerW := ABounds.W - 4;
    if InnerW < 1 then
      InnerW := 1;
    BodyRows(ABounds.W, TextRows, Lines);
    if TextRows > ABounds.H - 2 then
      TextRows := ABounds.H - 2;
    FText.Arrange(Rc(ABounds.X + 2, ABounds.Y + 1, InnerW, TextRows));
  end
  else
    FText.Arrange(Rc(ABounds.X + Inset, ABounds.Y, ABounds.W - Inset,
      ABounds.H));
end;

procedure TChatItem.Render(const S: ISurface);
var
  L, R, T, B, TextRows, Lines, X, I: Integer;
  InnerW: Integer;
  Border, SurfaceAttr: TAttr;
  Title: UnicodeString;
  RuleCh, MarkCh: UnicodeString;
begin
  if (FBounds.W < 1) or (FBounds.H < 1) then
    Exit;

  case FKind of
    ckAssistant, ckError:
      begin
        FText.Render(S);
        Exit;
      end;
    ckThinking:
      begin
        PutText(S, FBounds.X + 1, FBounds.Y, Sparkles[FSpark], FTheme.Accent);
        PutText(S, FBounds.X + 3, FBounds.Y, 'Thinking', FTheme.Muted);
        Exit;
      end;
  else
    ;
  end;

  L := FBounds.X;
  R := FBounds.X + FBounds.W - 1;
  T := FBounds.Y;
  B := FBounds.Y + FBounds.H - 1;
  BodyRows(FBounds.W, TextRows, Lines);

  if (not FExpanded) and (FKind in [ckThought, ckTool]) then
  begin
    { Both collapse to a thin rule; a tool's is full contrast, so the reasons
      read as a story of the agent's decisions. }
    RuleCh := '─';
    MarkCh := '▼';
  end
  else
  begin
    RuleCh := '';
    MarkCh := '▲';
  end;

  { Collapsed rule line: ' ─ Label ───── ▼ ─', one leading space, running to the
    block's right edge (a space remains before the scrollbar column). }
  if RuleCh <> '' then
  begin
    Title := ' ' + RuleCh + ' ' + UnicodeString(FLabel) + ' ';
    I := FBounds.W - Length(Title) - 5;
    if I < 1 then
      I := 1;
    if FKind = ckTool then
      PutText(S, L, T, Title + Rep(RuleCh, I) + ' ' + MarkCh + ' ' + RuleCh,
        FTheme.Text)
    else
      PutText(S, L, T, Title + Rep(RuleCh, I) + ' ' + MarkCh + ' ' + RuleCh,
        FTheme.Muted);
    Exit;
  end;

  { Boxed kinds. }
  if FKind = ckUser then
  begin
    SurfaceAttr := OnBg(FTheme.Text, FTheme.RaisedBg);
    Border := OnBg(WithStyle(FTheme.Accent, [sfDim]), FTheme.RaisedBg);
  end
  else if FKind = ckTool then
  begin
    SurfaceAttr := OnBg(FTheme.Text, FTheme.SunkenBg);
    Border := OnBg(FTheme.Border, FTheme.SunkenBg);
  end
  else
  begin
    SurfaceAttr := FTheme.Base;
    Border := FTheme.Border;
  end;

  S.FillRect(FBounds, SurfaceAttr);

  if FKind = ckUser then
  begin
    PutCh(S, L, T, '╭', Border);
    PutCh(S, R, T, '╮', Border);
    PutCh(S, L, B, '╰', Border);
    PutCh(S, R, B, '┘', Border);
    for X := L + 1 to R - 1 do
      PutCh(S, X, T, '─', Border);
    for X := L + 1 to R - 1 do
      PutCh(S, X, B, '═', Border);
    for I := T + 1 to B - 1 do
    begin
      PutCh(S, L, I, '│', Border);
      PutCh(S, R, I, '│', Border);
    end;
  end
  else
  begin
    { ┌─ Label ───── ▲ ─┐ }
    InnerW := FBounds.W - 4;
    if InnerW < 1 then
      InnerW := 1;
    Title := '┌─ ' + UnicodeString(FLabel) + ' ';
    I := FBounds.W - Length(Title) - 5;
    if I < 1 then
      I := 1;
    PutText(S, L, T, Title + Rep('─', I) + ' ▲ ─┐', Border);
    PutCh(S, L, B, '└', Border);
    PutCh(S, R, B, '┘', Border);
    for X := L + 1 to R - 1 do
      PutCh(S, X, B, '─', Border);
    for I := T + 1 to B - 1 do
    begin
      PutCh(S, L, I, '│', Border);
      PutCh(S, R, I, '│', Border);
    end;
  end;

  FText.Render(S);
end;

function TChatItem.HandleEvent(const E: TInputEvent): Boolean;
begin
  Result := False;
  if not (FKind in [ckThought, ckTool]) then
    Exit;
  if (E.Kind = ikMouse) and (E.Mouse.Button = mbLeft) and
    (E.Mouse.X >= FBounds.X) and (E.Mouse.Y >= FBounds.Y) and
    (E.Mouse.X < FBounds.X + FBounds.W) and (E.Mouse.Y < FBounds.Y + FBounds.H)
  then
  begin
    FExpanded := not FExpanded;
    if Assigned(FOnToggle) then
      FOnToggle(Self);
    Exit(True);
  end;
end;

function TChatItem.Advance(const ANowMs: Int64): Boolean;
var
  NewSpark: Integer;
begin
  if FKind <> ckThinking then
    Exit(False);
  NewSpark := (ANowMs div 90) mod Length(Sparkles);
  Result := NewSpark <> FSpark;
  FSpark := NewSpark;
end;

function TChatItem.Animating: Boolean;
begin
  Result := FKind = ckThinking;
end;

{ TChatStack }

constructor TChatStack.Create(const ATheme: TTheme);
begin
  inherited Create;
  FTheme := ATheme;
  FGap := 1;
end;

destructor TChatStack.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FItems) do
    FItems[I].Free;
  inherited Destroy;
end;

function TChatStack.Count: Integer;
begin
  Result := Length(FItems);
end;

function TChatStack.ItemAt(AIndex: Integer): TChatItem;
begin
  Result := FItems[AIndex];
end;

function TChatStack.Add(AKind: TChatKind; const ALabel, AText: string): TChatItem;
begin
  SetLength(FItems, Length(FItems) + 1);
  Result := TChatItem.Create(AKind, ALabel, AText, FTheme);
  Result.OnToggle := FOnToggle;
  Result.OnChange := FOnChange;
  FItems[High(FItems)] := Result;
end;

procedure TChatStack.Clear;
var
  I: Integer;
begin
  for I := 0 to High(FItems) do
    FItems[I].Free;
  FItems := nil;
end;

procedure TChatStack.Remove(AItem: TChatItem);
var
  I, J: Integer;
begin
  for I := 0 to High(FItems) do
    if FItems[I] = AItem then
    begin
      FItems[I].Free;
      for J := I to High(FItems) - 1 do
        FItems[J] := FItems[J + 1];
      SetLength(FItems, Length(FItems) - 1);
      Exit;
    end;
end;

procedure TChatStack.SetOnToggle(AValue: TNotifyEvent);
var
  I: Integer;
begin
  FOnToggle := AValue;
  for I := 0 to High(FItems) do
    FItems[I].OnToggle := AValue;
end;

procedure TChatStack.SetOnChange(AValue: TNotifyEvent);
var
  I: Integer;
begin
  FOnChange := AValue;
  for I := 0 to High(FItems) do
    FItems[I].OnChange := AValue;
end;

function TChatStack.Measure(const AAvail: TSize): TSize;
var
  I, H: Integer;
  Avail: TSize;
begin
  Result := Default(TSize);
  Result.W := AAvail.W - 1;   { reserve the scrollbar column }
  if Result.W < 1 then
    Result.W := 1;
  Avail.W := Result.W;
  Avail.H := AAvail.H;
  H := 0;
  for I := 0 to Count - 1 do
  begin
    Inc(H, ItemAt(I).Measure(Avail).H);
    if I < Count - 1 then
      Inc(H, FGap);
  end;
  Result.H := H + ContentBottomPad + FBottomInset;
end;

procedure TChatStack.Arrange(const ABounds: TRect);
var
  I, Y, H: Integer;
  Avail: TSize;
begin
  inherited Arrange(ABounds);
  Avail.W := ABounds.W;
  Avail.H := ABounds.H;
  Y := ABounds.Y;
  for I := 0 to Count - 1 do
  begin
    H := ItemAt(I).Measure(Avail).H;
    { Inset by one column on each side: the panel shows
      border | space | content | space | scrollbar | border. }
    ItemAt(I).Arrange(Rc(ABounds.X + 1, Y, ABounds.W - 2, H));
    Inc(Y, H + FGap);
  end;
end;

procedure TChatStack.Render(const S: ISurface);
var
  I: Integer;
begin
  S.PushClip(FBounds);
  for I := 0 to Count - 1 do
    ItemAt(I).Render(S);
  S.PopClip;
end;

function TChatStack.HandleEvent(const E: TInputEvent): Boolean;
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    if ItemAt(I).HandleEvent(E) then
      Exit(True);
  Result := False;
end;

function TChatStack.Advance(const ANowMs: Int64): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to Count - 1 do
    if ItemAt(I).Advance(ANowMs) then
      Result := True;
end;

function TChatStack.Animating: Boolean;
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    if ItemAt(I).Animating then
      Exit(True);
  Result := False;
end;

{ TChatStream }

constructor TChatStream.Create(const ATheme: TTheme);
begin
  inherited Create;
  FFollow := True;
  FStack := TChatStack.Create(ATheme);
  FScroll := TScrollContainer.Create(FStack, smAuto, smNever);
  { The scrollbar sits in the messages panel's right border column, so its track
    must not be painted: the border reads as the track and only the thumb
    shows. }
  FScroll.TrackVisible := False;
  { Intercept block changes and toggles ourselves, so the host only sees the
    notification and the stream owns the scroll behaviour. }
  FStack.SetOnChange(ItemChanged);
  FStack.SetOnToggle(ItemToggled);
end;

destructor TChatStream.Destroy;
begin
  FScroll.Free;
  inherited Destroy;
end;

function TChatStream.Add(AKind: TChatKind; const ALabel, AText: string): TChatItem;
begin
  Result := FStack.Add(AKind, ALabel, AText);
  FFollow := True;
end;

procedure TChatStream.Clear;
begin
  FStack.Clear;
  FFollow := True;
  FScroll.ScrollY := 0;
end;

procedure TChatStream.Remove(AItem: TChatItem);
begin
  FStack.Remove(AItem);
end;

function TChatStream.Count: Integer;
begin
  Result := FStack.Count;
end;

function TChatStream.ItemAt(AIndex: Integer): TChatItem;
begin
  Result := FStack.ItemAt(AIndex);
end;

function TChatStream.Last: TChatItem;
begin
  if FStack.Count = 0 then
    Exit(nil);
  Result := FStack.ItemAt(FStack.Count - 1);
end;

procedure TChatStream.FollowBottom;
begin
  FFollow := True;
  FScroll.ScrollY := High(Integer);
end;

procedure TChatStream.SetOnToggle(AValue: TNotifyEvent);
begin
  FOnToggle := AValue;
end;

procedure TChatStream.ItemToggled(Sender: TObject);
begin
  { A toggle changes one block's height, not the conversation. Stop following so
    the re-arrange keeps the scroll where it is: the block's top stays on the
    same row, and its body grows or shrinks around that row. }
  FFollow := False;
  if Assigned(FOnToggle) then
    FOnToggle(Self);
end;

procedure TChatStream.SetOnChange(AValue: TNotifyEvent);
begin
  FOnChange := AValue;
end;

procedure TChatStream.SetBottomInset(AValue: Integer);
begin
  if AValue < 0 then
    AValue := 0;
  FBottomInset := AValue;
  FStack.BottomInset := AValue;
end;

procedure TChatStream.ItemChanged(Sender: TObject);
begin
  { Content grew: keep following, but do not yank a reader who scrolled away. }
  if FFollow then
    FScroll.ScrollY := High(Integer);
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

function TChatStream.Measure(const AAvail: TSize): TSize;
begin
  Result := AAvail;
end;

procedure TChatStream.Arrange(const ABounds: TRect);
var
  B: TRect;
begin
  inherited Arrange(ABounds);
  { Bleed one column into the messages panel's right border so the scrollbar
    lands in that border column (the panel has no padding, so the column just
    past the content is the border). }
  B := ABounds;
  Inc(B.W);
  FScroll.Arrange(B);
  if FFollow then
    FScroll.ScrollY := High(Integer);
end;

procedure TChatStream.Render(const S: ISurface);
begin
  FScroll.Render(S);
end;

function TChatStream.HandleEvent(const E: TInputEvent): Boolean;
var
  Before: Integer;
  Scrollish: Boolean;
begin
  Before := FScroll.ScrollY;
  Result := FScroll.HandleEvent(E);
  Scrollish := (E.Kind = ikKey) or
    ((E.Kind = ikMouse) and
    ((E.Mouse.Button = mbWheelUp) or (E.Mouse.Button = mbWheelDown)));
  { A click that reached a block toggled it, which pins the view; only a real
    scroll interaction re-evaluates whether we are following the bottom. }
  if Result and (Scrollish or (FScroll.ScrollY <> Before)) then
    FFollow := FScroll.ScrollY >= FScroll.MaxScrollY;
end;

function TChatStream.Advance(const ANowMs: Int64): Boolean;
begin
  Result := FStack.Advance(ANowMs);
end;

function TChatStream.Animating: Boolean;
begin
  Result := FStack.Animating;
end;

end.
