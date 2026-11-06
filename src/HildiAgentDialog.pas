unit HildiAgentDialog;
{ The /agent list, and the pure function behind it.

  Same split as HildiProviderDialog, for the same reason: a dialog cannot be
  unit-tested, but the facts an operator must see CAN be. An agent is a
  behaviour, so what matters is which one is active, what model and provider it
  points at, and whether those resolve.

  No store, no dialog, no HTTP here. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, HildiStore;

type
  TAgentListItem = record
    Name: string;             // the operator's label; 'hildi' is built in
    ProviderName: string;
    Model: string;
    Active: Boolean;
    { False when the agent names a provider that does not exist. SHOWN anyway: an
      agent pointing at a missing connection is a fact to see and fix, and hiding
      it would make the breakage invisible until a turn failed. }
    ProviderExists: Boolean;
    { One line: "openrouter - openai/gpt-4o - temp 0.2 - prompt" }
    Summary: string;
  end;

  TAgentListItemArray = array of TAgentListItem;

  { Whether a provider name resolves. Injected so this unit needs no store. }
  TAgentHasProvider = function(const AName: string): Boolean;

{ Build the display items. Pure. }
function AgentListItems(const ARows: TAgentRowArray;
  AHasProvider: TAgentHasProvider): TAgentListItemArray;

{ The one-line summary. Exported so the format is pinned by a test. }
function AgentSummary(const ARow: TAgentRow): string;

const
  MissingProviderReason = 'provider not configured';

implementation

function AgentSummary(const ARow: TAgentRow): string;
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
  Add(ARow.ProviderName);
  Add(ARow.Model);
  { Only parameters that are SET. An unset parameter is "not configured", not
    zero - the same distinction the request body makes. }
  if ARow.HasTemperature then
    Add(Format('temp %g', [ARow.Temperature]));
  if ARow.HasTopP then
    Add(Format('top_p %g', [ARow.TopP]));
  if ARow.HasMaxTokens then
    Add(Format('max %d', [ARow.MaxTokens]));
  if ARow.HasSeed then
    Add(Format('seed %d', [ARow.Seed]));
  if ARow.ReasoningEffort <> '' then
    Add('effort ' + ARow.ReasoningEffort);
  if ARow.Tier <> '' then
    Add('tier ' + ARow.Tier);
  { The presence of a behaviour prompt is worth knowing at a glance - it is what
    makes an agent more than a model choice. The TEXT does not go in the summary. }
  if ARow.SystemPrompt <> '' then
    Add('prompt');
  if Parts = '' then
    Parts := '(no provider or model)';
  Result := Parts;
end;

function AgentListItems(const ARows: TAgentRowArray;
  AHasProvider: TAgentHasProvider): TAgentListItemArray;
var
  I: Integer;
  Row: TAgentRow;
  Item: TAgentListItem;
  Ok: Boolean;
begin
  Result := nil;
  for I := 0 to High(ARows) do
  begin
    Row := ARows[I];
    { An unnamed agent cannot be addressed - activation and deletion are BY NAME
      - so it is skipped rather than shown as something unactionable. }
    if Trim(Row.Name) = '' then
      Continue;
    Item := Default(TAgentListItem);
    Item.Name := Row.Name;
    Item.ProviderName := Row.ProviderName;
    Item.Model := Row.Model;
    Item.Active := Row.Active;
    { An agent with NO provider named is fine: it inherits the active provider.
      Only a name that does not resolve is a problem. }
    Ok := (Row.ProviderName = '') or
      (Assigned(AHasProvider) and AHasProvider(Row.ProviderName));
    Item.ProviderExists := Ok;
    if Ok then
      Item.Summary := AgentSummary(Row)
    else
      Item.Summary := MissingProviderReason + ': ' + Row.ProviderName;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Item;
  end;
end;

end.
