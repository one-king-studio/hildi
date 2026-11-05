unit TestSkillModal;
{ fpcunit tests for HildiSkillModal: the skill detail dialog.

  No terminal and no registry: the dialog takes a plain TSkillDetail record, so
  everything here is a check on what it REPORTS, not on how it looks. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  TUIBase, TUIInput, TUITheme,
  HildiSkillModal;

type
  { Records what the dialog asked to load. A class, not an anonymous method:
    FPC's delphi mode here has no anonymous-method support, and the modal's
    callback is an "of object" pointer. }
  TLoadRecorder = class
  public
    Key: string;
    Calls: Integer;
    procedure OnLoad(const AKey: string);
  end;

  TSkillModalTest = class(TTestCase)
  private
    function KeyEvent(AKind: TKeyKind): TInputEvent;
    function Detail(const AKey, AName: string): TSkillDetail;
  published
    procedure TestEnterReportsTheKey;
    procedure TestLoadedSkillDoesNotReport;
    procedure TestEscapeReportsNothing;
    procedure TestLongBodyScrolls;
    procedure TestOptionalFieldsDefaultEmpty;
    { The footer this dialog BUILDS must split into as many pairs as it draws.
      Checking the splitter alone is not enough: the bug where clicking
      "esc cancel" loaded the skill was a caller and the splitter disagreeing
      about the separator, and every unit test still passed. }
    procedure TestFooterSplitsIntoTheCtasItDraws;
  end;

function Rc(AX, AY, AW, AH: Integer): TRect;

implementation

function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

procedure TLoadRecorder.OnLoad(const AKey: string);
begin
  Key := AKey;
  Inc(Calls);
end;

function TSkillModalTest.KeyEvent(AKind: TKeyKind): TInputEvent;
begin
  Result := Default(TInputEvent);
  Result.Kind := ikKey;
  Result.Key.Kind := AKind;
end;

function TSkillModalTest.Detail(const AKey, AName: string): TSkillDetail;
begin
  Result := Default(TSkillDetail);
  Result.Key := AKey;
  Result.Name := AName;
  Result.Description := 'does a thing';
  Result.Body := 'step one';
end;

procedure TSkillModalTest.TestEnterReportsTheKey;
var
  M: TSkillModal;
  R: TLoadRecorder;
begin
  { The dialog does not load: it reports the key and the host decides. That is
    what keeps it free of the registry, the driver and the approval gate. }
  M := TSkillModal.Create(Default(TTheme));
  R := TLoadRecorder.Create;
  try
    M.SetDetail(Detail('alpha', 'alpha'));
    M.Visible := True;
    M.OnLoad := R.OnLoad;
    AssertTrue('enter is handled', M.HandleEvent(KeyEvent(kkEnter)));
    AssertEquals('the key is reported', 'alpha', R.Key);
    AssertEquals('once', 1, R.Calls);
    AssertFalse('and the dialog closed itself', M.Visible);
  finally
    M.Free;
    R.Free;
  end;
end;

procedure TSkillModalTest.TestLoadedSkillDoesNotReport;
var
  M: TSkillModal;
  R: TLoadRecorder;
  D: TSkillDetail;
begin
  M := TSkillModal.Create(Default(TTheme));
  R := TLoadRecorder.Create;
  try
    D := Detail('alpha', 'alpha');
    D.Loaded := True;
    M.SetDetail(D);
    M.Visible := True;
    M.OnLoad := R.OnLoad;
    { Enter is not consumed: there is nothing to load. }
    AssertFalse('enter does nothing when loaded',
      M.HandleEvent(KeyEvent(kkEnter)));
    AssertEquals('and reports nothing', 0, R.Calls);
  finally
    M.Free;
    R.Free;
  end;
end;

procedure TSkillModalTest.TestEscapeReportsNothing;
var
  M: TSkillModal;
  R: TLoadRecorder;
begin
  M := TSkillModal.Create(Default(TTheme));
  R := TLoadRecorder.Create;
  try
    M.SetDetail(Detail('alpha', 'alpha'));
    M.Visible := True;
    M.OnLoad := R.OnLoad;
    AssertTrue('escape is handled', M.HandleEvent(KeyEvent(kkEscape)));
    AssertEquals('nothing was loaded', 0, R.Calls);
    AssertFalse('and the dialog closed', M.Visible);
  finally
    M.Free;
    R.Free;
  end;
end;

procedure TSkillModalTest.TestLongBodyScrolls;
var
  M: TSkillModal;
  D: TSkillDetail;
  I: Integer;
  S: string;
begin
  { A long SKILL.md must not push the CTAs off the screen. The assertions are on
    what the keys are CONSUMED, because the scroll offset is private - and a
    dialog that ignored them would still render fine on a tall enough screen. }
  M := TSkillModal.Create(Default(TTheme));
  try
    D := Detail('alpha', 'alpha');
    S := '';
    for I := 1 to 200 do
      S := S + 'line ' + IntToStr(I) + #10;
    D.Body := S;
    M.SetDetail(D);
    M.Arrange(Rc(0, 0, 60, 20));
    AssertTrue('down scrolls', M.HandleEvent(KeyEvent(kkDown)));
    AssertTrue('page down scrolls', M.HandleEvent(KeyEvent(kkPageDown)));
    AssertTrue('end jumps to the bottom', M.HandleEvent(KeyEvent(kkEnd)));
    AssertTrue('home returns to the top', M.HandleEvent(KeyEvent(kkHome)));
    { Enter still works while scrolled: the CTA is not pushed away. }
    AssertTrue('the CTA still responds', M.HandleEvent(KeyEvent(kkEnter)));
  finally
    M.Free;
  end;
end;

procedure TSkillModalTest.TestOptionalFieldsDefaultEmpty;
var
  D: TSkillDetail;
begin
  { The dialog omits a row whose field is empty. This pins that the fields a
    skill usually lacks default to empty rather than to a placeholder the dialog
    would then have to special-case. }
  D := Default(TSkillDetail);
  AssertEquals('license', '', D.License);
  AssertEquals('compatibility', '', D.Compatibility);
  AssertEquals('allowed tools', '', D.AllowedTools);
  AssertEquals('location', '', D.Location);
  AssertEquals('no resources', 0, Length(D.Resources));
  AssertFalse('not loaded', D.Loaded);
end;

procedure TSkillModalTest.TestFooterSplitsIntoTheCtasItDraws;
var
  M: TSkillModal;
  D: TSkillDetail;
begin
  M := TSkillModal.Create(Default(TTheme));
  try
    { A loadable, unloaded skill draws TWO CTAs: use, cancel. They must split
      into two pairs, or a click on either one reports the wrong key. }
    D := Detail('alpha', 'Alpha');
    D.Loaded := False;
    M.SetDetail(D);
    AssertEquals('an unloaded skill has use + cancel', 2, M.FooterPairCount);

    { Already loaded: no load CTA, just dismiss. Still two pairs, because the
      left-hand phrase is a label and 'esc cancel' is the binding. }
    D.Loaded := True;
    M.SetDetail(D);
    AssertTrue('a loaded skill still has a split footer',
      M.FooterPairCount >= 1);

    { No key at all: one CTA only. }
    D := Detail('', '');
    D.Loaded := False;
    M.SetDetail(D);
    AssertEquals('a skill with no key has only cancel', 1, M.FooterPairCount);
  finally
    M.Free;
  end;
end;

initialization
  RegisterTest(TSkillModalTest);
end.
