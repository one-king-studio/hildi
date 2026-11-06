unit TestAgentDialog;
{ Tests for the /agent list assembly. Pure: no dialog, no store, no network. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, HildiStore, HildiAgentDialog;

type
  TAgentDialogTest = class(TTestCase)
  private
    function MakeRow(const AName, AProvider, AModel: string): TAgentRow;
    function ItemsOf(const ARows: TAgentRowArray): TAgentListItemArray;
  published
    procedure TestSummaryNamesProviderAndModel;
    procedure TestSummaryOmitsUnsetParameters;
    procedure TestSummaryNotesThatABehaviourPromptExists;
    procedure TestAnAgentWithAMissingProviderIsShown;
    procedure TestAnAgentWithNoProviderIsFine;
    procedure TestTheActiveAgentIsMarked;
  end;

implementation

function AnyProvider(const AName: string): Boolean;
begin
  Result := (AName = 'work') or (AName = 'personal');
end;

function TAgentDialogTest.MakeRow(const AName, AProvider,
  AModel: string): TAgentRow;
begin
  Result := Default(TAgentRow);
  Result.Name := AName;
  Result.ProviderName := AProvider;
  Result.Model := AModel;
end;

function TAgentDialogTest.ItemsOf(
  const ARows: TAgentRowArray): TAgentListItemArray;
begin
  Result := AgentListItems(ARows, AnyProvider);
end;

procedure TAgentDialogTest.TestSummaryNamesProviderAndModel;
var
  R: TAgentRow;
begin
  R := MakeRow('reviewer', 'work', 'openai/gpt-4o');
  AssertEquals('provider and model', 'work - openai/gpt-4o', AgentSummary(R));
end;

procedure TAgentDialogTest.TestSummaryOmitsUnsetParameters;
var
  R: TAgentRow;
  S: string;
begin
  { An unset parameter is NOT zero - it is "not configured". Showing "temp 0" for
    an unset temperature would tell the operator the opposite of the truth. }
  R := MakeRow('bare', 'work', 'm');
  S := AgentSummary(R);
  AssertTrue('no temp shown', Pos('temp', S) = 0);
  AssertTrue('no max shown', Pos('max', S) = 0);
end;

procedure TAgentDialogTest.TestSummaryNotesThatABehaviourPromptExists;
var
  R: TAgentRow;
begin
  { The behaviour prompt is what makes an agent more than a model choice, so its
    PRESENCE is worth seeing at a glance. Its text is not - it can be long, and
    the list is one line. }
  R := MakeRow('reviewer', 'work', 'm');
  AssertTrue('no prompt marker when unset', Pos('prompt', AgentSummary(R)) = 0);
  R.SystemPrompt := 'You review code carefully and tersely.';
  AssertTrue('marked when set', Pos('prompt', AgentSummary(R)) > 0);
  AssertTrue('but not its text',
    Pos('carefully', AgentSummary(R)) = 0);
end;

procedure TAgentDialogTest.TestAnAgentWithAMissingProviderIsShown;
var
  Rows: TAgentRowArray;
  Items: TAgentListItemArray;
begin
  { An agent naming a provider that does not exist is a broken configuration. It
    is SHOWN so the operator can see and fix it - hiding it would leave the
    breakage invisible until a turn failed. }
  SetLength(Rows, 1);
  Rows[0] := MakeRow('stale', 'no-such-provider', 'm');
  Items := ItemsOf(Rows);
  AssertEquals('still listed', 1, Length(Items));
  AssertFalse('marked as not resolving', Items[0].ProviderExists);
  AssertTrue('states the reason: ' + Items[0].Summary,
    Pos('no-such-provider', Items[0].Summary) > 0);
end;

procedure TAgentDialogTest.TestAnAgentWithNoProviderIsFine;
var
  Rows: TAgentRowArray;
  Items: TAgentListItemArray;
begin
  { An agent that names no provider is NOT broken: it inherits whichever provider
    is active. Only a name that fails to resolve is a problem. }
  SetLength(Rows, 1);
  Rows[0] := MakeRow('inherit', '', 'some/model');
  Items := ItemsOf(Rows);
  AssertEquals('listed', 1, Length(Items));
  AssertTrue('resolves', Items[0].ProviderExists);
end;

procedure TAgentDialogTest.TestTheActiveAgentIsMarked;
var
  Rows: TAgentRowArray;
  Items: TAgentListItemArray;
begin
  SetLength(Rows, 2);
  Rows[0] := MakeRow('a', 'work', 'm1');
  Rows[0].Active := False;
  Rows[1] := MakeRow('b', 'work', 'm2');
  Rows[1].Active := True;
  Items := ItemsOf(Rows);
  AssertFalse('first is not active', Items[0].Active);
  AssertTrue('second is', Items[1].Active);
end;

initialization
  RegisterTest(TAgentDialogTest);
end.
