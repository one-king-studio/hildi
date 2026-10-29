unit test_session_client;
{ Tests for the session wire client's runtime-binary resolution. The transport
  and connection paths are covered by the runtime integration suite. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  hildi.session.client;

type
  TSessionClientTest = class(TTestCase)
  private
    FTempDir: string;
    function Touch(const APath: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestExplicitPathWins;
    procedure TestSiblingFallback;
    procedure TestEmptyWhenNeitherExists;
    procedure TestExplicitMustExist;
  end;

implementation

procedure TSessionClientTest.SetUp;
begin
  FTempDir := GetTempDir + 'hildi-client-test-' + IntToStr(Random(MaxInt)) +
    PathDelim;
  ForceDirectories(FTempDir);
end;

procedure TSessionClientTest.TearDown;
begin
  if FTempDir = '' then
    Exit;
  DeleteFile(FTempDir + 'custom-agent');
  DeleteFile(FTempDir + DefaultRuntimeBinary);
  RemoveDir(FTempDir);
end;

function TSessionClientTest.Touch(const APath: string): string;
var
  F: TFileStream;
begin
  F := TFileStream.Create(APath, fmCreate);
  F.Free;
  Result := APath;
end;

procedure TSessionClientTest.TestExplicitPathWins;
var
  Explicit: string;
begin
  Explicit := Touch(FTempDir + 'custom-agent');
  AssertEquals('explicit path', Explicit,
    ResolveRuntimeBinary(Explicit, FTempDir + 'hildi'));
end;

procedure TSessionClientTest.TestSiblingFallback;
var
  Sibling: string;
begin
  Sibling := Touch(FTempDir + DefaultRuntimeBinary);
  AssertEquals('sibling', Sibling,
    ResolveRuntimeBinary('', FTempDir + 'hildi'));
end;

procedure TSessionClientTest.TestEmptyWhenNeitherExists;
begin
  AssertEquals('nothing', '',
    ResolveRuntimeBinary('', FTempDir + 'hildi'));
end;

procedure TSessionClientTest.TestExplicitMustExist;
var
  Sibling: string;
begin
  Sibling := Touch(FTempDir + DefaultRuntimeBinary);
  AssertEquals('falls back', Sibling,
    ResolveRuntimeBinary(FTempDir + 'missing-agent',
      FTempDir + 'hildi'));
end;

initialization
  RegisterTest(TSessionClientTest);
end.
