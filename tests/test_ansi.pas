unit test_ansi;
{ fpcunit tests for hildegard.helper.ansi. Each test sets the enabled state
  explicitly and restores it, so results do not depend on the TTY. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, hildegard.helper.ansi;

type
  TAnsiTest = class(TTestCase)
  private
    FSaved: Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestColorBuildsRecord;
    procedure TestFgEmitsTruecolorWhenEnabled;
    procedure TestDimWrapsAndResetsWhenEnabled;
    procedure TestDisabledReturnsTextUnchanged;
    procedure TestDisabledFgIsEmpty;
    procedure TestEnabledToggleRoundTrip;
  end;

implementation

procedure TAnsiTest.SetUp;
begin
  FSaved := AnsiEnabled;
end;

procedure TAnsiTest.TearDown;
begin
  AnsiSetEnabled(FSaved);
end;

procedure TAnsiTest.TestColorBuildsRecord;
var
  C: TAnsiColor;
begin
  C := Color(1, 2, 3);
  AssertEquals('r', 1, C.R);
  AssertEquals('g', 2, C.G);
  AssertEquals('b', 3, C.B);
end;

procedure TAnsiTest.TestFgEmitsTruecolorWhenEnabled;
var
  S: string;
begin
  AnsiSetEnabled(True);
  S := AnsiFg(Color(10, 20, 30));
  AssertTrue('starts with ESC', (Length(S) > 0) and (S[1] = #27));
  AssertTrue('truecolor sequence', Pos('[38;2;10;20;30m', S) > 0);
end;

procedure TAnsiTest.TestDimWrapsAndResetsWhenEnabled;
var
  S: string;
begin
  AnsiSetEnabled(True);
  S := AnsiDim('hello');
  AssertTrue('has dim code', Pos(#27 + '[2m', S) > 0);
  AssertTrue('has reset', Pos(#27 + '[0m', S) > 0);
  AssertTrue('contains text', Pos('hello', S) > 0);
end;

procedure TAnsiTest.TestDisabledReturnsTextUnchanged;
begin
  AnsiSetEnabled(False);
  AssertEquals('dim unchanged', 'plain', AnsiDim('plain'));
  AssertEquals('bold unchanged', 'plain', AnsiBold('plain'));
  AssertEquals('styled unchanged', 'plain', AnsiStyled('plain', AnsiRed));
end;

procedure TAnsiTest.TestDisabledFgIsEmpty;
begin
  AnsiSetEnabled(False);
  AssertEquals('fg empty', '', AnsiFg(AnsiRed));
  AssertEquals('reset empty', '', AnsiReset);
end;

procedure TAnsiTest.TestEnabledToggleRoundTrip;
begin
  AnsiSetEnabled(True);
  AssertTrue('on', AnsiEnabled);
  AnsiSetEnabled(False);
  AssertFalse('off', AnsiEnabled);
end;

initialization
  RegisterTest(TAnsiTest);
end.
