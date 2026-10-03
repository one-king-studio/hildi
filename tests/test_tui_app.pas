unit test_tui_app;
{ fpcunit tests for hildegard.helper.tui.app: plane stacking, modal dimming and
  input trapping, resize relayout, and one-event-per-Step. No terminal. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.app;

type
  TAppProbe = class(TWidget)
  private
    FW, FH: Integer;
    FMarker: UnicodeString;
  public
    Accept: Boolean;
    HandleCount: Integer;
    LastKeyKind: TKeyKind;
    LastKind: TInputKind;
    LastPaste: UnicodeString;
    ArrangeCalls: Integer;
    constructor Create(AW, AH: Integer; const AMarker: UnicodeString = '#');
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

  TTuiAppTest = class(TTestCase)
  private
    function Rc(AX, AY, AW, AH: Integer): TRect;
    function KeyEvent(AKind: TKeyKind): TInputEvent;
    function ResizeEvent(AW, AH: Integer): TInputEvent;
    function PasteEvent(const AText: string): TInputEvent;
  published
    procedure TestFrameRendersBaseThenModal;
    procedure TestModalDimsBackgroundButKeepsText;
    procedure TestModalRegionNotDimmed;
    procedure TestModalTrapsInput;
    procedure TestPopModalRestoresBase;
    procedure TestResizeRelayoutsRoot;
    procedure TestStepProcessesOneEvent;
    procedure TestPasteIsDispatched;
  end;

implementation

constructor TAppProbe.Create(AW, AH: Integer; const AMarker: UnicodeString);
begin
  inherited Create;
  FW := AW;
  FH := AH;
  FMarker := AMarker;
  Accept := True;
end;

function TAppProbe.Measure(const AAvail: TSize): TSize;
begin
  Result := Default(TSize);
  Result.W := FW;
  Result.H := FH;
end;

procedure TAppProbe.Arrange(const ABounds: TRect);
begin
  inherited Arrange(ABounds);
  Inc(ArrangeCalls);
end;

procedure TAppProbe.Render(const S: ISurface);
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

function TAppProbe.HandleEvent(const E: TInputEvent): Boolean;
begin
  Inc(HandleCount);
  LastKeyKind := E.Key.Kind;
  LastKind := E.Kind;
  LastPaste := E.Text;
  Result := Accept;
end;

function TTuiAppTest.Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function TTuiAppTest.KeyEvent(AKind: TKeyKind): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
end;

function TTuiAppTest.ResizeEvent(AW, AH: Integer): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikResize;
  Result.NewSize.W := AW;
  Result.NewSize.H := AH;
end;

function TTuiAppTest.PasteEvent(const AText: string): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikPaste;
  Result.Text := UnicodeString(AText);
end;

procedure TTuiAppTest.TestPasteIsDispatched;
var
  S: TSurfaceMemory;
  Src: TInputSourceScripted;
  Base: TAppProbe;
  App: TTuiApp;
begin
  S := TSurfaceMemory.Create(10, 4);
  Src := TInputSourceScripted.Create;
  Base := TAppProbe.Create(10, 4, 'B');
  App := TTuiApp.Create(S, Src, Base);
  try
    { A paste must reach the widget tree, like a key or a mouse event. }
    Src.Push(PasteEvent('hello' + #10 + 'world'));
    App.Step;
    AssertEquals('paste reached the root', Ord(ikPaste), Ord(Base.LastKind));
    AssertEquals('payload intact', 'hello' + #10 + 'world',
      string(Base.LastPaste));
  finally
    App.Free;
  end;
end;

procedure TTuiAppTest.TestFrameRendersBaseThenModal;
var
  S: TSurfaceMemory;
  Src: TInputSourceScripted;
  Base: TAppProbe;
  ModalC: TContainer;
  MP: TAppProbe;
  App: TTuiApp;
begin
  S := TSurfaceMemory.Create(10, 4);
  Src := TInputSourceScripted.Create;
  Base := TAppProbe.Create(10, 4, 'B');
  App := TTuiApp.Create(S, Src, Base);
  try
    ModalC := TContainer.Create([Fixed(2), Fill(1)], [Fixed(1), Fill(1)]);
    MP := TAppProbe.Create(2, 1, 'M');
    ModalC.Add(MP, 0, 0);
    ModalC.Arrange(Rc(0, 0, 10, 4));
    App.PushPlane(TPlane.Create(ModalC, True, False));
    App.Step;
    AssertEquals('modal drawn over base', 'M', S.CellAt(0, 0).Ch);
    AssertEquals('base visible around modal', 'B', S.CellAt(4, 2).Ch);
  finally
    App.Free;
  end;
end;

procedure TTuiAppTest.TestModalDimsBackgroundButKeepsText;
var
  S: TSurfaceMemory;
  Src: TInputSourceScripted;
  Base, ModalRoot: TAppProbe;
  App: TTuiApp;
begin
  S := TSurfaceMemory.Create(10, 4);
  Src := TInputSourceScripted.Create;
  Base := TAppProbe.Create(10, 4, 'B');
  App := TTuiApp.Create(S, Src, Base);
  try
    ModalRoot := TAppProbe.Create(2, 1, 'M');
    ModalRoot.Arrange(Rc(0, 0, 2, 1));
    App.PushPlane(TPlane.Create(ModalRoot, True, True));
    App.Step;
    AssertEquals('base glyph preserved under the modal', 'B', S.CellAt(5, 2).Ch);
    AssertTrue('background cell is dimmed', sfDim in S.CellAt(5, 2).Attr.Style);
    AssertEquals('modal glyph drawn', 'M', S.CellAt(0, 0).Ch);
  finally
    App.Free;
  end;
end;

procedure TTuiAppTest.TestModalRegionNotDimmed;
var
  S: TSurfaceMemory;
  Src: TInputSourceScripted;
  App: TTuiApp;
  ModalRoot: TAppProbe;
begin
  S := TSurfaceMemory.Create(10, 4);
  Src := TInputSourceScripted.Create;
  App := TTuiApp.Create(S, Src, TAppProbe.Create(10, 4, 'B'));
  try
    ModalRoot := TAppProbe.Create(2, 1, 'M');
    ModalRoot.Arrange(Rc(0, 0, 2, 1));
    App.PushPlane(TPlane.Create(ModalRoot, True, True));
    App.Step;
    AssertFalse('modal cell is not dimmed',
      sfDim in S.CellAt(0, 0).Attr.Style);
    AssertTrue('surrounding cell is dimmed',
      sfDim in S.CellAt(9, 3).Attr.Style);
  finally
    App.Free;
  end;
end;

procedure TTuiAppTest.TestModalTrapsInput;
var
  S: TSurfaceMemory;
  Src: TInputSourceScripted;
  Base, ModalRoot: TAppProbe;
  App: TTuiApp;
begin
  S := TSurfaceMemory.Create(10, 4);
  Src := TInputSourceScripted.Create;
  Base := TAppProbe.Create(10, 4, 'B');
  ModalRoot := TAppProbe.Create(10, 4, 'M');
  App := TTuiApp.Create(S, Src, Base);
  try
    App.PushPlane(TPlane.Create(ModalRoot, True, False));
    Src.Push(KeyEvent(kkDown));
    App.Step;
    AssertEquals('base receives nothing while modal is up', 0, Base.HandleCount);
    AssertEquals('modal receives the event', 1, ModalRoot.HandleCount);
  finally
    App.Free;
  end;
end;

procedure TTuiAppTest.TestPopModalRestoresBase;
var
  S: TSurfaceMemory;
  Src: TInputSourceScripted;
  App: TTuiApp;
  ModalRoot: TAppProbe;
begin
  S := TSurfaceMemory.Create(10, 4);
  Src := TInputSourceScripted.Create;
  App := TTuiApp.Create(S, Src, TAppProbe.Create(10, 4, 'B'));
  try
    ModalRoot := TAppProbe.Create(10, 4, 'M');
    ModalRoot.Arrange(Rc(0, 0, 10, 4));
    App.PushPlane(TPlane.Create(ModalRoot, True, True));
    App.Step;
    AssertEquals('modal is shown', 'M', S.CellAt(0, 0).Ch);

    App.PopPlane;
    App.Step;
    AssertEquals('base restored', 'B', S.CellAt(0, 0).Ch);
    AssertFalse('base no longer dimmed',
      sfDim in S.CellAt(0, 0).Attr.Style);
    AssertFalse('no modal remains', App.ModalActive);
  finally
    App.Free;
  end;
end;

procedure TTuiAppTest.TestResizeRelayoutsRoot;
var
  S: TSurfaceMemory;
  Src: TInputSourceScripted;
  Base: TAppProbe;
  App: TTuiApp;
  Before: Integer;
begin
  S := TSurfaceMemory.Create(20, 10);
  Src := TInputSourceScripted.Create;
  Base := TAppProbe.Create(20, 10, 'B');
  App := TTuiApp.Create(S, Src, Base);
  try
    AssertEquals('initial layout width', 20, Base.Bounds.W);
    Before := Base.ArrangeCalls;
    S.Resize(30, 15);
    Src.Push(ResizeEvent(30, 15));
    App.Step;
    AssertEquals('relaid out to new width', 30, Base.Bounds.W);
    AssertEquals('relaid out to new height', 15, Base.Bounds.H);
    AssertTrue('a relayout actually happened', Base.ArrangeCalls > Before);
  finally
    App.Free;
  end;
end;

procedure TTuiAppTest.TestStepProcessesOneEvent;
var
  S: TSurfaceMemory;
  Src: TInputSourceScripted;
  Base: TAppProbe;
  App: TTuiApp;
begin
  S := TSurfaceMemory.Create(10, 4);
  Src := TInputSourceScripted.Create;
  Base := TAppProbe.Create(10, 4, 'B');
  App := TTuiApp.Create(S, Src, Base);
  try
    Src.Push(KeyEvent(kkDown));
    Src.Push(KeyEvent(kkUp));
    App.Step;
    AssertEquals('first Step handles one event', 1, Base.HandleCount);
    AssertTrue('first event was down', Base.LastKeyKind = kkDown);
    App.Step;
    AssertEquals('second Step handles the next', 2, Base.HandleCount);
    AssertTrue('second event was up', Base.LastKeyKind = kkUp);
  finally
    App.Free;
  end;
end;

initialization
  RegisterTest(TTuiAppTest);
end.
