unit TestTUIPrompt;
{ fpcunit tests for TUIWidgetsPrompt: a single-line editor with
  cluster-aware cursor editing, history, and submit. No terminal. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  TUIBase, TUIInput,
  TUISurface, TUIWidget,
  TUIWidgetsPrompt;

type
  TSubmitRecorder = class
  public
    Count: Integer;
    Last: string;
    procedure OnSubmit(const AText: string);
  end;

  TPromptLineTest = class(TTestCase)
  private
    FPrompt: TPromptLine;
    FRecorder: TSubmitRecorder;
    function Key(AKind: TKeyKind): TInputEvent;
    function Ch(const AText: string): TInputEvent;
    procedure TypeText(const AText: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestTypingThenSubmit;
    procedure TestBackspaceAndDelete;
    procedure TestHomeEndInsert;
    procedure TestHistoryRecallAndDraft;
    procedure TestInactiveIgnoresInput;
    procedure TestEmptySubmitIgnored;
    procedure TestRenderShowsCursorReversed;
  end;

implementation

procedure TSubmitRecorder.OnSubmit(const AText: string);
begin
  Inc(Count);
  Last := AText;
end;

{ TPromptLineTest }

procedure TPromptLineTest.SetUp;
begin
  FPrompt := TPromptLine.Create('> ');
  FRecorder := TSubmitRecorder.Create;
  FPrompt.OnSubmit := FRecorder.OnSubmit;
end;

procedure TPromptLineTest.TearDown;
begin
  FPrompt.Free;
  FRecorder.Free;
end;

function TPromptLineTest.Key(AKind: TKeyKind): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
end;

function TPromptLineTest.Ch(const AText: string): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := kkChar;
  Result.Key.Ch := UnicodeString(AText);
end;

procedure TPromptLineTest.TypeText(const AText: string);
var
  I: Integer;
begin
  for I := 1 to Length(AText) do
    FPrompt.HandleEvent(Ch(AText[I]));
end;

procedure TPromptLineTest.TestTypingThenSubmit;
begin
  FPrompt.HandleEvent(Ch('h'));
  FPrompt.HandleEvent(Ch('i'));
  AssertEquals('text', 'hi', FPrompt.Text);
  FPrompt.HandleEvent(Key(kkEnter));
  AssertEquals('submitted once', 1, FRecorder.Count);
  AssertEquals('submitted text', 'hi', FRecorder.Last);
  AssertEquals('cleared', '', FPrompt.Text);
end;

procedure TPromptLineTest.TestBackspaceAndDelete;
begin
  TypeText('abc');
  FPrompt.HandleEvent(Key(kkBackspace));
  AssertEquals('after backspace', 'ab', FPrompt.Text);
  FPrompt.HandleEvent(Key(kkLeft));
  FPrompt.HandleEvent(Key(kkDelete));
  AssertEquals('after delete', 'a', FPrompt.Text);
end;

procedure TPromptLineTest.TestHomeEndInsert;
begin
  TypeText('ab');
  FPrompt.HandleEvent(Key(kkHome));
  FPrompt.HandleEvent(Ch('X'));
  AssertEquals('insert at home', 'Xab', FPrompt.Text);
  FPrompt.HandleEvent(Key(kkEnd));
  FPrompt.HandleEvent(Ch('Y'));
  AssertEquals('insert at end', 'XabY', FPrompt.Text);
end;

procedure TPromptLineTest.TestHistoryRecallAndDraft;
begin
  FPrompt.AddHistory('one');
  FPrompt.AddHistory('two');
  TypeText('draft');
  FPrompt.HandleEvent(Key(kkUp));
  AssertEquals('two', 'two', FPrompt.Text);
  FPrompt.HandleEvent(Key(kkUp));
  AssertEquals('one', 'one', FPrompt.Text);
  FPrompt.HandleEvent(Key(kkDown));
  AssertEquals('back to two', 'two', FPrompt.Text);
  FPrompt.HandleEvent(Key(kkDown));
  AssertEquals('draft restored', 'draft', FPrompt.Text);
end;

procedure TPromptLineTest.TestInactiveIgnoresInput;
begin
  FPrompt.Active := False;
  FPrompt.HandleEvent(Ch('x'));
  AssertEquals('no text when inactive', '', FPrompt.Text);
end;

procedure TPromptLineTest.TestEmptySubmitIgnored;
begin
  FPrompt.HandleEvent(Ch(' '));
  FPrompt.HandleEvent(Key(kkEnter));
  AssertEquals('no submit', 0, FRecorder.Count);
end;

procedure TPromptLineTest.TestRenderShowsCursorReversed;
var
  Surface: TSurfaceMemory;
  Cell: TCell;
  R: TRect;
begin
  TypeText('a');
  Surface := TSurfaceMemory.Create(10, 1);
  try
    R := Default(TRect);
    R.X := 0;
    R.Y := 0;
    R.W := 10;
    R.H := 1;
    FPrompt.Arrange(R);
    FPrompt.Render(Surface);
    { Prompt marker occupies columns 0..1, 'a' at column 2, cursor at column 3. }
    Cell := Surface.CellAt(3, 0);
    AssertTrue('cursor reversed', sfReverse in Cell.Attr.Style);
  finally
    Surface.Free;
  end;
end;

initialization
  RegisterTest(TPromptLineTest);

end.
