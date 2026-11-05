unit TestTUIForwarding;
{ A gate for the protocol every composite must forward.

  TWidget has grown methods over time - HitTest, CopySelection - and each new one
  became a thing every composite had to remember to forward. Four forgot, and
  each was found by an operator in a terminal rather than by any test:

    TMarkdownView      had no HandleEvent at all
    TChatItem          exited early, so prose blocks never delegated
    TSingleChild       (the tree ROOT) never forwarded CopySelection
    TScrollContainer   never forwarded CopySelection

  A unit test on the component cannot see this: the component was correct every
  time, and the container above it was not. So this file tests the CONTAINERS,
  with a probe child that records what reached it.

  The four methods below are the ones a child must receive. Measure and Render
  are layout and paint; HandleEvent is input; CopySelection is the copy walk.
  A composite that does not pass these through has made its child unreachable. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils, fpcunit, testregistry,
  TUIBase, TUIInput, TUISurface, TUITheme, TUIWidget,
  TUIWidgetsPanel, TUIWidgetsScroll, TUIWidgetsModal;

type
  { Records every protocol call that reaches it, so a composite can be asked
    "did you pass this on?" without knowing anything about the composite. }
  TRecordingChild = class(TWidget)
  public
    MeasureCalls: Integer;
    ArrangeCalls: Integer;
    RenderCalls: Integer;
    EventCalls: Integer;
    HitTestCalls: Integer;
    CopyCalls: Integer;
    AdvanceCalls: Integer;
    CopyHandled: Boolean;
    constructor Create;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function HitTest(AX, AY: Integer): Boolean; override;
    function CopySelection(const S: ISurface): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    procedure Reset;
  end;

  TForwardingTest = class(TTestCase)
  private
    FTheme: TTheme;
    function Rc(AX, AY, AW, AH: Integer): TRect;
    function Click(X, Y: Integer): TInputEvent;
  protected
    procedure SetUp; override;
  published
    { The two single-child composites. }
    procedure TestPanelForwardsTheWholeProtocol;
    procedure TestScrollContainerForwardsTheWholeProtocol;

    { The container. }
    procedure TestContainerForwardsTheWholeProtocol;

    { The dialog frame. }
    procedure TestModalForwardsToItsContent;
    procedure TestModalScrollableContentReceivesEvents;
  end;

implementation

{ TRecordingChild }

constructor TRecordingChild.Create;
begin
  inherited Create;
  Reset;
end;

procedure TRecordingChild.Reset;
begin
  MeasureCalls := 0;
  ArrangeCalls := 0;
  RenderCalls := 0;
  EventCalls := 0;
  HitTestCalls := 0;
  CopyCalls := 0;
  AdvanceCalls := 0;
  CopyHandled := False;
end;

function TRecordingChild.Measure(const AAvail: TSize): TSize;
begin
  Inc(MeasureCalls);
  Result := Default(TSize);
  Result.W := 8;
  Result.H := 3;
end;

procedure TRecordingChild.Arrange(const ABounds: TRect);
begin
  inherited Arrange(ABounds);
  Inc(ArrangeCalls);
end;

procedure TRecordingChild.Render(const S: ISurface);
begin
  Inc(RenderCalls);
end;

function TRecordingChild.HandleEvent(const E: TInputEvent): Boolean;
begin
  Inc(EventCalls);
  Result := False;
end;

function TRecordingChild.HitTest(AX, AY: Integer): Boolean;
begin
  Inc(HitTestCalls);
  Result := inherited HitTest(AX, AY);
end;

function TRecordingChild.CopySelection(const S: ISurface): Boolean;
begin
  Inc(CopyCalls);
  Result := CopyHandled;
end;

function TRecordingChild.Advance(const ANowMs: Int64): Boolean;
begin
  Inc(AdvanceCalls);
  Result := False;
end;

{ TForwardingTest }

procedure TForwardingTest.SetUp;
begin
  FTheme := DarkTheme;
end;

function TForwardingTest.Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function TForwardingTest.Click(X, Y: Integer): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikMouse;
  Result.Mouse.X := X;
  Result.Mouse.Y := Y;
  Result.Mouse.Button := mbLeft;
  Result.Mouse.Action := maPress;
end;

procedure TForwardingTest.TestPanelForwardsTheWholeProtocol;
var
  C: TRecordingChild;
  P: TPanel;
  S: TSurfaceMemory;
  Avail: TSize;
begin
  C := TRecordingChild.Create;
  P := TPanel.Create(C, FTheme, Default(TBoxStyle));
  S := TSurfaceMemory.Create(30, 8);
  try
    Avail := Default(TSize);
    Avail.W := 30;
    Avail.H := 8;
    P.Measure(Avail);
    AssertTrue('Measure reached the child', C.MeasureCalls > 0);

    P.Arrange(Rc(0, 0, 30, 8));
    AssertTrue('Arrange reached the child', C.ArrangeCalls > 0);

    P.Render(S);
    AssertTrue('Render reached the child', C.RenderCalls > 0);

    P.HandleEvent(Click(5, 4));
    AssertTrue('HandleEvent reached the child', C.EventCalls > 0);

    P.CopySelection(S);
    AssertTrue('CopySelection reached the child', C.CopyCalls > 0);

    P.Advance(1000);
    AssertTrue('Advance reached the child', C.AdvanceCalls > 0);
  finally
    P.Free;   { owns C }
    S.Free;
  end;
end;

procedure TForwardingTest.TestScrollContainerForwardsTheWholeProtocol;
var
  C: TRecordingChild;
  Sc: TScrollContainer;
  S: TSurfaceMemory;
begin
  C := TRecordingChild.Create;
  Sc := TScrollContainer.Create(C, smNever, smNever);
  S := TSurfaceMemory.Create(20, 6);
  try
    Sc.Arrange(Rc(0, 0, 20, 6));
    { A scroll container MEASURES its child during its own layout pass rather
      than arranging it, so Measure is the forward that matters here. }
    AssertTrue('Measure reached the child', C.MeasureCalls > 0);

    Sc.HandleEvent(Click(3, 3));
    AssertTrue('HandleEvent reached the child', C.EventCalls > 0);

    { This is the one that was missing, and it meant copy never worked through a
      scroller - which is every dialog with content. }
    Sc.CopySelection(S);
    AssertTrue('CopySelection reached the child', C.CopyCalls > 0);
  finally
    Sc.Free;   { owns C }
    S.Free;
  end;
end;

procedure TForwardingTest.TestContainerForwardsTheWholeProtocol;
var
  C: TRecordingChild;
  K: TContainer;
  S: TSurfaceMemory;
  Avail: TSize;
begin
  C := TRecordingChild.Create;
  { AUTO tracks, not Fill: a container only calls Measure on a child in an auto
    track (Fill shares the leftover without asking). Asserting Measure with Fill
    would be asserting something the container never promised. }
  K := TContainer.Create([Auto], [Auto]);
  S := TSurfaceMemory.Create(20, 6);
  try
    K.Add(C, 0, 0);
    Avail := Default(TSize);
    Avail.W := 20;
    Avail.H := 6;
    K.Measure(Avail);
    AssertTrue('Measure reached the child', C.MeasureCalls > 0);

    K.Arrange(Rc(0, 0, 20, 6));
    AssertTrue('Arrange reached the child', C.ArrangeCalls > 0);

    K.Render(S);
    AssertTrue('Render reached the child', C.RenderCalls > 0);

    K.HandleEvent(Click(3, 3));
    AssertTrue('HandleEvent reached the child', C.EventCalls > 0);

    { A container reports a hit when a CHILD is hit - that recursion is the
      contract, and it was missing until e618a02. }
    C.Reset;
    K.HitTest(3, 3);
    AssertTrue('HitTest reached the child', C.HitTestCalls > 0);

    K.CopySelection(S);
    AssertTrue('CopySelection reached the child', C.CopyCalls > 0);

    K.Advance(1000);
    AssertTrue('Advance reached the child', C.AdvanceCalls > 0);
  finally
    K.Free;   { owns C }
    S.Free;
  end;
end;

procedure TForwardingTest.TestModalForwardsToItsContent;
var
  C: TRecordingChild;
  M: TModal;
  S: TSurfaceMemory;
begin
  C := TRecordingChild.Create;
  { Not scrollable: the content is arranged directly, so this test is about the
    frame's own forwarding rather than the scroller's. }
  M := TModal.Create(FTheme, C, False);
  S := TSurfaceMemory.Create(40, 16);
  try
    M.Arrange(Rc(0, 0, 40, 16));
    AssertTrue('Arrange reached the content', C.ArrangeCalls > 0);

    M.Render(S);
    AssertTrue('Render reached the content', C.RenderCalls > 0);

    M.HandleEvent(Click(5, 3));
    AssertTrue('HandleEvent reached the content', C.EventCalls > 0);

    M.CopySelection(S);
    AssertTrue('CopySelection reached the content', C.CopyCalls > 0);
  finally
    M.Free;   { owns C }
    S.Free;
  end;
end;

procedure TForwardingTest.TestModalScrollableContentReceivesEvents;
var
  C: TRecordingChild;
  M: TModal;
  S: TSurfaceMemory;
begin
  C := TRecordingChild.Create;
  M := TModal.Create(FTheme, C, True);
  S := TSurfaceMemory.Create(40, 16);
  try
    { The scrollable path wraps the content in a scroller, so this is really the
      scroller's forwarding tested through the modal. Kept separate because the
      two constructors take different paths and only one of them was broken. }
    M.Arrange(Rc(0, 0, 40, 16));
    M.Render(S);
    M.HandleEvent(Click(5, 3));
    AssertTrue('HandleEvent reached scrolled content', C.EventCalls > 0);

    M.CopySelection(S);
    AssertTrue('CopySelection reached scrolled content', C.CopyCalls > 0);
  finally
    M.Free;   { owns C }
    S.Free;
  end;
end;

initialization
  RegisterTest(TForwardingTest);
end.
