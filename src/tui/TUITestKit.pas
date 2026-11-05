unit TUITestKit;
{ Fixtures for testing widgets headlessly. SHIPS WITH THE MODULE.

  The toolkit's testability is part of its value, not an accident of the harness
  suite. 27 test files in this repo each hand-roll their own surface, their own
  event records and their own arrange-then-render dance; a consumer adopting the
  library would reinvent all of it. This unit is that scaffolding, named.

  Nothing here is application code: it depends only on core, terminal and the
  widget tier, so the isolation gates pass with it in place.

  Usage:
    F := TWidgetFixture.Create(40, 20);
    F.Render(MyWidget);
    AssertEquals('title', 'Hello', F.Row(0));
    F.Free;
}

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils,
  TUIBase, TUIInput,
  TUISurface, TUITheme, TUIWidget;

type
  { The in-memory surface, re-exported so a consumer does not have to reach into
    a production unit for it. Same type, same counters - this is a naming
    convenience, not a wrapper. }
  TTestSurface = TSurfaceMemory;

  { A surface plus the arrange/render/read dance every widget test needs.
    The surface is OWNED by the fixture. }
  TWidgetFixture = class
  private
    FSurface: TSurfaceMemory;
    FTheme: TTheme;
    FWidth, FHeight: Integer;
  public
    constructor Create(AWidth, AHeight: Integer; const ATheme: TTheme);
    destructor Destroy; override;
    { Arrange at the fixture's size, or at an explicit rect, then render. }
    procedure Render(AWidget: TWidget); overload;
    procedure Render(AWidget: TWidget; AWidth, AHeight: Integer); overload;
    procedure RenderAt(AWidget: TWidget; const ABounds: TRect);
    { The row as UTF-8, for comparing against string literals. }
    function Row(ARow: Integer): string; overload;
    function Row(ARow, ACol, ALen: Integer): string; overload;
    { A row as the toolkit's own UnicodeString, for width-sensitive checks. }
    function RowU(ARow: Integer): UnicodeString;
    function CellAt(X, Y: Integer): TCell;
    function ChangedCells: Integer;
    function PutCount: Integer;
    { What a widget TRIED to copy, and how many times. }
    function ClipboardText: string;
    function ClipboardWrites: Integer;
    procedure Clear;
    property Surface: TSurfaceMemory read FSurface;
    property Theme: TTheme read FTheme;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
  end;

{ Event builders. A drag test reads as three lines instead of three records. }
function KeyEvent(AKind: TKeyKind; AMods: TModifiers = []): TInputEvent;
function CharEvent(const ACh: string; AMods: TModifiers = []): TInputEvent;
function MouseEvent(X, Y: Integer; AButton: TMouseButton;
  AAction: TMouseAction; AMods: TModifiers = []): TInputEvent;
function PressAt(X, Y: Integer): TInputEvent;
function MoveTo(X, Y: Integer): TInputEvent;
function ReleaseAt(X, Y: Integer): TInputEvent;
function ResizeEvent(AWidth, AHeight: Integer): TInputEvent;
function PasteEvent(const AText: string): TInputEvent;

{ NOTE: a TAppFixture (a TTuiApp over a TInputSourceScripted) was written and
  withdrawn. Both of its tests raised an EAccessViolation in the suite while the
  same sequence passed in a standalone program, so the fault is shared state
  rather than the fixture's own logic - and shipping a fixture that crashes the
  suite would be worse than shipping none. The reproduction is recorded in the
  TODO; when it is root-caused, this is where it belongs. Every widget test in
  this repo still hand-rolls its own app wiring for that reason. }

implementation

{ Event builders }

function KeyEvent(AKind: TKeyKind; AMods: TModifiers): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
  Result.Key.Mods := AMods;
end;

function CharEvent(const ACh: string; AMods: TModifiers): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := kkChar;
  Result.Key.Ch := UnicodeString(ACh);
  Result.Key.Mods := AMods;
end;

function MouseEvent(X, Y: Integer; AButton: TMouseButton;
  AAction: TMouseAction; AMods: TModifiers): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikMouse;
  Result.Mouse.X := X;
  Result.Mouse.Y := Y;
  Result.Mouse.Button := AButton;
  Result.Mouse.Action := AAction;
  Result.Mouse.Mods := AMods;
end;

function PressAt(X, Y: Integer): TInputEvent;
begin
  Result := MouseEvent(X, Y, mbLeft, maPress);
end;

function MoveTo(X, Y: Integer): TInputEvent;
begin
  { A drag carries the button it is holding, so a widget can tell a drag from a
    bare hover. }
  Result := MouseEvent(X, Y, mbLeft, maMotion);
end;

function ReleaseAt(X, Y: Integer): TInputEvent;
begin
  Result := MouseEvent(X, Y, mbNone, maRelease);
end;

function ResizeEvent(AWidth, AHeight: Integer): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikResize;
  Result.NewSize.W := AWidth;
  Result.NewSize.H := AHeight;
end;

function PasteEvent(const AText: string): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikPaste;
  Result.Text := UnicodeString(AText);
end;

{ TWidgetFixture }

constructor TWidgetFixture.Create(AWidth, AHeight: Integer; const ATheme: TTheme);
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AHeight;
  FTheme := ATheme;
  FSurface := TSurfaceMemory.Create(AWidth, AHeight);
  FSurface.SetScreenBg(ATheme.Bg);
end;

destructor TWidgetFixture.Destroy;
begin
  FSurface.Free;
  inherited Destroy;
end;

procedure TWidgetFixture.Clear;
begin
  FSurface.Clear(DefaultAttr);
end;

procedure TWidgetFixture.RenderAt(AWidget: TWidget; const ABounds: TRect);
begin
  FSurface.Clear(DefaultAttr);
  AWidget.Arrange(ABounds);
  { Pass the object directly: holding it in a local ISurface bumps the refcount
    and frees the surface on return, handing the caller a dangling pointer. }
  AWidget.Render(FSurface);
end;

procedure TWidgetFixture.Render(AWidget: TWidget);
begin
  Render(AWidget, FWidth, FHeight);
end;

procedure TWidgetFixture.Render(AWidget: TWidget; AWidth, AHeight: Integer);
var
  R: TRect;
begin
  R := Default(TRect);
  R.X := 0;
  R.Y := 0;
  R.W := AWidth;
  R.H := AHeight;
  RenderAt(AWidget, R);
end;

function TWidgetFixture.Row(ARow: Integer): string;
begin
  Result := Row(ARow, 0, FWidth);
end;

function TWidgetFixture.Row(ARow, ACol, ALen: Integer): string;
begin
  Result := string(UTF8Encode(FSurface.RowText(ARow, ACol, ALen)));
end;

function TWidgetFixture.RowU(ARow: Integer): UnicodeString;
begin
  Result := FSurface.RowText(ARow, 0, FWidth);
end;

function TWidgetFixture.CellAt(X, Y: Integer): TCell;
begin
  Result := FSurface.CellAt(X, Y);
end;

function TWidgetFixture.ChangedCells: Integer;
begin
  Result := FSurface.LastFrameChangedCells;
end;

function TWidgetFixture.PutCount: Integer;
begin
  Result := FSurface.PutCount;
end;

function TWidgetFixture.ClipboardText: string;
begin
  Result := string(UTF8Encode(FSurface.ClipboardText));
end;

function TWidgetFixture.ClipboardWrites: Integer;
begin
  Result := FSurface.ClipboardWrites;
end;

end.
