unit TestTUIPerf;
{ Deterministic performance tests for the TUI toolkit.

  These assert *work* (changed cells, Arrange calls), never wall-clock time, so
  they cannot flake on a loaded machine and belong in `make check`. Wall-clock
  budgets live in the benchmark (`examples/tui_bench.pas`, `make bench`). }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  TUIBase, TUIInput,
  TUISurface, TUIWidget,
  TUIWidgetsText, TUIWidgetsScroll,
  TUITheme, TUIWidgetsChat,
  TUIApp;

type
  TPerfSpy = class(TWidget)
  private
    FW, FH: Integer;
    FMarker: UnicodeString;
  public
    ArrangeCalls: Integer;
    constructor Create(AW, AH: Integer; const AMarker: UnicodeString = '#');
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
  end;

  TTuiPerfTest = class(TTestCase)
  private
    function Rc(AX, AY, AW, AH: Integer): TRect;
    function SpanOf(const AText: UnicodeString): TSpan;
  published
    procedure TestFirstFrameChangesAllCells;
    procedure TestUnchangedFrameChangesZeroCells;
    procedure TestOneLineAppendChangesOnlyItsRow;
    procedure TestScrollChangesOnlyViewportRows;
    procedure TestLayoutRunsOnlyWhenDirty;
    procedure TestLargeBlockLayoutIsCachedOnce;
    procedure TestScrolledBlockDrawsOnlyTheViewport;
    procedure TestScrolledBlockRendersTheVisibleRows;
    procedure TestScrolledChatDrawsOnlyVisibleBlocks;
    procedure TestScrollingDoesNotRemeasureBlocks;
    procedure TestScrollingDoesNotRebuildTheLayout;
    procedure TestModalToggleChangesOnlyOverlayAndDimmedRegion;
  end;

implementation

constructor TPerfSpy.Create(AW, AH: Integer; const AMarker: UnicodeString);
begin
  inherited Create;
  FW := AW;
  FH := AH;
  FMarker := AMarker;
end;

function TPerfSpy.Measure(const AAvail: TSize): TSize;
begin
  Result := Default(TSize);
  Result.W := FW;
  Result.H := FH;
end;

procedure TPerfSpy.Arrange(const ABounds: TRect);
begin
  inherited Arrange(ABounds);
  Inc(ArrangeCalls);
end;

procedure TPerfSpy.Render(const S: ISurface);
var
  X, Y: Integer;
  C: TCell;
begin
  C := Default(TCell);
  C.Ch := FMarker;
  C.Attr := DefaultAttr;
  for Y := 0 to FBounds.H - 1 do
    for X := 0 to FBounds.W - 1 do
      S.Put(FBounds.X + X, FBounds.Y + Y, C);
end;

function TTuiPerfTest.Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function TTuiPerfTest.SpanOf(const AText: UnicodeString): TSpan;
begin
  Result := Default(TSpan);
  Result.Text := AText;
  Result.Attr := DefaultAttr;
end;

procedure TTuiPerfTest.TestFirstFrameChangesAllCells;
var
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(20, 6);
  try
    S.Clear(DefaultAttr);
    S.Flush;
    AssertEquals('first frame paints every cell', 20 * 6,
      S.LastFrameChangedCells);
  finally
    S.Free;
  end;
end;

procedure TTuiPerfTest.TestUnchangedFrameChangesZeroCells;
var
  S: TSurfaceMemory;
  Src: TInputSourceScripted;
  App: TTuiApp;
begin
  S := TSurfaceMemory.Create(20, 6);
  Src := TInputSourceScripted.Create;
  App := TTuiApp.Create(S, Src, TPerfSpy.Create(20, 6, 'B'));
  try
    App.Step;
    App.Step;
    AssertEquals('a static frame changes nothing', 0,
      S.LastFrameChangedCells);
  finally
    App.Free;
  end;
end;

procedure TTuiPerfTest.TestOneLineAppendChangesOnlyItsRow;
var
  S: TSurfaceMemory;
  Block: TTextBlock;
  Scroll: TScrollContainer;
begin
  S := TSurfaceMemory.Create(20, 6);
  try
    Block := TTextBlock.Create([SpanOf('line0')], wmNone);
    Scroll := TScrollContainer.Create(Block, smNever, smNever);
    try
      Scroll.Arrange(Rc(0, 0, 20, 6));
      S.Clear(DefaultAttr);
      Scroll.Render(S);
      S.Flush;

      Block.SetText('line0'#10'line1', DefaultAttr);
      Scroll.Arrange(Rc(0, 0, 20, 6));
      S.Clear(DefaultAttr);
      Scroll.Render(S);
      S.Flush;

      AssertTrue('append changes at most one row',
        S.LastFrameChangedCells <= 20);
      AssertTrue('append changed something', S.LastFrameChangedCells > 0);
    finally
      Scroll.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiPerfTest.TestLargeBlockLayoutIsCachedOnce;
var
  S: TSurfaceMemory;
  Block: TTextBlock;
  Text: string;
  I, After: Integer;
  Sz: TSize;
begin
  Text := '';
  for I := 1 to 500 do
    Text := Text + 'line ' + IntToStr(I) + ' of a large tool result' + #10;

  S := TSurfaceMemory.Create(60, 20);
  try
    Block := TTextBlock.Create([SpanOf(UnicodeString(Text))], wmWord);
    try
      Block.WrapWidth := 56;
      Block.Arrange(Rc(0, 0, 56, 20));
      Sz := Default(TSize);
      Sz.W := 56;
      Sz.H := 20;
      { Warm the cache. }
      Block.Measure(Sz);
      Block.Render(S);
      After := Block.LayoutBuilds;

      { Twenty more measures and renders must not rebuild the layout: a large
        block was previously re-wrapped on every frame. }
      for I := 1 to 20 do
      begin
        Block.Measure(Sz);
        Block.Render(S);
      end;
      AssertEquals('layout built once, not per frame', After,
        Block.LayoutBuilds);
    finally
      Block.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiPerfTest.TestScrolledBlockDrawsOnlyTheViewport;
var
  S: TSurfaceMemory;
  Block: TTextBlock;
  Scroll: TScrollContainer;
  Text: string;
  I: Integer;
begin
  Text := '';
  for I := 1 to 1000 do
  begin
    if I > 0 then
      Text := Text + #10;
    Text := Text + 'row' + IntToStr(I);
  end;

  S := TSurfaceMemory.Create(20, 6);
  try
    Block := TTextBlock.Create([SpanOf(UnicodeString(Text))], wmNone);
    Scroll := TScrollContainer.Create(Block, smNever, smNever);
    try
      Scroll.Arrange(Rc(0, 0, 20, 6));
      Scroll.ScrollTo(0, 900);
      S.Clear(DefaultAttr);
      S.ResetFrameStats;
      Scroll.Render(S);
      { Only the six visible rows are drawn, not the thousand in the block. }
      AssertTrue('draws bounded by the viewport, not the block',
        S.PutCount <= 20 * 6);
    finally
      Scroll.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiPerfTest.TestScrolledBlockRendersTheVisibleRows;
var
  S: TSurfaceMemory;
  Block: TTextBlock;
  Scroll: TScrollContainer;
  Text: string;
  I: Integer;
begin
  Text := 'row1';
  for I := 2 to 1000 do
    Text := Text + #10 + 'row' + IntToStr(I);

  S := TSurfaceMemory.Create(20, 6);
  try
    Block := TTextBlock.Create([SpanOf(UnicodeString(Text))], wmNone);
    Scroll := TScrollContainer.Create(Block, smNever, smNever);
    try
      Scroll.Arrange(Rc(0, 0, 20, 6));
      Scroll.ScrollTo(0, 900);
      S.Clear(DefaultAttr);
      Scroll.Render(S);
      { The culled render still draws the rows the clip shows: scrolled to 900,
        surface row 0 is the block's row 900 ('row901'). }
      AssertEquals('first visible row', 'row901', string(S.RowText(0, 0, 6)));
      AssertEquals('last visible row', 'row906', string(S.RowText(5, 0, 6)));
    finally
      Scroll.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiPerfTest.TestScrolledChatDrawsOnlyVisibleBlocks;
var
  S: TSurfaceMemory;
  Stream: TChatStream;
  Text: string;
  I: Integer;
begin
  Text := 'one' + #10 + 'two' + #10 + 'three';
  S := TSurfaceMemory.Create(40, 12);
  try
    Stream := TChatStream.Create(DarkTheme);
    try
      for I := 1 to 50 do
        Stream.Add(ckAssistant, '', Text);
      { Add follows the bottom, so most of the fifty blocks are above the
        viewport. }
      Stream.Arrange(Rc(0, 0, 40, 12));
      S.Clear(DefaultAttr);
      S.ResetFrameStats;
      Stream.Render(S);
      AssertTrue('draws bounded by the viewport, not the block count',
        S.PutCount < 40 * 12);
    finally
      Stream.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiPerfTest.TestScrollingDoesNotRemeasureBlocks;
var
  S: TSurfaceMemory;
  Stream: TChatStream;
  Item: TChatItem;
  Text: string;
  I, Before: Integer;
  Ev: TInputEvent;
begin
  Text := '';
  for I := 1 to 200 do
    Text := Text + 'line ' + IntToStr(I) + ' of a large tool result' + #10;

  S := TSurfaceMemory.Create(40, 12);
  try
    Stream := TChatStream.Create(DarkTheme);
    try
      for I := 1 to 4 do
      begin
        Item := Stream.Add(ckTool, 'reason ' + IntToStr(I), Text);
        Item.Expanded := True;
      end;
      Stream.Arrange(Rc(0, 0, 40, 12));
      S.Clear(DefaultAttr);
      Stream.Render(S);
      Before := Item.MeasureCount;

      Ev := Default(TInputEvent);
      Ev.Kind := ikMouse;
      Ev.Mouse.Button := mbWheelUp;
      Ev.Mouse.X := 5;
      Ev.Mouse.Y := 5;
      for I := 1 to 10 do
      begin
        Stream.HandleEvent(Ev);
        Stream.Arrange(Rc(0, 0, 40, 12));
        S.Clear(DefaultAttr);
        Stream.Render(S);
      end;
      AssertEquals('a scroll does not re-measure unchanged blocks', Before,
        Item.MeasureCount);
    finally
      Stream.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiPerfTest.TestScrollingDoesNotRebuildTheLayout;
var
  S: TSurfaceMemory;
  Stream: TChatStream;
  Item: TChatItem;
  Text: string;
  I, Before: Integer;
  Ev: TInputEvent;
begin
  Text := '';
  for I := 1 to 200 do
    Text := Text + 'line ' + IntToStr(I) + ' of a large tool result' + #10;

  S := TSurfaceMemory.Create(40, 12);
  try
    Stream := TChatStream.Create(DarkTheme);
    try
      for I := 1 to 4 do
      begin
        Item := Stream.Add(ckTool, 'reason ' + IntToStr(I), Text);
        Item.Expanded := True;
      end;
      Stream.Arrange(Rc(0, 0, 40, 12));
      S.Clear(DefaultAttr);
      Stream.Render(S);
      Before := Item.LayoutBuilds;

      Ev := Default(TInputEvent);
      Ev.Kind := ikMouse;
      Ev.Mouse.Button := mbWheelDown;
      Ev.Mouse.X := 5;
      Ev.Mouse.Y := 5;
      for I := 1 to 10 do
      begin
        Stream.HandleEvent(Ev);
        Stream.Arrange(Rc(0, 0, 40, 12));
        S.Clear(DefaultAttr);
        Stream.Render(S);
      end;
      AssertEquals('scroll does not rebuild the text layout', Before,
        Item.LayoutBuilds);
    finally
      Stream.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiPerfTest.TestScrollChangesOnlyViewportRows;
var
  S: TSurfaceMemory;
  Scroll: TScrollContainer;
  Block: TTextBlock;
  Text: string;
  I: Integer;
begin
  Text := '';
  for I := 0 to 99 do
  begin
    if I > 0 then
      Text := Text + #10;
    Text := Text + 'r' + IntToStr(I);
  end;

  S := TSurfaceMemory.Create(20, 6);
  try
    Block := TTextBlock.Create([SpanOf(UnicodeString(Text))], wmNone);
    Scroll := TScrollContainer.Create(Block, smNever, smNever);
    try
      Scroll.Arrange(Rc(0, 0, 20, 6));
      S.Clear(DefaultAttr);
      Scroll.Render(S);
      S.Flush;

      Scroll.ScrollBy(0, 1);
      S.Clear(DefaultAttr);
      Scroll.Render(S);
      S.Flush;

      AssertTrue('scroll changes at most the viewport',
        S.LastFrameChangedCells <= 20 * 6);
      AssertTrue('scroll changed something', S.LastFrameChangedCells > 0);
    finally
      Scroll.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiPerfTest.TestLayoutRunsOnlyWhenDirty;
var
  S: TSurfaceMemory;
  Src: TInputSourceScripted;
  Spy: TPerfSpy;
  App: TTuiApp;
  Before: Integer;
begin
  S := TSurfaceMemory.Create(20, 6);
  Src := TInputSourceScripted.Create;
  Spy := TPerfSpy.Create(20, 6, 'B');
  App := TTuiApp.Create(S, Src, Spy);
  try
    Before := Spy.ArrangeCalls;
    App.Step;
    App.Step;
    AssertEquals('a Step without input does not re-arrange', Before,
      Spy.ArrangeCalls);
  finally
    App.Free;
  end;
end;

procedure TTuiPerfTest.TestModalToggleChangesOnlyOverlayAndDimmedRegion;
var
  S: TSurfaceMemory;
  Src: TInputSourceScripted;
  App: TTuiApp;
  ModalRoot: TPerfSpy;
begin
  S := TSurfaceMemory.Create(20, 6);
  Src := TInputSourceScripted.Create;
  App := TTuiApp.Create(S, Src, TPerfSpy.Create(20, 6, 'B'));
  try
    App.Step;

    { A modal without dimming changes only the overlay rectangle. }
    ModalRoot := TPerfSpy.Create(2, 1, 'M');
    ModalRoot.Arrange(Rc(0, 0, 2, 1));
    App.PushPlane(TPlane.Create(ModalRoot, True, False));
    App.Step;
    AssertTrue('non-dim modal changes only its overlay',
      S.LastFrameChangedCells <= 2);

    { A dimmed modal adds a faint flag across the dimmed background, so the
      change is bounded by the whole (dimmed) surface; glyphs survive. }
    ModalRoot := TPerfSpy.Create(2, 1, 'M');
    ModalRoot.Arrange(Rc(0, 0, 2, 1));
    App.PushPlane(TPlane.Create(ModalRoot, True, True));
    App.Step;
    AssertTrue('dimmed modal stays within the screen',
      S.LastFrameChangedCells <= 20 * 6);
    AssertEquals('base glyph preserved under dim', 'B', S.CellAt(10, 5).Ch);
    AssertTrue('base cell dimmed', sfDim in S.CellAt(10, 5).Attr.Style);
    AssertEquals('overlay glyph drawn', 'M', S.CellAt(0, 0).Ch);
  finally
    App.Free;
  end;
end;

initialization
  RegisterTest(TTuiPerfTest);
end.
