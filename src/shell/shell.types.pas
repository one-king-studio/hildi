unit shell.types;
{ The shell library's shared types: the environment, a command call and its
  result, the handler and gate seams, the execution limits, and the parse error.

  The library is standalone: nothing here may reach a hildegard.helper.* unit.
  Commands are capabilities the consumer registers; the gate is its policy. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes;

type
  { The shell environment. Case-sensitive, like the shell itself. }
  TShellEnv = class
  private
    FValues: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    function Get(const AName: string): string;
    function Has(const AName: string): Boolean;
    procedure SetValue(const AName, AValue: string);
    procedure Unset(const AName: string);
    { The variable names, in insertion order. }
    function Names: TStringArray;
    procedure CopyFrom(AOther: TShellEnv);
    function Clone: TShellEnv;
  end;

  { One command invocation. Args are the expanded words after the command name. }
  TShellCall = record
    Name: string;
    Args: TStringArray;
    Stdin: string;
    Cwd: string;
    Env: TShellEnv;
  end;

  TShellResult = record
    Stdout: string;
    Stderr: string;
    ExitCode: Integer;
  end;

  TShellHandler = function(const ACall: TShellCall): TShellResult of object;

  { Consulted before a registered handler. False = denied: the handler never
    runs, and the interpreter reports stderr + status 126. }
  TShellGate = function(const ACall: TShellCall): Boolean of object;

  { Every bound is mandatory. 0 takes the default from DefaultShellLimits. }
  TShellLimits = record
    MaxCommands: Integer;
    MaxLoopIterations: Integer;
    MaxCallDepth: Integer;
    MaxOutputBytes: Integer;
    MaxExecutionTimeMs: Int64;
  end;

  TShellParseError = record
    Offset: Integer;
    Line: Integer;
    Column: Integer;
    Message: string;
  end;

function DefaultShellLimits: TShellLimits;
function ShellResultOk(const AStdout: string; AExitCode: Integer = 0): TShellResult;
function ShellResultErr(const AStderr: string; AExitCode: Integer = 1): TShellResult;

implementation

constructor TShellEnv.Create;
begin
  inherited Create;
  FValues := TStringList.Create;
  FValues.CaseSensitive := True;
  FValues.NameValueSeparator := '=';
end;

destructor TShellEnv.Destroy;
begin
  FValues.Free;
  inherited Destroy;
end;

function TShellEnv.Get(const AName: string): string;
var
  I: Integer;
begin
  I := FValues.IndexOfName(AName);
  if I < 0 then
    Result := ''
  else
    Result := FValues.ValueFromIndex[I];
end;

function TShellEnv.Has(const AName: string): Boolean;
begin
  Result := FValues.IndexOfName(AName) >= 0;
end;

procedure TShellEnv.SetValue(const AName, AValue: string);
var
  I: Integer;
begin
  I := FValues.IndexOfName(AName);
  if I < 0 then
    FValues.Add(AName + '=' + AValue)
  else
    FValues[I] := AName + '=' + AValue;
end;

procedure TShellEnv.Unset(const AName: string);
var
  I: Integer;
begin
  I := FValues.IndexOfName(AName);
  if I >= 0 then
    FValues.Delete(I);
end;

function TShellEnv.Names: TStringArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, FValues.Count);
  for I := 0 to FValues.Count - 1 do
    Result[I] := FValues.Names[I];
end;

procedure TShellEnv.CopyFrom(AOther: TShellEnv);
begin
  FValues.Assign(AOther.FValues);
end;

function TShellEnv.Clone: TShellEnv;
begin
  Result := TShellEnv.Create;
  Result.CopyFrom(Self);
end;

function DefaultShellLimits: TShellLimits;
begin
  Result.MaxCommands := 10000;
  Result.MaxLoopIterations := 10000;
  Result.MaxCallDepth := 100;
  Result.MaxOutputBytes := 1024 * 1024;
  Result.MaxExecutionTimeMs := 30000;
end;

function ShellResultOk(const AStdout: string; AExitCode: Integer): TShellResult;
begin
  Result := Default(TShellResult);
  Result.Stdout := AStdout;
  Result.ExitCode := AExitCode;
end;

function ShellResultErr(const AStderr: string; AExitCode: Integer): TShellResult;
begin
  Result := Default(TShellResult);
  Result.Stderr := AStderr;
  Result.ExitCode := AExitCode;
end;

end.
