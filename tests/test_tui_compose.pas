unit test_tui_compose;
{ fpcunit tests for hildegard.helper.tui.compose: the input box chrome, growth,
  and the submit rule. Rendering is asserted through TSurfaceMemory. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  SysUtils, fpcunit, testregistry,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.theme,
  hildegard.helper.tui.compose;

type
  TTuiComposeTest = class(TTestCase)
  private
    FTheme: TTheme;
    FSubmitted: string;
    FSubmits: Integer;
    procedure OnSubmit(const AText: string);
    function Rc(AX, AY, AW, AH: Integer): TRect;
    function Key(AKind: TKeyKind; AMods: TModifiers = []): TInputEvent;
    function Ch(const AText: string): TInputEvent;
  protected
    procedure SetUp; override;
  published
    procedure TestNeededHeightGrowsWithWrappedText;
    procedure TestEnterSubmitsAndClears;
    procedure TestShiftEnterAddsALine;
    procedure TestAltEnterAddsALine;
    procedure TestEmptySubmitIsIgnored;
    procedure TestPasteInsertsLiterallyWithoutSubmit;
    procedure TestCtaShowsSendAndCancel;
    procedure TestInfoLineRenders;
    procedure TestCaretBlinkIsForwarded;
  end;

implementation

procedure TTuiComposeTest.SetUp;
begin
  FTheme := DarkTheme;
  FSubmitted := '';
  FSubmits := 0;
end;

procedure TTuiComposeTest.OnSubmit(const AText: string);
begin
  FSubmitted := AText;
  Inc(FSubmits);
end;

function TTuiComposeTest.Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function TTuiComposeTest.Key(AKind: TKeyKind; AMods: TModifiers): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
  Result.Key.Mods := AMods;
end;

function TTuiComposeTest.Ch(const AText: string): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := kkChar;
  Result.Key.Ch := UnicodeString(AText);
end;

procedure TTuiComposeTest.TestNeededHeightGrowsWithWrappedText;
var
  C: TComposeBox;
  Empty, Wrapped: Integer;
begin
  C := TComposeBox.Create(FTheme, 'info');
  try
    Empty := C.NeededHeight(30);
    C.Edit.InsertText(
      'this is a fairly long line of text that should wrap onto several rows');
    Wrapped := C.NeededHeight(30);
    AssertTrue('grew with the wrapped text', Wrapped > Empty);
    AssertEquals('one text row plus four chrome rows', 5, Empty);
  finally
    C.Free;
  end;
end;

procedure TTuiComposeTest.TestEnterSubmitsAndClears;
var
  C: TComposeBox;
  I: Integer;
begin
  C := TComposeBox.Create(FTheme, 'info');
  try
    C.OnSubmit := OnSubmit;
    C.Arrange(Rc(0, 0, 30, 5));
    for I := 1 to 3 do
      C.HandleEvent(Ch('abc'[I]));
    AssertTrue('enter handled', C.HandleEvent(Key(kkEnter)));
    AssertEquals('submitted once', 1, FSubmits);
    AssertEquals('submitted the text', 'abc', FSubmitted);
    AssertEquals('box cleared', '', string(C.Text));
  finally
    C.Free;
  end;
end;

procedure TTuiComposeTest.TestShiftEnterAddsALine;
var
  C: TComposeBox;
  I: Integer;
begin
  C := TComposeBox.Create(FTheme, 'info');
  try
    C.OnSubmit := OnSubmit;
    C.Arrange(Rc(0, 0, 30, 5));
    for I := 1 to 2 do
      C.HandleEvent(Ch('ab'[I]));
    AssertTrue('shift+enter handled', C.HandleEvent(Key(kkEnter, [moShift])));
    AssertEquals('not submitted', 0, FSubmits);
    AssertEquals('a line was added', 'ab' + #10, string(C.Text));
  finally
    C.Free;
  end;
end;

procedure TTuiComposeTest.TestAltEnterAddsALine;
var
  C: TComposeBox;
begin
  C := TComposeBox.Create(FTheme, 'info');
  try
    C.OnSubmit := OnSubmit;
    C.Arrange(Rc(0, 0, 30, 5));
    C.HandleEvent(Ch('a'));
    AssertTrue('alt+enter handled', C.HandleEvent(Key(kkEnter, [moAlt])));
    AssertEquals('not submitted', 0, FSubmits);
    AssertEquals('a line was added', 'a' + #10, string(C.Text));
  finally
    C.Free;
  end;
end;

procedure TTuiComposeTest.TestEmptySubmitIsIgnored;
var
  C: TComposeBox;
begin
  C := TComposeBox.Create(FTheme, 'info');
  try
    C.OnSubmit := OnSubmit;
    C.Arrange(Rc(0, 0, 30, 5));
    C.HandleEvent(Ch(' '));
    C.HandleEvent(Key(kkEnter));
    AssertEquals('whitespace-only is not submitted', 0, FSubmits);
  finally
    C.Free;
  end;
end;

procedure TTuiComposeTest.TestPasteInsertsLiterallyWithoutSubmit;
var
  C: TComposeBox;
  E: TInputEvent;
begin
  C := TComposeBox.Create(FTheme, 'info');
  try
    C.OnSubmit := OnSubmit;
    C.Arrange(Rc(0, 0, 30, 8));
    E := Default(TInputEvent);
    E.Kind := ikPaste;
    E.Text := 'line one' + #10 + 'line two';
    AssertTrue('paste handled', C.HandleEvent(E));
    AssertEquals('a paste never submits', 0, FSubmits);
    AssertEquals('inserted literally', 'line one' + #10 + 'line two',
      string(C.Text));
  finally
    C.Free;
  end;
end;

procedure TTuiComposeTest.TestCtaShowsSendAndCancel;
var
  C: TComposeBox;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(40, 5);
  try
    C := TComposeBox.Create(FTheme, 'Hildegard');
    try
      C.Arrange(Rc(0, 0, 40, 5));

      C.Cta := ckNone;
      C.Render(S);
      AssertEquals('no CTA when idle and empty', False,
        Pos('send', S.RowText(3, 0, 40)) > 0);

      C.Cta := ckSend;
      C.Render(S);
      AssertTrue('send CTA shown',
        Pos(SendCtaKey + ' send', S.RowText(3, 0, 40)) > 0);

      C.Cta := ckCancel;
      C.Render(S);
      AssertTrue('cancel CTA shown',
        Pos('esc cancel', S.RowText(3, 0, 40)) > 0);
    finally
      C.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiComposeTest.TestInfoLineRenders;
var
  C: TComposeBox;
  S: TSurfaceMemory;
begin
  S := TSurfaceMemory.Create(30, 5);
  try
    C := TComposeBox.Create(FTheme, 'Hildegard');
    try
      C.Arrange(Rc(0, 0, 30, 5));
      C.Render(S);
      AssertTrue('info line shown',
        Pos('Hildegard', S.RowText(3, 0, 30)) > 0);
      AssertEquals('heavy top border', '═', S.CellAt(1, 0).Ch);
      AssertEquals('single bottom border', '─', S.CellAt(1, 4).Ch);
    finally
      C.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TTuiComposeTest.TestCaretBlinkIsForwarded;
var
  C: TComposeBox;
begin
  C := TComposeBox.Create(FTheme, 'info');
  try
    AssertTrue('animates (the caret blinks)', C.Animating);
    AssertFalse('same blink phase', C.Advance(0));
    AssertTrue('blink toggled', C.Advance(600));
  finally
    C.Free;
  end;
end;

initialization
  RegisterTest(TTuiComposeTest);
end.
