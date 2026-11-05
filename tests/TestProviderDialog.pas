unit TestProviderDialog;
{ Tests for the /provider list assembly. Pure: no dialog, no store, no network.

  These pin the three facts most likely to be wrong and least likely to be
  noticed: which provider is active, whether a row's slug resolves, and that a
  row which CANNOT resolve is still shown rather than silently dropped. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, HildiStore, HildiProviderDialog;

type
  TProviderDialogTest = class(TTestCase)
  private
    function MakeRow(const AName, AKey, AModel: string): TProviderRow;
    function ItemsOf(const ARows: TProviderRowArray): TProviderListItemArray;
  published
    procedure TestSummaryNamesSlugModelAndParameters;
    procedure TestSummaryOmitsUnsetParameters;
    procedure TestAProviderWithNoAdapterIsShownUnusable;
    procedure TestAnEmptyKeyIsUnusable;
    procedure TestTheActiveProviderIsMarked;
    procedure TestAnUnnamedRowIsSkipped;
    procedure TestAnEmptyStoreGivesNoItems;
    procedure TestASecretNeverAppearsInASummary;
  end;

implementation

{ Every slug resolves except the ones a test deliberately denies. }
function AnyAdapter(const AKey: string): Boolean;
begin
  Result := (AKey = 'fireworks') or (AKey = 'openrouter') or (AKey = 'openai');
end;

function NoAdapter(const AKey: string): Boolean;
begin
  Result := False;
end;

function TProviderDialogTest.MakeRow(const AName, AKey, AModel: string): TProviderRow;
begin
  Result := Default(TProviderRow);
  Result.Name := AName;
  Result.Key := AKey;
  Result.Model := AModel;
end;

function TProviderDialogTest.ItemsOf(
  const ARows: TProviderRowArray): TProviderListItemArray;
begin
  Result := ProviderListItems(ARows, AnyAdapter);
end;

procedure TProviderDialogTest.TestSummaryNamesSlugModelAndParameters;
var
  R: TProviderRow;
begin
  R := MakeRow('work', 'openrouter', 'openai/gpt-4o');
  R.Temperature := 0.3;
  R.HasTemperature := True;
  AssertEquals('slug, model and the set parameter',
    'openrouter - openai/gpt-4o - temp 0.3', ProviderSummary(R));
end;

procedure TProviderDialogTest.TestSummaryOmitsUnsetParameters;
var
  R: TProviderRow;
begin
  { An unset parameter is NOT zero - it is "not configured". Showing
    "temp 0" for an unset temperature would tell the operator the opposite of
    the truth, and is the same sentinel mistake the request body refuses. }
  R := MakeRow('bare', 'openrouter', 'some/model');
  AssertEquals('only what is set', 'openrouter - some/model',
    ProviderSummary(R));
  AssertTrue('no temp shown', Pos('temp', ProviderSummary(R)) = 0);
end;

procedure TProviderDialogTest.TestAProviderWithNoAdapterIsShownUnusable;
var
  Rows: TProviderRowArray;
  Items: TProviderListItemArray;
begin
  { THE regression that matters. A row naming a slug with no adapter cannot be
    spoken to. Hiding it would make a broken configuration invisible; showing it
    as unusable is what lets the operator fix it. }
  SetLength(Rows, 1);
  Rows[0] := MakeRow('stale', 'not-a-real-provider', 'm');
  Items := ItemsOf(Rows);
  AssertEquals('still listed', 1, Length(Items));
  AssertFalse('and marked unusable', Items[0].Usable);
  AssertEquals('with the reason, not a summary', NoAdapterReason,
    Items[0].Summary);
end;

procedure TProviderDialogTest.TestAnEmptyKeyIsUnusable;
var
  Rows: TProviderRowArray;
  Items: TProviderListItemArray;
begin
  { A row with no Key predates the Name/Key split, or was written by hand. It is
    not a provider we can speak to, and guessing a slug for it would be worse. }
  SetLength(Rows, 1);
  Rows[0] := MakeRow('legacy', '', 'm');
  Items := ProviderListItems(Rows, AnyAdapter);
  AssertEquals('listed', 1, Length(Items));
  AssertFalse('unusable', Items[0].Usable);
end;

procedure TProviderDialogTest.TestTheActiveProviderIsMarked;
var
  Rows: TProviderRowArray;
  Items: TProviderListItemArray;
begin
  SetLength(Rows, 2);
  Rows[0] := MakeRow('a', 'fireworks', 'm1');
  Rows[0].Active := False;
  Rows[1] := MakeRow('b', 'openrouter', 'm2');
  Rows[1].Active := True;
  Items := ItemsOf(Rows);
  AssertFalse('first is not active', Items[0].Active);
  AssertTrue('second is', Items[1].Active);
end;

procedure TProviderDialogTest.TestAnUnnamedRowIsSkipped;
var
  Rows: TProviderRowArray;
  Items: TProviderListItemArray;
begin
  { Activation and deletion are BY NAME, so an unnamed row is something the
    operator cannot act on. Shown, it would be a dead entry. }
  SetLength(Rows, 2);
  Rows[0] := MakeRow('', 'fireworks', 'm');
  Rows[1] := MakeRow('real', 'fireworks', 'm');
  Items := ItemsOf(Rows);
  AssertEquals('only the named one', 1, Length(Items));
  AssertEquals('and it is the real one', 'real', Items[0].Name);
end;

procedure TProviderDialogTest.TestAnEmptyStoreGivesNoItems;
var
  Items: TProviderListItemArray;
begin
  Items := ProviderListItems(nil, AnyAdapter);
  AssertEquals('no items', 0, Length(Items));
end;

procedure TProviderDialogTest.TestASecretNeverAppearsInASummary;
var
  R: TProviderRow;
  S: string;
begin
  { The summary is built from the row, and the row has no secret field - the key
    lives in `settings` (Stage 2). This test exists so that stays true if anyone
    later adds a convenient field. }
  R := MakeRow('work', 'openrouter', 'openai/gpt-4o');
  S := ProviderSummary(R);
  AssertTrue('no bearer', Pos('Bearer', S) = 0);
  AssertTrue('no sk- prefix', Pos('sk-', S) = 0);
end;

initialization
  RegisterTest(TProviderDialogTest);
end.
