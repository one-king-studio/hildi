unit HildiApprovalStore;
{ SQLite-backed IApprovalStore. Keeps the approval unit free of the store and
  the store free of the adapter. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, HildiApproval, HildiStore;

type
  TStoreApprovalStore = class(TInterfacedObject, IApprovalStore)
  private
    FStore: TSqliteStore;
  public
    constructor Create(AStore: TSqliteStore);
    function Load(const AContext: TApprovalContext;
      out ARules: TApprovalRuleArray; out AError: string): Boolean;
    function Save(const ARule: TApprovalRule; out AError: string): Boolean;
    function Remove(const ARule: TApprovalRule; out AError: string): Boolean;
  end;

implementation

function StoreErrText(const AError: TStoreError): string;
begin
  Result := AError.Message;
  if AError.Detail <> '' then
    Result := Result + ' (' + AError.Detail + ')';
end;

constructor TStoreApprovalStore.Create(AStore: TSqliteStore);
begin
  inherited Create;
  FStore := AStore;
end;

function TStoreApprovalStore.Load(const AContext: TApprovalContext;
  out ARules: TApprovalRuleArray; out AError: string): Boolean;
var
  StoreError: TStoreError;
begin
  AError := '';
  if FStore = nil then
  begin
    ARules := nil;
    AError := 'no store';
    Exit(False);
  end;
  if not FStore.LoadApprovals(AContext, ARules, StoreError) then
  begin
    AError := StoreErrText(StoreError);
    Exit(False);
  end;
  Result := True;
end;

function TStoreApprovalStore.Save(const ARule: TApprovalRule;
  out AError: string): Boolean;
var
  StoreError: TStoreError;
begin
  AError := '';
  if FStore = nil then
  begin
    AError := 'no store';
    Exit(False);
  end;
  if not FStore.SaveApproval(ARule, StoreError) then
  begin
    AError := StoreErrText(StoreError);
    Exit(False);
  end;
  Result := True;
end;

function TStoreApprovalStore.Remove(const ARule: TApprovalRule;
  out AError: string): Boolean;
var
  StoreError: TStoreError;
begin
  AError := '';
  if FStore = nil then
  begin
    AError := 'no store';
    Exit(False);
  end;
  if not FStore.RemoveApproval(ARule, StoreError) then
  begin
    AError := StoreErrText(StoreError);
    Exit(False);
  end;
  Result := True;
end;

end.
