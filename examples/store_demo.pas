program store_demo;
{ Demo: exercise the embedded SQLite store. Opens a temporary database, saves
  credentials, enqueues a request, claims and finishes it, and reads it back.

  Run:  make store-demo && ./build/bin/hildegard-helper-store-demo }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}   // must come first on Unix
  SysUtils, hildegard.helper.store;

var
  Cfg: TStoreConfig;
  Store: TSqliteStore;
  Err: TStoreError;
  Cred: TDeviceCredentials;
  Req, Claimed, Fetched: TStoredRequest;
  Query: TRequestQuery;
  List: TStoredRequestArray;
  Path: string;

procedure Fail(const AWhere: string);
begin
  WriteLn('FAILED at ', AWhere, ': ', Err.Message, ' / ', Err.Detail);
  Halt(1);
end;

begin
  Path := IncludeTrailingPathDelimiter(GetTempDir) + 'hildegard_store_demo.db';
  DeleteFile(Path);
  DeleteFile(Path + '-wal');
  DeleteFile(Path + '-shm');

  Cfg.DatabasePath := Path;
  Cfg.LibraryPath := '';
  Cfg.BusyTimeoutMs := 5000;

  Store := TSqliteStore.Create(Cfg);
  try
    if not Store.Open(Err) then
      Fail('Open');
    WriteLn('opened ', Path, ' (schema v', StoreSchemaVersion, ')');

    Cred := Default(TDeviceCredentials);
    Cred.DeviceId := 'demo-device';
    Cred.Token := 'demo-token';
    Cred.Endpoint := 'https://api.fireworks.ai';
    Cred.AccountId := 'demo-account';
    if not Store.SaveCredentials(Cred, Err) then
      Fail('SaveCredentials');
    WriteLn('credentials saved');

    Req := Default(TStoredRequest);
    Req.Id := 'req-1';
    Req.Kind := 'shell';
    Req.Payload := '{"cmd":"date"}';
    if not Store.EnqueueRequest(Req, Err) then
      Fail('EnqueueRequest');
    WriteLn('enqueued ', Req.Id);

    if not Store.ClaimNextPending(Claimed, Err) then
      Fail('ClaimNextPending');
    WriteLn('claimed ', Claimed.Id, ' kind=', Claimed.Kind,
      ' payload=', Claimed.Payload);

    if not Store.FinishRequest(Claimed.Id, rsCompleted, 0, 'ok', Err) then
      Fail('FinishRequest');

    if not Store.GetRequest('req-1', Fetched, Err) then
      Fail('GetRequest');
    WriteLn('finished request status=', Ord(Fetched.Status),
      ' result=', Fetched.Result);

    Query.UseStatus := True;
    Query.Status := rsCompleted;
    Query.Limit := 0;
    Query.Offset := 0;
    if not Store.QueryRequests(Query, List, Err) then
      Fail('QueryRequests');
    WriteLn('completed requests: ', Length(List));
  finally
    Store.Free;
  end;

  DeleteFile(Path);
  DeleteFile(Path + '-wal');
  DeleteFile(Path + '-shm');
  WriteLn('store demo done');
end.
