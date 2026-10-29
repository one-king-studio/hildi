unit ShellRegistry;
{ The command registry: a name maps to a handler. The consumer fills it; an
  unregistered name is `command not found`. Names are case-sensitive, like the
  shell. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, ShellTypes;

type
  TShellRegistry = class
  private
    FNames: TStringList;
    FHandlers: array of TShellHandler;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Register(const AName: string; AHandler: TShellHandler);
    function Resolve(const AName: string; out AHandler: TShellHandler): Boolean;
    function Count: Integer;
  end;

implementation

constructor TShellRegistry.Create;
begin
  inherited Create;
  FNames := TStringList.Create;
  FNames.CaseSensitive := True;
  FNames.Sorted := False;
  FHandlers := nil;
end;

destructor TShellRegistry.Destroy;
begin
  FNames.Free;
  inherited Destroy;
end;

procedure TShellRegistry.Register(const AName: string; AHandler: TShellHandler);
var
  I, N: Integer;
begin
  I := FNames.IndexOf(AName);
  if I >= 0 then
  begin
    FHandlers[I] := AHandler;
    Exit;
  end;
  N := Length(FHandlers);
  SetLength(FHandlers, N + 1);
  FHandlers[N] := AHandler;
  FNames.Add(AName);
end;

function TShellRegistry.Resolve(const AName: string;
  out AHandler: TShellHandler): Boolean;
var
  I: Integer;
begin
  AHandler := nil;
  I := FNames.IndexOf(AName);
  Result := I >= 0;
  if Result then
    AHandler := FHandlers[I];
end;

function TShellRegistry.Count: Integer;
begin
  Result := FNames.Count;
end;

end.
