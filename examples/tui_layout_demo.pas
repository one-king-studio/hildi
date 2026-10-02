program tui_layout_demo;
{ A layout exploration for a personal coding-agent harness.

  Two main columns - file explorer + editor, and the chat column - shown only
  when the terminal is wider than 180 columns. The two halves are a 50/50 split;
  the left half is a fixed 20-column file explorer plus a filling editor. Narrower
  terminals collapse to the chat column alone.

  The chat column follows docs/design/chat_panel_tui.md:
    - user messages: a raised background, a dimmed accent border and a heavy
      bottom edge (the "bubble");
    - assistant messages: plain text on the app background, blank lines between
      paragraphs;
    - thought blocks: collapsed to a dimmed rule, expanded to a dimmed box; the
      whole block is clickable;
    - tool reason/output blocks: collapsed to a heavy rule, expanded to a sunken
      (darker) box with full-contrast text;
    - an animated thinking indicator (a sparkle burst);
    - a scrollbar with a dim track and a brighter thumb (same glyph).
  The input box shares the user bubble's raised background and border, grows with
  the text, and overlays the stream up to 60% of the height. Enter sends;
  Shift+Enter adds a line.

  Keys: Ctrl-C / Ctrl-D quit; Ctrl-B toggles the side panel; Enter send;
  Shift+Enter newline; wheel / Up / Down scroll; click a block to expand it.

  Theme: --theme=dark|light|auto (or HILDEGARD_THEME); auto detects the
  terminal's own background. We always paint our own background.

  Run: make layout-demo }

{$mode delphi}{$H+}{$codepage utf8}

uses
  {$ifdef unix}cthreads, cwstring,{$endif}   // cthreads first; cwstring for Unicode
  SysUtils, Classes,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.text, hildegard.helper.tui.app,
  hildegard.helper.tui.surface.video, hildegard.helper.tui.input.terminal,
  hildegard.helper.tui.theme, hildegard.helper.tui.panel,
  hildegard.helper.tui.list, hildegard.helper.tui.scroll;

const
  WideThreshold = 180;     // two columns appear above this width
  SidebarWidth = 20;       // fixed file-explorer column
  SideWidth = 30;          // chat side panel
  MinChatWidth = 40;
  FooterHeight = 1;
  MaxComposePercent = 60;  // the input box never exceeds this share of the height
  CollapsedLines = 3;
  ContentBottomPad = 2;    // blank rows kept below the last message block
  Sparkles: array[0..12] of UnicodeString =
    ('∙', '•', '●', '◉', '❂', '✴', '✵', '✶', '✷', '✸', '✹', '✺', '❋');

var
  QuitRequested: Boolean = False;

type
  TLineArray = array of UnicodeString;
  TSubmitEvent = procedure(const AText: string) of object;

  { Wraps the root so Ctrl-C/Ctrl-D quit. }
  TQuitShell = class(TSingleChild)
  public
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

  TChatKind = (ckUser, ckAssistant, ckThought, ckTool, ckThinking);

  { One item in the chat stream. }
  TChatItem = class(TWidget)
  private
    FKind: TChatKind;
    FLabel: string;
    FText: TTextBlock;
    FExpanded: Boolean;
    FTheme: TTheme;
    FOnToggle: TNotifyEvent;
    FStartMs: Int64;
    FSpark: Integer;
    function Inset: Integer;
    function BodyAttr: TAttr;
    procedure SetBody(const AText: string);
    procedure BodyRows(AWidth: Integer; out ATextRows, ALines: Integer);
    function Boxed: Boolean;
  public
    constructor Create(AKind: TChatKind; const ALabel, AText: string;
      const ATheme: TTheme);
    destructor Destroy; override;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
    property Expanded: Boolean read FExpanded;
    property OnToggle: TNotifyEvent read FOnToggle write FOnToggle;
  end;

  { A vertical stack of chat items, measured at the available width. }
  TChatStack = class(TWidget)
  private
    FItems: array of TChatItem;
    FTheme: TTheme;
    FGap: Integer;
    function Count: Integer;
    function ItemAt(AIndex: Integer): TChatItem;
  public
    constructor Create(const ATheme: TTheme);
    destructor Destroy; override;
    function Add(AKind: TChatKind; const ALabel, AText: string): TChatItem;
    { Assign the toggle callback to every item (including ones added earlier). }
    procedure SetOnToggle(AValue: TNotifyEvent);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
  end;

  { The scrolling stream of chat items, sticky to the bottom. }
  TChatStream = class(TWidget)
  private
    FStack: TChatStack;
    FScroll: TScrollContainer;
    FFollow: Boolean;
    FOnToggle: TNotifyEvent;
    procedure SetOnToggle(AValue: TNotifyEvent);
  public
    constructor Create(const ATheme: TTheme);
    destructor Destroy; override;
    function Add(AKind: TChatKind; const ALabel, AText: string): TChatItem;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
    property OnToggle: TNotifyEvent read FOnToggle write SetOnToggle;
  end;

  { The input box: a raised, heavy-bordered box that grows with the text. Enter
    sends, Shift+Enter adds a line; the cursor blinks. }
  TComposeBox = class(TWidget)
  private
    FTheme: TTheme;
    FText: UnicodeString;
    FInfo: string;
    FBlinkOn: Boolean;
    FOnSubmit: TSubmitEvent;
    FOnChange: TNotifyEvent;
    procedure Backspace;
    procedure InsertText(const S: UnicodeString);
    procedure Wrap(AWidth: Integer; out ALines: TLineArray);
  public
    constructor Create(const ATheme: TTheme; const AInfo: string);
    procedure Clear;
    function NeededHeight(AWidth: Integer): Integer;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
    property Text: UnicodeString read FText;
    property OnSubmit: TSubmitEvent read FOnSubmit write FOnSubmit;
    { Fired when the text changes, so the app re-arranges (the box grows). }
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  { The chat column: a bordered messages panel with a separate full-width compose
    panel below it (aligned to the messages panel's borders), a CTA line above
    the compose and a status line below it. The compose overlays the messages
    panel as it grows. }
  TChatColumn = class(TWidget)
  private
    FMessages: TPanel;
    FCta: TWidget;
    FCompose: TComposeBox;
    FStatus: TWidget;
  public
    constructor Create(AMessages: TPanel; ACta: TWidget; ACompose: TComposeBox;
      AStatus: TWidget);
    destructor Destroy; override;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
    property Compose: TComposeBox read FCompose;
  end;

  { The responsive layout. }
  TResponsiveLayout = class(TWidget)
  private
    FFiles: TWidget;
    FEditor: TWidget;
    FChat: TWidget;
    FSide: TWidget;
    FShowSide: Boolean;
    procedure PlaceChatColumn(const R: TRect);
    procedure Place(const ABounds: TRect);
  public
    constructor Create(AFiles, AEditor, AChat, ASide: TWidget);
    destructor Destroy; override;
    procedure ToggleSide;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
  end;

  TDemo = class
  private
    FStream: TChatStream;
    FCompose: TComposeBox;
    FApp: TTuiApp;
  public
    constructor Create(AStream: TChatStream; ACompose: TComposeBox);
    procedure SetApp(AApp: TTuiApp);
    procedure OnSubmit(const AText: string);
    procedure OnToggle(Sender: TObject);
  end;

function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function Rep(const ACh: UnicodeString; AN: Integer): UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to AN do
    Result := Result + ACh;
end;

procedure PutCh(const S: ISurface; X, Y: Integer; const ACh: UnicodeString;
  const AAttr: TAttr);
var
  C: TCell;
begin
  C := Default(TCell);
  C.Ch := ACh;
  C.Attr := AAttr;
  S.Put(X, Y, C);
end;

procedure PutText(const S: ISurface; X, Y: Integer; const AText: UnicodeString;
  const AAttr: TAttr);
var
  I: Integer;
begin
  for I := 1 to Length(AText) do
    PutCh(S, X + I - 1, Y, UnicodeString(AText[I]), AAttr);
end;

{ Split text into wrapped display lines at AWidth (greedy, word boundaries). }
procedure WrapText(const AText: UnicodeString; AWidth: Integer;
  out ALines: TLineArray);

  procedure AddLine(const L: UnicodeString);
  begin
    SetLength(ALines, Length(ALines) + 1);
    ALines[High(ALines)] := L;
  end;

  procedure WrapPara(const P: UnicodeString);
  var
    Words: array of UnicodeString;
    I, N: Integer;
    W, Line: UnicodeString;
    function Break(W2: UnicodeString): UnicodeString;
    begin
      while Length(W2) > AWidth do
      begin
        AddLine(Copy(W2, 1, AWidth));
        W2 := Copy(W2, AWidth + 1, MaxInt);
      end;
      Result := W2;
    end;
  begin
    Words := nil;
    N := 0;
    W := '';
    for I := 1 to Length(P) do
      if P[I] = ' ' then
      begin
        SetLength(Words, N + 1);
        Words[N] := W;
        Inc(N);
        W := '';
      end
      else
        W := W + P[I];
    SetLength(Words, N + 1);
    Words[N] := W;
    Line := '';
    for I := 0 to High(Words) do
    begin
      W := Words[I];
      if W = '' then
        Continue;
      if Line = '' then
        Line := Break(W)
      else if Length(Line) + 1 + Length(W) <= AWidth then
        Line := Line + ' ' + W
      else
      begin
        AddLine(Line);
        Line := Break(W);
      end;
    end;
    AddLine(Line);
  end;

var
  Rest, Para: UnicodeString;
  P: Integer;
begin
  ALines := nil;
  if AWidth < 1 then
    AWidth := 1;
  Rest := AText;
  repeat
    P := Pos(#10, Rest);
    if P > 0 then
    begin
      Para := Copy(Rest, 1, P - 1);
      Rest := Copy(Rest, P + 1, MaxInt);
    end
    else
    begin
      Para := Rest;
      Rest := '';
    end;
    WrapPara(Para);
  until Rest = '';
end;

{ TQuitShell }

function TQuitShell.HandleEvent(const E: TInputEvent): Boolean;
begin
  if (E.Kind = ikKey) and (E.Key.Kind = kkChar) and (moCtrl in E.Key.Mods) and
    ((E.Key.Ch = 'c') or (E.Key.Ch = 'd')) then
  begin
    QuitRequested := True;
    Exit(True);
  end;
  Result := inherited HandleEvent(E);
end;

{ TChatItem }

constructor TChatItem.Create(AKind: TChatKind; const ALabel, AText: string;
  const ATheme: TTheme);
begin
  inherited Create;
  FKind := AKind;
  FLabel := ALabel;
  FTheme := ATheme;
  FExpanded := AKind <> ckThought;
  FSpark := 0;
  FStartMs := 0;
  FText := TTextBlock.Create([], wmWord);
  SetBody(AText);
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
  else
    Result := FTheme.Text;
  end;
end;

procedure TChatItem.SetBody(const AText: string);
var
  One: TSpan;
begin
  One := Default(TSpan);
  One.Text := UnicodeString(AText);
  One.Attr := BodyAttr;
  FText.SetSpans([One]);
end;

function TChatItem.Inset: Integer;
begin
  if (FKind = ckUser) or ((FKind in [ckThought, ckTool]) and FExpanded) then
    Result := 4
  else if FKind = ckAssistant then
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
    ckAssistant:
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
    FText.Arrange(Rc(ABounds.X + Inset, ABounds.Y, ABounds.W - Inset, ABounds.H));
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
    ckAssistant:
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

  if (FKind = ckThought) and (not FExpanded) then
  begin
    RuleCh := '─';
    MarkCh := '▼';
  end
  else if (FKind = ckTool) and (not FExpanded) then
  begin
    RuleCh := '═';
    MarkCh := '▼';
  end
  else
  begin
    RuleCh := '';
    MarkCh := '▲';
  end;

  { Collapsed rule line: ' ─ Label ───── ▼ ─', one leading space, running to the
    item's right edge (a space remains before the scrollbar column). }
  if RuleCh <> '' then
  begin
    Title := ' ' + RuleCh + ' ' + UnicodeString(FLabel) + ' ';
    I := FBounds.W - Length(Title) - 5;
    if I < 1 then
      I := 1;
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
    (E.Mouse.X < FBounds.X + FBounds.W) and (E.Mouse.Y < FBounds.Y + FBounds.H) then
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
  FItems[High(FItems)] := Result;
end;

procedure TChatStack.SetOnToggle(AValue: TNotifyEvent);
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    ItemAt(I).OnToggle := AValue;
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
  Result.H := H + ContentBottomPad;
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
  { The scrollbar sits in the messages panel's right border column, so its
    track must not be painted: the border reads as the track and only the thumb
    shows. }
  FScroll.TrackVisible := False;
end;

destructor TChatStream.Destroy;
begin
  FScroll.Free;
  inherited Destroy;
end;

function TChatStream.Add(AKind: TChatKind; const ALabel, AText: string): TChatItem;
begin
  Result := FStack.Add(AKind, ALabel, AText);
  Result.OnToggle := FOnToggle;
  FFollow := True;
end;

procedure TChatStream.SetOnToggle(AValue: TNotifyEvent);
begin
  FOnToggle := AValue;
  FStack.SetOnToggle(AValue);
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
begin
  Result := FScroll.HandleEvent(E);
  if Result then
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

{ TComposeBox }

constructor TComposeBox.Create(const ATheme: TTheme; const AInfo: string);
begin
  inherited Create;
  FTheme := ATheme;
  FInfo := AInfo;
  FText := '';
  FBlinkOn := True;
end;

procedure TComposeBox.Clear;
begin
  FText := '';
end;

procedure TComposeBox.InsertText(const S: UnicodeString);
begin
  FText := FText + S;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TComposeBox.Backspace;
begin
  if Length(FText) > 0 then
  begin
    SetLength(FText, Length(FText) - 1);
    if Assigned(FOnChange) then
      FOnChange(Self);
  end;
end;

procedure TComposeBox.Wrap(AWidth: Integer; out ALines: TLineArray);
begin
  if AWidth < 1 then
    AWidth := 1;
  WrapText(FText, AWidth, ALines);
end;

function TComposeBox.NeededHeight(AWidth: Integer): Integer;
var
  Lines: TLineArray;
begin
  Wrap(AWidth - 4, Lines);
  { Rounded top and bottom borders, the text lines, a blank, and the info line. }
  Result := Length(Lines) + 4;
end;

function TComposeBox.Measure(const AAvail: TSize): TSize;
begin
  Result := Default(TSize);
  Result.W := AAvail.W;
  Result.H := NeededHeight(AAvail.W);
end;

procedure TComposeBox.Arrange(const ABounds: TRect);
begin
  inherited Arrange(ABounds);
end;

procedure TComposeBox.Render(const S: ISurface);
var
  L, R, T, B, I, InnerW, TextRows, First, Col, X: Integer;
  Lines: TLineArray;
  SurfaceAttr, Border, BodyAttr, CursorAttr: TAttr;
begin
  if (FBounds.W < 4) or (FBounds.H < 4) then
    Exit;
  L := FBounds.X;
  R := FBounds.X + FBounds.W - 1;
  T := FBounds.Y;
  B := FBounds.Y + FBounds.H - 1;
  InnerW := FBounds.W - 4;
  if InnerW < 1 then
    InnerW := 1;

  SurfaceAttr := OnBg(FTheme.Text, FTheme.RaisedBg);
  Border := OnBg(WithStyle(FTheme.Accent, [sfDim]), FTheme.RaisedBg);
  BodyAttr := SurfaceAttr;
  CursorAttr := OnBg(WithStyle(FTheme.Accent, [sfBold]), FTheme.RaisedBg);

  S.FillRect(FBounds, SurfaceAttr);

  { Heavy top, single bottom, light sides. }
  PutCh(S, L, T, '╭', Border);
  PutCh(S, R, T, '╮', Border);
  PutCh(S, L, B, '╰', Border);
  PutCh(S, R, B, '╯', Border);
  for X := L + 1 to R - 1 do
  begin
    PutCh(S, X, T, '═', Border);
    PutCh(S, X, B, '─', Border);
  end;
  for I := T + 1 to B - 1 do
  begin
    PutCh(S, L, I, '│', Border);
    PutCh(S, R, I, '│', Border);
  end;

  Wrap(InnerW, Lines);
  TextRows := FBounds.H - 4;
  if TextRows < 1 then
    TextRows := 1;
  First := 0;
  if Length(Lines) > TextRows then
    First := Length(Lines) - TextRows;   { keep the tail (the cursor) visible }

  for I := 0 to TextRows - 1 do
  begin
    if First + I > High(Lines) then
      Break;
    PutText(S, L + 2, T + 1 + I, Lines[First + I], BodyAttr);
  end;

  { Blinking block cursor after the last line's text (which starts at L+2). }
  if FBlinkOn then
  begin
    I := High(Lines) - First;
    if I < 0 then
      I := 0;
    Col := 2 + Length(Lines[High(Lines)]);
    if Col < FBounds.W - 2 then
      PutCh(S, L + Col, T + 1 + I, '█', CursorAttr);
  end;

  { Info line. }
  PutText(S, L + 2, B - 1, UnicodeString(FInfo), OnBg(FTheme.Muted, FTheme.RaisedBg));
end;

function TComposeBox.HandleEvent(const E: TInputEvent): Boolean;
begin
  Result := False;
  if E.Kind <> ikKey then
    Exit;
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
    kkEnter:
      begin
        if moShift in E.Key.Mods then
          InsertText(#10)                 { Shift+Enter: a new line }
        else
        begin
          if Assigned(FOnSubmit) and (Trim(string(FText)) <> '') then
          begin
            FOnSubmit(string(FText));
            Clear;
          end;
        end;
        Exit(True);
      end;
  else
    ;
  end;
end;

function TComposeBox.Advance(const ANowMs: Int64): Boolean;
var
  On2: Boolean;
begin
  On2 := ((ANowMs div 530) mod 2) = 0;
  Result := On2 <> FBlinkOn;
  FBlinkOn := On2;
end;

function TComposeBox.Animating: Boolean;
begin
  Result := True;
end;

{ TChatColumn }

constructor TChatColumn.Create(AMessages: TPanel; ACta: TWidget;
  ACompose: TComposeBox; AStatus: TWidget);
begin
  inherited Create;
  FMessages := AMessages;
  FCta := ACta;
  FCompose := ACompose;
  FStatus := AStatus;
end;

destructor TChatColumn.Destroy;
begin
  FMessages.Free;
  FCta.Free;
  FCompose.Free;
  FStatus.Free;
  inherited Destroy;
end;

function TChatColumn.Measure(const AAvail: TSize): TSize;
begin
  Result := AAvail;
end;

procedure TChatColumn.Arrange(const ABounds: TRect);
var
  MessagesH, ComposeH, MaxH, ComposeY: Integer;
begin
  inherited Arrange(ABounds);
  MessagesH := ABounds.H - 1;   { the status line }
  if MessagesH < 1 then
    MessagesH := 1;

  { The compose is an overlay: it grows upward over the messages panel, which
    keeps its full size, so the message content and its scroll do not reflow. }
  ComposeH := FCompose.NeededHeight(ABounds.W);
  MaxH := (ABounds.H * MaxComposePercent) div 100;
  if ComposeH > MaxH then
    ComposeH := MaxH;
  if ComposeH < 4 then
    ComposeH := 4;
  ComposeY := ABounds.Y + MessagesH - ComposeH;
  if ComposeY < ABounds.Y then
    ComposeY := ABounds.Y;

  FMessages.Arrange(Rc(ABounds.X, ABounds.Y, ABounds.W, MessagesH));
  FStatus.Arrange(Rc(ABounds.X + 1, ABounds.Y + ABounds.H - 1, ABounds.W - 2, 1));
  FCompose.Arrange(Rc(ABounds.X, ComposeY, ABounds.W, ComposeH));
  { The CTA strip sits above the compose, inside the messages panel's borders and
    short of the scrollbar column, so those borders are not overwritten. }
  FCta.Arrange(Rc(ABounds.X + 1, ComposeY - 1, ABounds.W - 3, 1));
end;

procedure TChatColumn.Render(const S: ISurface);
begin
  FMessages.Render(S);
  FCta.Render(S);
  FCompose.Render(S);
  FStatus.Render(S);
end;

function TChatColumn.HandleEvent(const E: TInputEvent): Boolean;
begin
  if FCompose.HandleEvent(E) then
    Exit(True);
  if FMessages.HandleEvent(E) then
    Exit(True);
  if FStatus.HandleEvent(E) then
    Exit(True);
  Result := False;
end;

function TChatColumn.Advance(const ANowMs: Int64): Boolean;
begin
  Result := FCompose.Advance(ANowMs);
  if FMessages.Advance(ANowMs) then
    Result := True;
end;

function TChatColumn.Animating: Boolean;
begin
  Result := FCompose.Animating or FMessages.Animating;
end;

{ TResponsiveLayout }

constructor TResponsiveLayout.Create(AFiles, AEditor, AChat, ASide: TWidget);
begin
  inherited Create;
  FFiles := AFiles;
  FEditor := AEditor;
  FChat := AChat;
  FSide := ASide;
  FShowSide := False;
end;

destructor TResponsiveLayout.Destroy;
begin
  FFiles.Free;
  FEditor.Free;
  FChat.Free;
  FSide.Free;
  inherited Destroy;
end;

procedure TResponsiveLayout.ToggleSide;
begin
  FShowSide := not FShowSide;
  if FBounds.W > 0 then
    Arrange(FBounds);
end;

function TResponsiveLayout.Measure(const AAvail: TSize): TSize;
begin
  Result := AAvail;
end;

procedure TResponsiveLayout.PlaceChatColumn(const R: TRect);
var
  SideW, ChatW: Integer;
  SideR, ChatCol: TRect;
begin
  FSide.Visible := FShowSide and (R.W >= MinChatWidth + SideWidth);
  if FSide.Visible then
  begin
    SideW := SideWidth;
    ChatW := R.W - SideW;
    ChatCol := Rc(R.X, R.Y, ChatW, R.H);
    SideR := Rc(R.X + ChatW, R.Y, SideW, R.H);
  end
  else
  begin
    ChatCol := R;
    SideR := Rc(R.X, R.Y, 0, 0);
  end;
  FChat.Arrange(ChatCol);
  FSide.Arrange(SideR);
end;

procedure TResponsiveLayout.Place(const ABounds: TRect);
var
  Wide: Boolean;
  LeftW, RightW: Integer;
begin
  Wide := ABounds.W > WideThreshold;
  FFiles.Visible := Wide;
  FEditor.Visible := Wide;

  if Wide then
  begin
    LeftW := ABounds.W div 2;
    RightW := ABounds.W - LeftW;
    FFiles.Arrange(Rc(ABounds.X, ABounds.Y, SidebarWidth, ABounds.H));
    FEditor.Arrange(Rc(ABounds.X + SidebarWidth, ABounds.Y,
      LeftW - SidebarWidth, ABounds.H));
    PlaceChatColumn(Rc(ABounds.X + LeftW, ABounds.Y, RightW, ABounds.H));
  end
  else
  begin
    FFiles.Arrange(Rc(ABounds.X, ABounds.Y, 0, 0));
    FEditor.Arrange(Rc(ABounds.X, ABounds.Y, 0, 0));
    PlaceChatColumn(ABounds);
  end;
end;

procedure TResponsiveLayout.Arrange(const ABounds: TRect);
begin
  inherited Arrange(ABounds);
  Place(ABounds);
end;

procedure TResponsiveLayout.Render(const S: ISurface);
begin
  S.PushClip(FBounds);
  if FFiles.Visible then
    FFiles.Render(S);
  if FEditor.Visible then
    FEditor.Render(S);
  if FChat.Visible then
    FChat.Render(S);
  if FSide.Visible then
    FSide.Render(S);
  S.PopClip;
end;

function TResponsiveLayout.HandleEvent(const E: TInputEvent): Boolean;
begin
  if (E.Kind = ikKey) and (E.Key.Kind = kkChar) and (moCtrl in E.Key.Mods) and
    (E.Key.Ch = 'b') then
  begin
    ToggleSide;
    Exit(True);
  end;
  if FFiles.Visible and FFiles.HandleEvent(E) then
    Exit(True);
  if FEditor.Visible and FEditor.HandleEvent(E) then
    Exit(True);
  if FChat.Visible and FChat.HandleEvent(E) then
    Exit(True);
  if FSide.Visible and FSide.HandleEvent(E) then
    Exit(True);
  Result := False;
end;

function TResponsiveLayout.Advance(const ANowMs: Int64): Boolean;
begin
  Result := False;
  if FFiles.Visible and FFiles.Advance(ANowMs) then
    Result := True;
  if FEditor.Visible and FEditor.Advance(ANowMs) then
    Result := True;
  if FChat.Visible and FChat.Advance(ANowMs) then
    Result := True;
  if FSide.Visible and FSide.Advance(ANowMs) then
    Result := True;
end;

function TResponsiveLayout.Animating: Boolean;
begin
  Result := (FFiles.Visible and FFiles.Animating) or
    (FEditor.Visible and FEditor.Animating) or
    (FChat.Visible and FChat.Animating) or
    (FSide.Visible and FSide.Animating);
end;

{ TDemo }

constructor TDemo.Create(AStream: TChatStream; ACompose: TComposeBox);
begin
  inherited Create;
  FStream := AStream;
  FCompose := ACompose;
end;

procedure TDemo.SetApp(AApp: TTuiApp);
begin
  FApp := AApp;
end;

procedure TDemo.OnSubmit(const AText: string);
begin
  FStream.Add(ckUser, '', AText);
  if FApp <> nil then
    FApp.Invalidate;
end;

procedure TDemo.OnToggle(Sender: TObject);
begin
  if FApp <> nil then
    FApp.Invalidate;
end;

var
  Surface: ISurface;
  InputTerm: TInputSourceTerminal;
  Input: IInputSource;
  Theme: TTheme;
  Files: TListView;
  EditorText, SideText: TTextBlock;
  StatusLeft, StatusRight: TTextBlock;
  Status: TContainer;
  CtaText: TTextBlock;
  Cta: TPanel;
  ChatStream: TChatStream;
  Compose: TComposeBox;
  ChatColumn: TChatColumn;
  MessagesPanel: TPanel;
  FilesPanel, EditorPanel, SidePanel: TPanel;
  Layout: TResponsiveLayout;
  Demo: TDemo;
  App: TTuiApp;
  Style: TBoxStyle;
  Mode: TThemeMode;
  Light: Boolean;

function RequestedThemeMode: TThemeMode;
var
  I: Integer;
  S: string;
begin
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Copy(S, 1, 8) = '--theme=' then
      Exit(ThemeModeFromString(Copy(S, 9, MaxInt)));
    if S = '--dark' then
      Exit(tmDark);
    if S = '--light' then
      Exit(tmLight);
  end;
  Result := ThemeModeFromString(GetEnvironmentVariable('HILDEGARD_THEME'));
end;

function ShouldStop: Boolean;
begin
  Result := QuitRequested or InputTerm.Terminated;
end;

begin
  Surface := TSurfaceVideo.Create;
  InputTerm := TInputSourceTerminal.Create;
  Input := InputTerm;

  Mode := RequestedThemeMode;
  Light := False;
  if Mode = tmAuto then
    Light := InputTerm.DetectLightBackground;
  Theme := SelectTheme(Mode, Light);

  Files := TListView.Create(Theme);
  Files.AddItem('src/');
  Files.AddItem('  hildegard.helper.tui.app.pas');
  Files.AddItem('  hildegard.helper.tui.widget.pas');
  Files.AddItem('  hildegard.helper.tui.text.pas');
  Files.AddItem('  hildegard.helper.tui.panel.pas');
  Files.AddItem('examples/');
  Files.AddItem('  tui_layout_demo.pas');
  Files.AddItem('Makefile');
  Files.AddItem('HANDOFF.md');
  Style := DefaultBoxStyle;
  Style.Title := 'Files';
  FilesPanel := TPanel.Create(Files, Theme, Style);

  EditorText := TTextBlock.Create([], wmNone);
  EditorText.SetText(
    'unit hildegard.helper.tui.app;' + #10 +
    '' + #10 +
    'procedure TTuiApp.Tick(const ANowMs: Int64);' + #10 +
    'begin' + #10 +
    '  if FStop then Exit;' + #10 +
    '  FNowMs := ANowMs;' + #10 +
    '  FLastTickMs := ANowMs;' + #10 +
    '  if AdvanceTree(ANowMs) or FLayoutDirty then' + #10 +
    '    Present;' + #10 +
    'end;', Theme.Text);
  Style.Title := 'Editor';
  EditorPanel := TPanel.Create(EditorText, Theme, Style);

  ChatStream := TChatStream.Create(Theme);
  ChatStream.Add(ckUser, '',
    'This is the user''s message. It should be rendered with a slightly lighter ' +
    'background to distinguish it from the rest of the content. Make the border ' +
    'be a dimmed accent color to not make it too distracting.');
  ChatStream.Add(ckThought, 'Thought · 8.2s',
    'This is an expanded thought block. The entire block is clickable even when ' +
    'collapsed, and clicking toggles between expanded and collapsed. The borders ' +
    'and text in this block are rendered with a dimmed color on the default ' +
    'background.');
  ChatStream.Add(ckAssistant, '',
    'Assistant message between thoughts.');
  ChatStream.Add(ckTool, 'Reason for tool call',
    '$ ls .' + #10 + '' + #10 +
    'AGENTS.md  Makefile   deps       examples   src' + #10 +
    'this entire block is a darker color with full contrast text');
  ChatStream.Add(ckAssistant, '',
    'Final assistant message. The scrollbar is the same character but rendered ' +
    'in different colors: a darker track and a lighter thumb.' + #10 + '' + #10 +
    'A multi-paragraph response simply applies a gap between paragraphs.');
  ChatStream.Add(ckThinking, '', '');

  Compose := TComposeBox.Create(Theme, 'Hildegard · Model v1 Fireworks · low');

  { The messages panel: a rounded, bordered panel that keeps its full size while
    the compose overlays it. }
  Style := DefaultBoxStyle;
  Style.Title := '';
  Style.Rounded := True;
  Style.Padding := 0;
  MessagesPanel := TPanel.Create(ChatStream, Theme, Style);

  { A CTA/stats line above the compose: a filled strip inside the messages
    panel's borders (border off, no padding, so it paints its own background). }
  CtaText := TTextBlock.Create([], wmNone);
  CtaText.SetText(' ↵ send   ⇧↵ newline   click a block to expand', Theme.Muted);
  Style := DefaultBoxStyle;
  Style.Title := '';
  Style.Border := False;
  Style.Padding := 0;
  Cta := TPanel.Create(CtaText, Theme, Style);

  { The status line below the compose. }
  StatusLeft := TTextBlock.Create([], wmNone);
  StatusLeft.SetText(GetCurrentDir, Theme.Muted);
  StatusRight := TTextBlock.Create([], wmNone);
  StatusRight.SetText('ctrl+p commands  ctrl+b sidebar  ctrl+/ help', Theme.Muted);
  Status := TContainer.Create([Auto, Fill(1), Auto], [Fixed(1)]);
  Status.Add(StatusLeft, 0, 0);
  Status.Add(StatusRight, 2, 0);

  ChatColumn := TChatColumn.Create(MessagesPanel, Cta, Compose, Status);

  SideText := TTextBlock.Create([], wmNone);
  SideText.SetText(
    'Tools' + #10 + '' + #10 +
    '  read_file      idle' + #10 +
    '  write_file     idle' + #10 +
    '  run_command    idle' + #10 +
    '  grep           idle' + #10 + '' + #10 +
    'Context' + #10 + '' + #10 +
    '  workspace  hildegard-helper' + #10 +
    '  model      fireworks' + #10 +
    '  session    (in memory)', Theme.Muted);
  Style := DefaultBoxStyle;
  Style.Title := 'Tools';
  SidePanel := TPanel.Create(SideText, Theme, Style);

  Demo := TDemo.Create(ChatStream, Compose);
  ChatStream.OnToggle := Demo.OnToggle;
  Compose.OnSubmit := Demo.OnSubmit;
  Compose.OnChange := Demo.OnToggle;

  Layout := TResponsiveLayout.Create(FilesPanel, EditorPanel, ChatColumn,
    SidePanel);

  App := TTuiApp.Create(Surface, Input, TQuitShell.Create(Layout));
  App.ScreenBg := Theme.Bg;
  Demo.SetApp(App);
  try
    App.Run(@ShouldStop);
  finally
    App.Free;
    Demo.Free;
    Input := nil;
    Surface := nil;
  end;
end.
