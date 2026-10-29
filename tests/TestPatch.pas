unit TestPatch;
{ fpcunit tests for HildiPatch: the unified-diff applier, against
  an in-memory file via the injected read/write callbacks. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, HildiPatch;

type
  { A one-file in-memory host: Read returns FText, Write records the result. }
  TMemIO = class
  public
    Text: string;
    Wrote: string;
    WriteCalls: Integer;
    function Read(const APath: string; out AText: string;
      out AError: string): Boolean;
    function Write(const APath: string; const AText: string;
      out AError: string): Boolean;
  end;

  TPatchTest = class(TTestCase)
  private
    FIO: TMemIO;
    function Apply(const APatch: string; AStrip: Integer; ADryRun: Boolean;
      out R: TPatchResult): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestAppliesACleanHunk;
    procedure TestBadContextIsRejectedNotFatal;
    procedure TestDryRunWritesNothing;
    procedure TestMultipleHunks;
  end;

implementation

function TMemIO.Read(const APath: string; out AText: string;
  out AError: string): Boolean;
begin
  AText := Text;
  AError := '';
  Result := True;
end;

function TMemIO.Write(const APath: string; const AText: string;
  out AError: string): Boolean;
begin
  Wrote := AText;
  Inc(WriteCalls);
  AError := '';
  Result := True;
end;

procedure TPatchTest.SetUp;
begin
  FIO := TMemIO.Create;
end;

procedure TPatchTest.TearDown;
begin
  FIO.Free;
  FIO := nil;
end;

function TPatchTest.Apply(const APatch: string; AStrip: Integer;
  ADryRun: Boolean; out R: TPatchResult): Boolean;
var
  Err: string;
begin
  Result := ApplyUnifiedPatch(APatch, AStrip, ADryRun, FIO.Read, FIO.Write, R,
    Err);
end;

procedure TPatchTest.TestAppliesACleanHunk;
var
  R: TPatchResult;
  Patch: string;
begin
  FIO.Text := 'one' + #10 + 'two' + #10 + 'three' + #10;
  Patch := '--- a/a.txt' + #10 + '+++ b/a.txt' + #10 +
    '@@ -1,3 +1,3 @@' + #10 + ' one' + #10 + '-two' + #10 + '+TWO' + #10 +
    ' three' + #10;
  AssertTrue('applied', Apply(Patch, 1, False, R));
  AssertEquals('one hunk', 1, R.Applied);
  AssertEquals('none rejected', 0, R.Rejected);
  AssertEquals('file patched', 'one' + #10 + 'TWO' + #10 + 'three' + #10,
    FIO.Wrote);
end;

procedure TPatchTest.TestBadContextIsRejectedNotFatal;
var
  R: TPatchResult;
  Patch: string;
begin
  { The context line does not match: the hunk is rejected, not an exception. }
  FIO.Text := 'alpha' + #10 + 'beta' + #10;
  Patch := '--- a/a.txt' + #10 + '+++ b/a.txt' + #10 +
    '@@ -1,2 +1,2 @@' + #10 + ' nope' + #10 + '-beta' + #10 + '+BETA' + #10;
  AssertTrue('ran', Apply(Patch, 1, False, R));
  AssertEquals('rejected', 1, R.Rejected);
  AssertEquals('nothing applied', 0, R.Applied);
end;

procedure TPatchTest.TestDryRunWritesNothing;
var
  R: TPatchResult;
  Patch: string;
begin
  FIO.Text := 'one' + #10 + 'two' + #10 + 'three' + #10;
  Patch := '--- a/a.txt' + #10 + '+++ b/a.txt' + #10 +
    '@@ -1,3 +1,3 @@' + #10 + ' one' + #10 + '-two' + #10 + '+TWO' + #10 +
    ' three' + #10;
  AssertTrue('ran', Apply(Patch, 1, True, R));
  AssertEquals('would apply', 1, R.Applied);
  AssertEquals('no write', 0, FIO.WriteCalls);
end;

procedure TPatchTest.TestMultipleHunks;
var
  R: TPatchResult;
  Patch: string;
begin
  FIO.Text := 'a' + #10 + 'b' + #10 + 'c' + #10 + 'd' + #10 + 'e' + #10;
  Patch := '--- a/a.txt' + #10 + '+++ b/a.txt' + #10 +
    '@@ -1,2 +1,2 @@' + #10 + ' a' + #10 + '-b' + #10 + '+B' + #10 +
    '@@ -4,2 +4,2 @@' + #10 + ' d' + #10 + '-e' + #10 + '+E' + #10;
  AssertTrue('applied', Apply(Patch, 1, False, R));
  AssertEquals('two hunks', 2, R.Applied);
  AssertEquals('patched', 'a' + #10 + 'B' + #10 + 'c' + #10 + 'd' + #10 +
    'E' + #10, FIO.Wrote);
end;

initialization
  RegisterTest(TPatchTest);
end.
