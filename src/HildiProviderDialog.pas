unit HildiProviderDialog;
{ The /provider list, and the pure function behind it.

  WHY THE LIST IS A PURE FUNCTION: a dialog cannot be unit-tested without a
  surface, and the facts an operator needs to see - which provider is active,
  which slug it names, whether that slug resolves to an adapter at all - are
  exactly the facts most likely to be wrong. So the assembly is a function of
  (rows, resolver) and the widget only renders what it returns.

  This unit deliberately does NOT talk to the HTTP layer or the models catalogue.
  Listing and selecting is v1; editing and model discovery are later, and the
  narrower surface is what makes those additions safe. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, HildiStore;

type
  { One row as the dialog needs it. }
  TProviderListItem = record
    Name: string;          // the operator's label
    Key: string;           // the provider slug: fireworks | openrouter | openai
    Endpoint: string;
    Model: string;
    Active: Boolean;
    { False when Key names no registered adapter. The row is still SHOWN: a
      provider that cannot resolve is a fact the operator must see and fix,
      never one to hide - hiding it would make the failure invisible. }
    Usable: Boolean;
    { A short human line: "openrouter - openai/gpt-4o - temp 0.3" }
    Summary: string;
  end;

  TProviderListItemArray = array of TProviderListItem;

  { Whether a slug resolves to an adapter. Injected so this unit needs no
    dependency on the provider library, and so a test can say "this one does,
    that one does not" without registering anything. }
  TProviderHasAdapter = function(const AKey: string): Boolean;

{ Build the display items. Pure: same inputs, same output, no I/O. }
function ProviderListItems(const ARows: TProviderRowArray;
  AHasAdapter: TProviderHasAdapter): TProviderListItemArray;

{ The one-line summary for a row. Exported so the format is pinned by a test. }
function ProviderSummary(const ARow: TProviderRow): string;

{ The slug a row should be resolved through. Empty when the row predates the
  Name/Key split, which the caller must show as unusable rather than guess. }
function ProviderSlug(const ARow: TProviderRow): string;

const
  { Shown instead of a summary when a row cannot resolve. }
  NoAdapterReason = 'no adapter for this provider key';

implementation

function ProviderSlug(const ARow: TProviderRow): string;
begin
  Result := Trim(ARow.Key);
end;

function ProviderSummary(const ARow: TProviderRow): string;
var
  Parts: string;

  procedure Add(const AText: string);
  begin
    if AText = '' then
      Exit;
    if Parts <> '' then
      Parts := Parts + ' - ';
    Parts := Parts + AText;
  end;

begin
  Parts := '';
  Add(ProviderSlug(ARow));
  Add(ARow.Model);
  { Only parameters that are SET. An unset parameter is not "0", it is "not
    configured", and showing nothing is the honest rendering. }
  if ARow.HasTemperature then
    Add(Format('temp %g', [ARow.Temperature]));
  if ARow.HasTopP then
    Add(Format('top_p %g', [ARow.TopP]));
  if ARow.HasMaxTokens then
    Add(Format('max %d', [ARow.MaxTokens]));
  if ARow.HasSeed then
    Add(Format('seed %d', [ARow.Seed]));
  if Length(ARow.Stop) > 0 then
    Add('stop x' + IntToStr(Length(ARow.Stop)));
  if Parts = '' then
    Parts := '(unconfigured)';
  Result := Parts;
end;

function ProviderListItems(const ARows: TProviderRowArray;
  AHasAdapter: TProviderHasAdapter): TProviderListItemArray;

  { A row is usable only when it names a slug AND that slug resolves. An empty
    slug is not a provider we can speak to; it is a row that needs fixing. }
  function UsableRow(const ARow: TProviderRow): Boolean;
  var
    Slug: string;
  begin
    Slug := ProviderSlug(ARow);
    Result := (Slug <> '') and Assigned(AHasAdapter) and AHasAdapter(Slug);
  end;

var
  I: Integer;
  Row: TProviderRow;
  Item: TProviderListItem;
  Ok: Boolean;
begin
  Result := nil;
  for I := 0 to High(ARows) do
  begin
    Row := ARows[I];
    { An empty name cannot be addressed by any other surface - activation and
      deletion are BY NAME - so an unnamed row is skipped rather than shown as
      something the operator cannot act on. }
    if Trim(Row.Name) = '' then
      Continue;
    Item := Default(TProviderListItem);
    Item.Name := Row.Name;
    Item.Key := ProviderSlug(Row);
    Item.Endpoint := Row.Endpoint;
    Item.Model := Row.Model;
    Item.Active := Row.Active;
    Ok := UsableRow(Row);
    Item.Usable := Ok;
    if Ok then
      Item.Summary := ProviderSummary(Row)
    else
      Item.Summary := NoAdapterReason;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Item;
  end;
end;

end.
