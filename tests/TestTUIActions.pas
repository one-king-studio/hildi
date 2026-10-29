unit TestTUIActions;
{ fpcunit tests for the CTA actions bar (TUIWidgetsActions): it renders
  its hints, fires OnAction by index on the hint's key, and ignores other keys.
  Headless, over TSurfaceMemory. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  TUIBase, TUISurface,
  TUIInput, TUITheme,
  TUIWidget, TUIWidgetsActions;

type
  TActionRecorder = class
  public
    Last: Integer;
    Count: Integer;
    procedure OnAction(AIndex: Integer);
  end;

  TActionsBarTest = class(TTestCase)
  private
    FBar: TActionsBar;
    FRec: TActionRecorder;
    function Surface(W, H: Integer): TSurfaceMemory;
    function Key(AKind: TKeyKind): TInputEvent;
    function Ch(const AText: string): TInputEvent;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRendersHints;
    procedure TestKeyFiresTheAction;
    procedure TestOtherKeyIsIgnored;
  end;

implementation

procedure TActionRecorder.OnAction(AIndex: Integer);
begin
  Last := AIndex;
  Inc(Count);
end;

function TActionsBarTest.Surface(W, H: Integer): TSurfaceMemory;
begin
  Result := TSurfaceMemory.Create(W, H);
end;

function TActionsBarTest.Key(AKind: TKeyKind): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
end;

function TActionsBarTest.Ch(const AText: string): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := kkChar;
  Result.Key.Ch := UnicodeString(AText);
end;

procedure TActionsBarTest.SetUp;
var
  Hints: TActionHintArray;
begin
  FBar := TActionsBar.Create(DarkTheme);
  FRec := TActionRecorder.Create;
  FBar.OnAction := FRec.OnAction;
  FBar.Label_ := 'subagent';
  SetLength(Hints, 3);
  Hints[0].Key := 'a';
  Hints[0].Action := ' abort';
  Hints[1].Key := 'r';
  Hints[1].Action := ' release';
  Hints[2].Key := 'esc';
  Hints[2].Action := ' leave';
  FBar.SetHints(Hints);
end;

procedure TActionsBarTest.TearDown;
begin
  FBar.Free;
  FRec.Free;
end;

procedure TActionsBarTest.TestRendersHints;
var
  S: TSurfaceMemory;
  R: TRect;
  Found: UnicodeString;
  Y: Integer;
begin
  S := Surface(60, 4);
  try
    R := Default(TRect);
    R.W := 60;
    R.H := 4;
    FBar.Arrange(R);
    FBar.Render(S);
    Found := '';
    for Y := 0 to 3 do
      Found := Found + S.RowText(Y, 0, 60);
    AssertTrue('the label is drawn', Pos('subagent', Found) > 0);
    AssertTrue('the abort hint is drawn', Pos('abort', Found) > 0);
    AssertTrue('the leave hint is drawn', Pos('leave', Found) > 0);
  finally
    S.Free;
  end;
end;

procedure TActionsBarTest.TestKeyFiresTheAction;
begin
  AssertTrue('the abort key is handled', FBar.HandleEvent(Ch('a')));
  AssertEquals('abort fired', 0, FRec.Last);
  AssertTrue('the release key is handled', FBar.HandleEvent(Ch('r')));
  AssertEquals('release fired', 1, FRec.Last);
  AssertEquals('two fires', 2, FRec.Count);
end;

procedure TActionsBarTest.TestOtherKeyIsIgnored;
begin
  AssertFalse('an unmapped key is not handled', FBar.HandleEvent(Ch('z')));
  AssertFalse('escape falls through to the host',
    FBar.HandleEvent(Key(kkEscape)));
  AssertEquals('nothing fired', 0, FRec.Count);
end;

initialization
  RegisterTest(TActionsBarTest);
end.
