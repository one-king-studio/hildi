unit test_tui_conversation;
{ fpcunit tests for hildegard.helper.tui.conversation: styled append, rendering,
  and sticky-to-bottom scrolling. No terminal. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.conversation;

type
  TConversationViewTest = class(TTestCase)
  private
    FView: TConversationView;
    function Rc(AW, AH: Integer): TRect;
    procedure AppendLines(ACount, AStart: Integer);
    function Key(AKind: TKeyKind): TInputEvent;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestAppendRendersStyledText;
    procedure TestFollowsBottomOnAppend;
    procedure TestScrollUpStopsFollowing;
    procedure TestEndResumesFollowing;
    procedure TestClear;
    procedure TestLongLineClipsNotWraps;
  end;

implementation

procedure TConversationViewTest.SetUp;
begin
  FView := TConversationView.Create;
end;

procedure TConversationViewTest.TearDown;
begin
  FView.Free;
end;

function TConversationViewTest.Rc(AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := 0;
  Result.Y := 0;
  Result.W := AW;
  Result.H := AH;
end;

procedure TConversationViewTest.AppendLines(ACount, AStart: Integer);
var
  I: Integer;
  Attr: TAttr;
begin
  Attr := DefaultAttr;
  Attr.Fg := 200;
  for I := AStart to AStart + ACount - 1 do
    FView.Append(UnicodeString('line' + IntToStr(I) + #10), Attr);
end;

function TConversationViewTest.Key(AKind: TKeyKind): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
end;

procedure TConversationViewTest.TestAppendRendersStyledText;
var
  Surface: TSurfaceMemory;
  Attr: TAttr;
  Cell: TCell;
begin
  Attr := DefaultAttr;
  Attr.Fg := 215;
  FView.Append('hello world', Attr);
  FView.Arrange(Rc(20, 3));
  Surface := TSurfaceMemory.Create(20, 3);
  try
    FView.Render(Surface);
    AssertEquals('rendered text', 'hello world', Surface.RowText(0, 0, 11));
    Cell := Surface.CellAt(0, 0);
    AssertEquals('styled fg', 215, Cell.Attr.Fg);
  finally
    Surface.Free;
  end;
end;

procedure TConversationViewTest.TestFollowsBottomOnAppend;
begin
  AppendLines(20, 0);
  FView.Arrange(Rc(10, 3));
  AssertTrue('following', FView.Following);
  AssertEquals('at bottom', 17, FView.ScrollY);
end;

procedure TConversationViewTest.TestScrollUpStopsFollowing;
begin
  AppendLines(20, 0);
  FView.Arrange(Rc(10, 3));
  AssertTrue('scrolled up handled', FView.HandleEvent(Key(kkUp)));
  AssertFalse('no longer following', FView.Following);
  AssertEquals('scrolled up by one', 16, FView.ScrollY);

  AppendLines(1, 20);
  FView.Arrange(Rc(10, 3));
  AssertEquals('stays put on append', 16, FView.ScrollY);
end;

procedure TConversationViewTest.TestEndResumesFollowing;
begin
  AppendLines(20, 0);
  FView.Arrange(Rc(10, 3));
  FView.HandleEvent(Key(kkUp));
  AssertFalse('not following', FView.Following);
  FView.HandleEvent(Key(kkEnd));
  AssertTrue('following after End', FView.Following);
  AssertEquals('at bottom', 17, FView.ScrollY);

  AppendLines(1, 20);
  FView.Arrange(Rc(10, 3));
  AssertEquals('new bottom', 18, FView.ScrollY);
end;

procedure TConversationViewTest.TestClear;
var
  Surface: TSurfaceMemory;
  Attr: TAttr;
begin
  Attr := DefaultAttr;
  FView.Append('gone', Attr);
  FView.Clear;
  FView.Arrange(Rc(10, 2));
  Surface := TSurfaceMemory.Create(10, 2);
  try
    FView.Render(Surface);
    AssertEquals('cleared', '', Surface.RowText(0, 0, 10));
  finally
    Surface.Free;
  end;
end;

procedure TConversationViewTest.TestLongLineClipsNotWraps;
var
  Surface: TSurfaceMemory;
  Attr: TAttr;
begin
  Attr := DefaultAttr;
  FView.Append('abcdefghijklmnopqrstuvwxyz', Attr);
  FView.Arrange(Rc(10, 3));
  Surface := TSurfaceMemory.Create(10, 3);
  try
    FView.Render(Surface);
    AssertEquals('clipped to the first ten columns', 'abcdefghij',
      Surface.RowText(0, 0, 10));
    AssertEquals('no wrapped continuation', '', Surface.RowText(1, 0, 10));
  finally
    Surface.Free;
  end;
end;

initialization
  RegisterTest(TConversationViewTest);

end.
