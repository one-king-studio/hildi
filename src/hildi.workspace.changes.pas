unit hildi.workspace.changes;
{ Per-tool-call file change records.

  The builtin shell tier writes only through its filesystem seam, so one
  observer on TWorkspaceShellFs captures every redirect, sed -i, tee, rm, mv,
  cp, mkdir and touch with exact before/after content. One run_command may
  produce many changes (a compound script), so a call owns a TFileChangeSet and
  consumers read it after the call returns.

  Contents are captured as text up to a cap; bigger or binary files record
  sizes only (Captured = False). }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes;

const
  { Content beyond this is recorded by size only. }
  MaxCapturedChangeBytes = 256 * 1024;

type
  TFileChangeKind = (fcCreated, fcModified, fcDeleted);

  TFileChange = record
    { Workspace-relative, '/'-separated. }
    Path: string;
    Kind: TFileChangeKind;
    IsDir: Boolean;
    Before, After: string;
    BeforeSize, AfterSize: Int64;
    { True when the text on both sides of the change is in Before/After, so a
      real diff can be computed. A process-tier modification has the AFTER text
      but not the BEFORE (the old bytes are gone by the time the post-run walk
      runs), so it records sizes only - a line count computed against an empty
      Before would report the whole file as added. }
    Captured: Boolean;
    { True when Before holds the real prior text. Separate from Captured because
      the two sides can be captured independently. }
    BeforeCaptured: Boolean;
  end;

  TFileChangeSet = class
  private
    FItems: array of TFileChange;
    function GetItem(AIndex: Integer): TFileChange;
    function GetCount: Integer;
  public
    procedure Add(const AChange: TFileChange);
    procedure Clear;
    { `M src/a.pas (+3 -1)`, `A new.txt`, `D old.txt`; empty when nothing
      changed. }
    function Summary: string;
    function CountOf(AKind: TFileChangeKind): Integer;
    property Count: Integer read GetCount;
    property Items[AIndex: Integer]: TFileChange read GetItem; default;
  end;

function ChangeKindCode(AKind: TFileChangeKind): Char;
function ChangeKindText(AKind: TFileChangeKind): string;

implementation

function ChangeKindCode(AKind: TFileChangeKind): Char;
begin
  case AKind of
    fcCreated: Result := 'A';
    fcModified: Result := 'M';
    fcDeleted: Result := 'D';
  end;
end;

function ChangeKindText(AKind: TFileChangeKind): string;
begin
  case AKind of
    fcCreated: Result := 'created';
    fcModified: Result := 'modified';
    fcDeleted: Result := 'deleted';
  end;
end;

function LineCount(const S: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to Length(S) do
    if S[I] = #10 then
      Inc(Result);
  if (S <> '') and (S[Length(S)] <> #10) then
    Inc(Result);
end;

function AddedLines(const ABefore, AAfter: string): Integer;
begin
  Result := LineCount(AAfter) - LineCount(ABefore);
  if Result < 0 then
    Result := 0;
end;

function RemovedLines(const ABefore, AAfter: string): Integer;
begin
  Result := LineCount(ABefore) - LineCount(AAfter);
  if Result < 0 then
    Result := 0;
end;

function TFileChangeSet.GetCount: Integer;
begin
  Result := Length(FItems);
end;

function TFileChangeSet.GetItem(AIndex: Integer): TFileChange;
begin
  Result := FItems[AIndex];
end;

procedure TFileChangeSet.Add(const AChange: TFileChange);
begin
  SetLength(FItems, Length(FItems) + 1);
  FItems[High(FItems)] := AChange;
end;

procedure TFileChangeSet.Clear;
begin
  FItems := nil;
end;

function TFileChangeSet.CountOf(AKind: TFileChangeKind): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FItems) do
    if FItems[I].Kind = AKind then
      Inc(Result);
end;

function TFileChangeSet.Summary: string;
var
  I: Integer;
  C: TFileChange;
  Delta: string;
begin
  Result := '';
  for I := 0 to High(FItems) do
  begin
    C := FItems[I];
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + ChangeKindCode(C.Kind) + ' ' + C.Path;
    if C.Kind = fcModified then
    begin
      { A real diff needs BOTH sides. Without the before text a line delta would
        read as "the whole file was added", which is a fabricated number - so a
        half-captured change reports sizes instead. }
      if C.Captured and C.BeforeCaptured then
        Delta := ' (+' + IntToStr(AddedLines(C.Before, C.After)) + ' -' +
          IntToStr(RemovedLines(C.Before, C.After)) + ')'
      else
        Delta := ' (' + IntToStr(C.BeforeSize) + ' -> ' +
          IntToStr(C.AfterSize) + ' bytes)';
      Result := Result + Delta;
    end;
  end;
end;

end.
