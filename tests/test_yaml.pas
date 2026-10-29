unit test_yaml;
{ fpcunit tests for hildi.yaml: the minimal YAML subset - mappings,
  nested mappings, sequences, scalars - and the out-of-subset errors. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, fpjson, hildi.yaml;

type
  TYamlTest = class(TTestCase)
  published
    procedure TestFlatMapping;
    procedure TestNestedMapping;
    procedure TestSequence;
    procedure TestScalarTypes;
    procedure TestSameIndentSequenceUnderKey;
    procedure TestSetPath;
    procedure TestTabIndentIsAnError;
    procedure TestRoundTrip;
  end;

implementation

function Parse(const S: string): TJSONData;
var
  Err: string;
begin
  Result := ParseYaml(S, Err);
  if Result = nil then
    raise Exception.Create('yaml: ' + Err);
end;

procedure TYamlTest.TestFlatMapping;
var
  D: TJSONData;
begin
  D := Parse('name: app' + #10 + 'count: 3');
  try
    AssertEquals('name', 'app', TJSONObject(D).Get('name', ''));
    AssertEquals('count', 3, TJSONObject(D).Get('count', 0));
  finally
    D.Free;
  end;
end;

procedure TYamlTest.TestNestedMapping;
var
  D: TJSONData;
  Sub: TJSONObject;
begin
  D := Parse('server:' + #10 + '  host: localhost' + #10 + '  port: 8080');
  try
    Sub := TJSONObject(TJSONObject(D).Find('server'));
    AssertEquals('host', 'localhost', Sub.Get('host', ''));
    AssertEquals('port', 8080, Sub.Get('port', 0));
  finally
    D.Free;
  end;
end;

procedure TYamlTest.TestSequence;
var
  D: TJSONData;
  A: TJSONArray;
begin
  D := Parse('items:' + #10 + '- one' + #10 + '- two');
  try
    A := TJSONArray(TJSONObject(D).Find('items'));
    AssertEquals('two items', 2, A.Count);
    AssertEquals('first', 'one', A.Strings[0]);
  finally
    D.Free;
  end;
end;

procedure TYamlTest.TestScalarTypes;
var
  D: TJSONData;
  O: TJSONObject;
begin
  D := Parse('b: true' + #10 + 'n: null' + #10 + 'f: 1.5' + #10 + 'q: "a b"');
  try
    O := TJSONObject(D);
    AssertEquals('bool', True, O.Get('b', False));
    AssertEquals('null type', Ord(jtNull), Ord(O.Find('n').JSONType));
    AssertTrue('float', O.Get('f', 0.0) > 1.4);
    AssertEquals('quoted', 'a b', O.Get('q', ''));
  finally
    D.Free;
  end;
end;

procedure TYamlTest.TestSameIndentSequenceUnderKey;
var
  D: TJSONData;
  A: TJSONArray;
begin
  { `key:` followed by `- item` at the key's own indent is a valid sequence. }
  D := Parse('tags:' + #10 + '- a' + #10 + '- b');
  try
    A := TJSONArray(TJSONObject(D).Find('tags'));
    AssertEquals('two tags', 2, A.Count);
  finally
    D.Free;
  end;
end;

procedure TYamlTest.TestSetPath;
var
  Out_: string;
  Err: string;
  V: TJSONData;
begin
  V := TJSONIntegerNumber.Create(9090);
  try
    Out_ := SetYamlPath('server:' + #10 + '  port: 8080' + #10,
      'server.port', V, Err);
  finally
    V.Free;
  end;
  AssertTrue('set', Pos('port: 9090', Out_) > 0);
end;

procedure TYamlTest.TestTabIndentIsAnError;
var
  D: TJSONData;
  Err: string;
begin
  D := ParseYaml('a:' + #10 + #9 + 'b: 1', Err);
  AssertNull('rejected', D);
  AssertTrue('names the line', Pos('line', Err) > 0);
end;

procedure TYamlTest.TestRoundTrip;
var
  D, D2: TJSONData;
  Err: string;
  Y: string;
begin
  D := Parse('a: 1' + #10 + 'b:' + #10 + '  c: two' + #10 + 'list:' + #10 +
    '- x' + #10 + '- y');
  try
    Y := ToYaml(D);
    D2 := ParseYaml(Y, Err);
    AssertNotNull('re-parses: ' + Err, D2);
    try
      AssertEquals('a survives', 1, TJSONObject(D2).Get('a', 0));
      AssertEquals('nested survives', 'two',
        TJSONObject(TJSONObject(D2).Find('b')).Get('c', ''));
    finally
      D2.Free;
    end;
  finally
    D.Free;
  end;
end;

initialization
  RegisterTest(TYamlTest);
end.
