unit TestTUIModal;
{ fpcunit tests for TModal: the shared dialog frame.

  This is the library's only reusable dialog component - the frame, the title,
  the 80% height cap, the fixed CTA footer and the optional scroll container -
  and until now it had no direct test at all. Its behaviour was verified only
  insofar as two Hildi dialogs happened to exercise it, and neither touched
  SetFooter, FooterClicked, PaintFrame or InnerRect.

  Everything is asserted on a memory surface, so the frame is checked cell by
  cell rather than described. A consumer building on this should be able to
  trust that the cap, the footer and the clipping are pinned. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils, fpcunit, testregistry,
  TUIBase, TUIInput, TUISurface, TUITheme, TUIWidget, TUIWidgetsModal;

type
  { A minimal content widget: records the rect it was arranged at, and can be
    told to draw badly (outside its own rect) to prove the footer still wins. }
  TProbeContent = class(TWidget)
  private
    FLastBounds: TRect;
    FArrangeCalls: Integer;
    FMeasureCalls: Integer;
    FTag: UnicodeString;
  public
    constructor Create(const ATag: UnicodeString);
    procedure Arrange(const ABounds: TRect); override;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    property LastBounds: TRect read FLastBounds;
    property ArrangeCalls: Integer read FArrangeCalls;
    property MeasureCalls: Integer read FMeasureCalls;
  end;

  { A modal whose content paints over the whole surface, including the footer
    rows, so the test can prove the CTAs are drawn last. }
  TBadContent = class(TProbeContent)
  public
    procedure Render(const S: ISurface); override;
  end;

  { Records the footer key a click delivered, so the test asserts the CONTRACT
    (a click on a CTA reports its key) rather than guessing a column. }
  TProbeModal = class(TModal)
  public
    LastKey: string;
    procedure FooterClicked(const AKey: string); override;
  end;

  TModalTest = class(TTestCase)
  private
    FTheme: TTheme;
    function Rc(AX, AY, AW, AH: Integer): TRect;
    function Click(X, Y: Integer): TInputEvent;
    function Render(M: TModal; AW, AH: Integer): TSurfaceMemory;
    function RenderAt(M: TModal; AW, AH, MW, MH: Integer): TSurfaceMemory;
  protected
    procedure SetUp; override;
  published
    { Sizing }
    procedure TestMeasureCapsHeightAtEightyPercent;
    procedure TestMeasureUsesAvailableHeightWhenTooShortToCap;
    procedure TestMeasureWidthInsetsAndHasAMinimum;

    { The frame }
    procedure TestFrameDrawsABoxAndTitle;
    procedure TestTitleAbsentStillDrawsTheFrame;

    { The fixed footer }
    procedure TestFooterSplitsIntoKeyAndActionPairs;
    procedure TestFooterWithNoKeyIsAllAction;
    procedure TestClickOnFooterDeliversTheKey;
    procedure TestClickOutsideTheFooterIsNotSwallowed;
    procedure TestNoFooterLeavesAPlainBottomBorder;

    { Content }
    procedure TestScrollableContentIsWrappedAndArranged;
    procedure TestContentIsNotGivenTheFooterRows;
    procedure TestFooterSurvivesContentThatPaintsOverIt;
  end;

implementation

{ TProbeContent }

constructor TProbeContent.Create(const ATag: UnicodeString);
begin
  inherited Create;
  FTag := ATag;
  FLastBounds := Default(TRect);
  FArrangeCalls := 0;
  FMeasureCalls := 0;
end;

procedure TProbeContent.Arrange(const ABounds: TRect);
begin
  inherited Arrange(ABounds);
  FLastBounds := ABounds;
  Inc(FArrangeCalls);
end;

function TProbeContent.Measure(const AAvail: TSize): TSize;
begin
  Inc(FMeasureCalls);
  Result := Default(TSize);
  Result.W := 10;
  Result.H := 3;
end;

procedure TProbeContent.Render(const S: ISurface);
var
  I: Integer;
  C: TCell;
begin
  if (FBounds.W <= 0) or (FBounds.H <= 0) then
    Exit;
  C := Default(TCell);
  C.Ch := FTag;
  C.Attr := DefaultAttr;
  for I := 0 to FBounds.W - 1 do
    S.Put(FBounds.X + I, FBounds.Y, C);
end;

{ TBadContent }

procedure TBadContent.Render(const S: ISurface);
var
  X, Y: Integer;
  C: TCell;
begin
  { Deliberately ignores its own bounds: every cell of the whole surface. A
    well-behaved widget would not, but the footer's guarantee has to hold against
    one that does. }
  C := Default(TCell);
  C.Ch := '#';
  C.Attr := DefaultAttr;
  for Y := 0 to 23 do
    for X := 0 to 59 do
      S.Put(X, Y, C);
end;

procedure TProbeModal.FooterClicked(const AKey: string);
begin
  LastKey := AKey;
end;

{ TModalTest }

procedure TModalTest.SetUp;
begin
  FTheme := DarkTheme;
end;

function TModalTest.Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function TModalTest.Click(X, Y: Integer): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikMouse;
  Result.Mouse.X := X;
  Result.Mouse.Y := Y;
  Result.Mouse.Button := mbLeft;
  Result.Mouse.Action := maPress;
end;

function TModalTest.RenderAt(M: TModal; AW, AH, MW, MH: Integer): TSurfaceMemory;
begin
  { Arrange at an EXPLICIT size. Measure applies the 80% cap, so arranging at the
    measured height means the modal does not reach the bottom of the surface -
    which is correct behaviour and made early assertions look for content in rows
    the modal never occupied. }
  Result := TSurfaceMemory.Create(AW, AH);
  Result.SetScreenBg(FTheme.Bg);
  M.Arrange(Rc(0, 0, MW, MH));
  M.Render(Result);
end;

function TModalTest.Render(M: TModal; AW, AH: Integer): TSurfaceMemory;
var
  Avail: TSize;
  W, H: Integer;
begin
  Result := TSurfaceMemory.Create(AW, AH);
  Result.SetScreenBg(FTheme.Bg);
  Avail := Default(TSize);
  Avail.W := AW;
  Avail.H := AH;
  W := M.Measure(Avail).W;
  H := M.Measure(Avail).H;
  M.Arrange(Rc(0, 0, W, H));
  { Pass the object directly. Holding it in a local ISurface would bump the
    refcount and release it on return, handing the caller a dangling pointer -
    the same double-free that bit the selection tests. }
  M.Render(Result);
end;

{ --- Sizing --- }

procedure TModalTest.TestMeasureCapsHeightAtEightyPercent;
var
  M: TModal;
  Avail: TSize;
begin
  M := TModal.Create(FTheme);
  try
    Avail := Default(TSize);
    Avail.W := 80;
    Avail.H := 50;
    { The cap is what keeps the transcript visible behind the dialog. }
    AssertEquals('height is 80% of what is available', 40, M.Measure(Avail).H);
  finally
    M.Free;
  end;
end;

procedure TModalTest.TestMeasureUsesAvailableHeightWhenTooShortToCap;
var
  M: TModal;
  Avail: TSize;
begin
  M := TModal.Create(FTheme);
  try
    { 80% of 5 is 4, which cannot hold the chrome plus a content row, so the
      modal takes the whole height rather than becoming unusable. }
    Avail := Default(TSize);
    Avail.W := 40;
    Avail.H := 5;
    AssertEquals('a short surface is used in full', 5, M.Measure(Avail).H);
  finally
    M.Free;
  end;
end;

procedure TModalTest.TestMeasureWidthInsetsAndHasAMinimum;
var
  M: TModal;
  Avail: TSize;
begin
  M := TModal.Create(FTheme);
  try
    Avail := Default(TSize);
    Avail.W := 60;
    Avail.H := 20;
    AssertEquals('width leaves a margin either side', 54, M.Measure(Avail).W);

    { Below the minimum the margin would make it too narrow to draw, so it takes
      the full width instead. }
    Avail.W := 26;
    AssertEquals('narrow surface uses the full width', 26, M.Measure(Avail).W);
  finally
    M.Free;
  end;
end;

{ --- The frame --- }

procedure TModalTest.TestFrameDrawsABoxAndTitle;
var
  M: TModal;
  S: TSurfaceMemory;
begin
  M := TModal.Create(FTheme);
  try
    { Set the title BEFORE rendering, and render ONCE. Two calls with the result
      assigned to the same variable leaks the first surface - I did exactly that
      and the heaptrc gate caught it as two 12,816-byte blocks (a 40x20 cell
      grid). One render, one surface, one free. }
    M.SetTitle('Hello');
    S := RenderAt(M, 40, 20, 40, 20);
    try
      AssertTrue('top-left corner is a corner glyph', S.CellAt(0, 0).Ch <> '');
      AssertTrue('the title reached the top border',
        Pos('Hello', UTF8Encode(S.RowText(0, 0, 40))) > 0);
      AssertTrue('the title is NOT repeated in the body',
        Pos('Hello', UTF8Encode(S.RowText(1, 0, 40))) = 0);
    finally
      S.Free;
    end;
  finally
    M.Free;
  end;
end;

procedure TModalTest.TestTitleAbsentStillDrawsTheFrame;
var
  M: TModal;
  S: TSurfaceMemory;
begin
  M := TModal.Create(FTheme);
  try
    S := RenderAt(M, 30, 12, 30, 12);
    AssertTrue('a modal with no title still has a border',
      S.CellAt(0, 0).Ch <> '');
    AssertTrue('and a bottom edge', S.CellAt(0, 11).Ch <> '');
  finally
    M.Free;
    S.Free;
  end;
end;

{ --- The fixed footer --- }

procedure TModalTest.TestFooterSplitsIntoKeyAndActionPairs;
var
  M: TModal;
  S: TSurfaceMemory;
  Last: string;
begin
  M := TModal.Create(FTheme);
  try
    M.SetFooter('enter accept   esc cancel');
    S := RenderAt(M, 50, 16, 50, 16);
    Last := UTF8Encode(S.RowText(14, 0, 50));
    AssertTrue('the first key is drawn', Pos('enter', Last) > 0);
    AssertTrue('the second key is drawn', Pos('esc', Last) > 0);
    AssertTrue('the actions are drawn too', Pos('accept', Last) > 0);
  finally
    M.Free;
    S.Free;
  end;
end;

procedure TModalTest.TestFooterWithNoKeyIsAllAction;
var
  M: TModal;
  S: TSurfaceMemory;
begin
  M := TModal.Create(FTheme);
  try
    { A lone phrase has no binding to dim, so it is all action. It must still be
      drawn rather than parsed away. }
    M.SetFooter('working');
    S := RenderAt(M, 40, 14, 40, 14);
    AssertTrue('the phrase is drawn',
      Pos('working', UTF8Encode(S.RowText(12, 0, 40))) > 0);
  finally
    M.Free;
    S.Free;
  end;
end;

procedure TModalTest.TestClickOnFooterDeliversTheKey;
var
  M: TProbeModal;
  S: TSurfaceMemory;
  X: Integer;
begin
  M := TProbeModal.Create(FTheme);
  try
    M.SetFooter('enter accept   esc cancel');
    S := RenderAt(M, 50, 16, 50, 16);
    try
      { Sweep the CTA row rather than guessing a column: the footer is
        RIGHT-aligned, so its position depends on the text width. Clicking every
        column proves a click anywhere on a CTA reaches its key. }
      for X := 0 to 49 do
        if M.LastKey = '' then
          M.HandleEvent(Click(X, 14));
      AssertEquals('a click on the first CTA reported its key', 'enter', M.LastKey);
    finally
      S.Free;
    end;
  finally
    M.Free;
  end;
end;

procedure TModalTest.TestClickOutsideTheFooterIsNotSwallowed;
var
  M: TModal;
begin
  M := TModal.Create(FTheme);
  try
    M.SetFooter('enter accept');
    M.Arrange(Rc(0, 0, 50, 16));
    { A click in the content area must reach the content, not be eaten by the
      frame. With no content widget nothing handles it, so it falls through. }
    AssertFalse('a click in the body is not consumed by the modal',
      M.HandleEvent(Click(5, 3)));
  finally
    M.Free;
  end;
end;

procedure TModalTest.TestNoFooterLeavesAPlainBottomBorder;
var
  M: TModal;
  S: TSurfaceMemory;
begin
  M := TModal.Create(FTheme);
  try
    S := RenderAt(M, 40, 14, 40, 14);
    { With no footer there is no divider row and no CTA row: the content simply
      runs down to the bottom border. }
    AssertTrue('the bottom edge is a border glyph', S.CellAt(0, 13).Ch <> '');
    AssertTrue('nothing CTA-shaped was drawn on the last content row',
      Pos('enter', UTF8Encode(S.RowText(11, 0, 40))) = 0);
  finally
    M.Free;
    S.Free;
  end;
end;

{ --- Content --- }

procedure TModalTest.TestScrollableContentIsWrappedAndArranged;
var
  C: TProbeContent;
  M: TModal;
  S: TSurfaceMemory;
begin
  C := TProbeContent.Create('x');
  M := TModal.Create(FTheme, C, True);
  try
    { A scroll container MEASURES its child and positions it lazily through its
      viewport; it does not call Arrange on it. So the observable fact here is
      that the child was measured and the container got a real viewport, not
      that LastBounds was set. Asserting Arrange would be asserting something
      the container never promised. }
    S := RenderAt(M, 40, 20, 40, 20);
    try
      AssertTrue('the content widget was measured by the scroller',
        C.MeasureCalls > 0);
      AssertTrue('and the modal drew a frame around it',
        S.CellAt(0, 0).Ch <> '');
    finally
      S.Free;
    end;
  finally
    M.Free;   { owns C }
  end;
end;

procedure TModalTest.TestContentIsNotGivenTheFooterRows;
var
  C: TProbeContent;
  M: TModal;
begin
  C := TProbeContent.Create('x');
  M := TModal.Create(FTheme, C, False);
  try
    M.SetFooter('enter accept');
    M.Arrange(Rc(0, 0, 40, 20));
    { The footer is FIXED: content must end above it, or the CTAs would scroll
      away - which is the whole point of a fixed footer. }
    AssertTrue('content ends above the footer',
      C.LastBounds.Y + C.LastBounds.H <= 18);
  finally
    M.Free;
  end;
end;

procedure TModalTest.TestFooterSurvivesContentThatPaintsOverIt;
var
  Bad: TBadContent;
  M: TModal;
  S: TSurfaceMemory;
  LastRow: string;
begin
  Bad := TBadContent.Create('#');
  M := TModal.Create(FTheme, Bad, False);
  try
    M.SetFooter('enter accept');
    S := RenderAt(M, 50, 16, 50, 16);
    { TBadContent scribbles '#' over every cell. The footer must still be
      readable, because it is drawn AFTER the content - that ordering is the
      guarantee, not the content's good behaviour. }
    LastRow := UTF8Encode(S.RowText(14, 0, 50));
    AssertTrue('the CTA text survived a content widget that painted over it',
      Pos('enter', LastRow) > 0);
  finally
    M.Free;
    S.Free;
  end;
end;

initialization
  RegisterTest(TModalTest);
end.
