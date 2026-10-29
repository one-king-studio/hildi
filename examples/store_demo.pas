program store_demo;
{ Demo: exercise the embedded SQLite store. Opens a temporary database, saves
  credentials, registers a workspace, starts a session, appends a ledger record,
  lists sessions, and round-trips a setting.

  Run:  make store-demo && ./build/bin/hildi-store-demo }

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}   // must come first on Unix
  SysUtils, hildi.store, hildi.session;

var
  Cfg: TStoreConfig;
  Store: TSqliteStore;
  Err: TStoreError;
  Cred, Loaded: TDeviceCredentials;
  Rec: TMessageRecord;
  TurnId: Int64;
  Summaries: TSessionSummaryArray;
  Path, SessionId, Value: string;
  WorkspaceId: Integer;

procedure Fail(const AWhere: string);
begin
  WriteLn('FAILED at ', AWhere, ': ', Err.Message, ' / ', Err.Detail);
  Halt(1);
end;

begin
  Path := IncludeTrailingPathDelimiter(GetTempDir) + 'hildi_store_demo.db';
  DeleteFile(Path);
  DeleteFile(Path + '-wal');
  DeleteFile(Path + '-shm');

  Cfg.DatabasePath := Path;
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
    if not Store.LoadCredentials(Loaded, Err) then
      Fail('LoadCredentials');
    WriteLn('credentials round trip: ', Loaded.DeviceId);

    if not Store.EnsureWorkspace('/tmp', WorkspaceId, Err) then
      Fail('EnsureWorkspace');
    WriteLn('workspace id: ', WorkspaceId);

    if not Store.CreateSession(WorkspaceId, SessionId, Err) then
      Fail('CreateSession');
    if not Store.BeginTurn(SessionId, TurnId, Err) then
      Fail('BeginTurn');
    Rec := Default(TMessageRecord);
    Rec.SessionId := SessionId;
    Rec.TurnId := TurnId;
    Rec.Role := mrUser;
    Rec.Content := 'hello';
    if not Store.AppendMessage(Rec, Err) then
      Fail('AppendMessage');
    if not Store.FinishTurn(TurnId, tsCompleted, 'stop', 0, '', '', Err) then
      Fail('FinishTurn');

    if not Store.ListSessions(WorkspaceId, Summaries, Err) then
      Fail('ListSessions');
    WriteLn('session ', SessionId, ' messages=', Summaries[0].MessageCount,
      ' turns=', Summaries[0].TurnCount);

    if not Store.SetSetting('demo.key', 'demo.value', Err) then
      Fail('SetSetting');
    if not Store.GetSetting('demo.key', Value, Err) then
      Fail('GetSetting');
    WriteLn('setting round trip: ', Value);
  finally
    Store.Free;
  end;

  DeleteFile(Path);
  DeleteFile(Path + '-wal');
  DeleteFile(Path + '-shm');
  WriteLn('store demo done');
end.
