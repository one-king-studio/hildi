unit hildegard.helper.harness.subagent.spy;
{ A second observer of one child session: it attaches to the child's runtime with
  the observe role (never drive) and maps the child's event stream onto the same
  TTurnEvents the chat panel already consumes. The app drains it with PopEvent.

  Closing releases the observer's socket; the child keeps running. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils,
  hildegard.helper.session.protocol, hildegard.helper.session.client,
  hildegard.helper.harness.turn, hildegard.helper.harness.driver;

type
  TSubagentSpy = class;

  { Maps a child's wire events onto the spy's queue. Runs on the client's reader
    thread. }
  TSpySink = class(TInterfacedObject, ISessionSink)
  private
    FQueue: TTurnQueue;
  public
    constructor Create(AQueue: TTurnQueue);
    procedure OnHello(const AHello: TSessionHello);
    procedure OnAttached(const AAttached: TSessionAttached);
    procedure OnEvent(const AEvent: TSessionEvent);
    procedure OnDetached(const AReason: string);
    procedure OnError(const ACode, AMessage: string);
  end;

  TSubagentSpy = class
  private
    FSessionId: string;
    FQueue: TTurnQueue;
    FSink: TSpySink;
    FSinkRef: ISessionSink;
    FClient: TSessionClient;
  public
    { Attach to a running child as an observer (Spawn is forced off). Returns
      nil with AError when the child is unreachable. }
    class function Open(const ASessionId: string;
      const AConfig: TSessionClientConfig; out AError: string): TSubagentSpy;
    destructor Destroy; override;
    { UI thread: pop the next child event, if any. }
    function PopEvent(out AEvent: TTurnEvent): Boolean;
    function SessionId: string;
    { Release the observer connection and join the reader. Idempotent. }
    procedure Close;
  end;

implementation

constructor TSpySink.Create(AQueue: TTurnQueue);
begin
  inherited Create;
  FQueue := AQueue;
end;

procedure TSpySink.OnHello(const AHello: TSessionHello);
begin
end;

procedure TSpySink.OnAttached(const AAttached: TSessionAttached);
begin
end;

procedure TSpySink.OnEvent(const AEvent: TSessionEvent);
var
  E: TTurnEvent;
begin
  if MapSessionEvent(AEvent, E) then
    FQueue.Push(E);
end;

procedure TSpySink.OnDetached(const AReason: string);
begin
end;

procedure TSpySink.OnError(const ACode, AMessage: string);
begin
end;

class function TSubagentSpy.Open(const ASessionId: string;
  const AConfig: TSessionClientConfig; out AError: string): TSubagentSpy;
var
  Spy: TSubagentSpy;
  Cfg: TSessionClientConfig;
  Client: TSessionClient;
begin
  Result := nil;
  AError := '';
  Spy := TSubagentSpy.Create;
  try
    Cfg := AConfig;
    Cfg.SessionId := ASessionId;
    Cfg.Role := srObserve;   // a spy never drives
    Cfg.Spawn := False;      // the child already runs
    Spy.FSessionId := ASessionId;
    Spy.FQueue := TTurnQueue.Create;
    Spy.FSink := TSpySink.Create(Spy.FQueue);
    Spy.FSinkRef := Spy.FSink;
    Client := TSessionClient.Open(Cfg, Spy.FSinkRef, AError);
    if Client = nil then
    begin
      Spy.Free;
      Exit(nil);
    end;
    Spy.FClient := Client;
  except
    on E: Exception do
    begin
      Spy.Free;
      AError := E.Message;
      Exit(nil);
    end;
  end;
  Result := Spy;
end;

destructor TSubagentSpy.Destroy;
begin
  Close;
  FQueue.Free;
  inherited Destroy;
end;

function TSubagentSpy.PopEvent(out AEvent: TTurnEvent): Boolean;
begin
  Result := FQueue.Pop(AEvent);
end;

function TSubagentSpy.SessionId: string;
begin
  Result := FSessionId;
end;

procedure TSubagentSpy.Close;
begin
  if FClient <> nil then
  begin
    FClient.Free;
    FClient := nil;
  end;
  FSinkRef := nil;
  FSink := nil;
end;

end.
