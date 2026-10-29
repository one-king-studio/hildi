program changes_standalone;
{ The isolation smoke for the Changes library. It uses ONLY src/changes plus the
  RTL: the build puts no harness unit on the search path, so a dependency on one
  fails here.

  It exercises the whole surface - diff, log replay, compare-and-swap, keyframes,
  retention - against the in-memory store, so the library's value is demonstrated
  without a database, a workspace, or an agent. }

{$mode delphi}{$H+}

uses
  SysUtils,
  ChangesTypes, ChangesText, ChangesStore, ChangesLog;

type
  THash = class
  public
    function OfText(const AText: string): string;
  end;

function THash.OfText(const AText: string): string;
var
  I: Integer;
  H: Cardinal;
begin
  H := 2166136261;
  {$push}{$Q-}{$R-}
  for I := 1 to Length(AText) do
    H := (H xor Ord(AText[I])) * 16777619;
  {$pop}
  Result := IntToHex(H, 8);
end;

var
  Store: IChangeStore;
  Hasher: THash;
  D, Text, Err: string;
  Capped: Boolean;
  R, Last: TChangeRecord;
  Id, Prev, I: Integer;
  Found: Boolean;
  V: TCasVerdict;
  Frame: TKeyframe;

procedure Check(const AName: string; AOk: Boolean; const ADetail: string);
begin
  if AOk then
    WriteLn('  ok    ', AName)
  else
  begin
    WriteLn('  FAIL  ', AName, ': ', ADetail);
    Halt(1);
  end;
end;

begin
  Hasher := THash.Create;
  try
    WriteLn('changes library standalone');

    { 1. A diff round-trips. }
    D := DiffText('alpha'#10'beta'#10, 'alpha'#10'BETA'#10'gamma'#10,
      DefaultPatchCapBytes, Capped);
    Check('diff produces a patch', D <> '', 'empty');
    Check('apply round-trips', ApplyUnifiedDiff('alpha'#10'beta'#10, D, Text, Err),
      Err);
    Check('the result is right', Text = 'alpha'#10'BETA'#10'gamma'#10, Text);

    { 2. A chain replays from nothing. }
    Store := TMemoryChangeStore.Create;
    R := Default(TChangeRecord);
    R.WorkspaceId := 1;
    R.Path := 'a.txt';
    R.Kind := ckModified;
    R.BeforeHash := Hasher.OfText('');
    R.AfterHash := Hasher.OfText('v1'#10);
    R.Patch := DiffText('', 'v1'#10, DefaultPatchCapBytes, Capped);
    Check('append 1', Store.Append(R, Prev, Err), Err);
    R.BeforeHash := R.AfterHash;
    R.AfterHash := Hasher.OfText('v1'#10'v2'#10);
    R.Patch := DiffText('v1'#10, 'v1'#10'v2'#10, DefaultPatchCapBytes, Capped);
    Check('append 2', Store.Append(R, Id, Err), Err);

    R := Default(TChangeRecord);
    R.WorkspaceId := 1;
    R.Path := 'a.txt';
    R.Id := Id;
    Check('replay', Reconstruct(Store, Hasher.OfText, R, Text, Err), Err);
    Check('replay is exact', Text = 'v1'#10'v2'#10, Text);

    { 3. Compare-and-swap. }
    Check('cas ok', CheckWrite(Store, 1, 'a.txt', Hasher.OfText('v1'#10'v2'#10),
      Hasher.OfText('v1'#10'v2'#10), V, Last, Err), Err);
    Check('cas agrees', V = cvOk, 'not ok');
    Check('cas conflict', CheckWrite(Store, 1, 'a.txt', 'STALE', 'NOW', V, Last,
      Err), Err);
    Check('cas refused', V = cvConflict, 'not a conflict');

    { 4. Keyframe policy. }
    Check('no keyframe for a small delta', not KeyframeDue(10, 10000, 1), 'due');
    Check('keyframe at the interval',
      KeyframeDue(0, 10000, KeyframeChangeInterval), 'not due');

    { 5. Retention. }
    Store := TMemoryChangeStore.Create;
    for I := 1 to 20 do
    begin
      R := Default(TChangeRecord);
      R.WorkspaceId := 1;
      R.Path := 'f.txt';
      R.Kind := ckModified;
      R.TurnId := I;
      R.AfterHash := 'h' + IntToStr(I);
      Check('append turn ' + IntToStr(I), Store.Append(R, Id, Err), Err);
    end;
    R := Default(TChangeRecord);
    R.WorkspaceId := 1;
    R.Path := 'f.txt';
    R.Id := 20;
    Check('prune point', PrunePointFor(nil, 16) = 0, 'expected 0 for no rows');

    { 6. The store seam is a real seam: Prune keeps the horizon. }
    Frame := Default(TKeyframe);
    Frame.WorkspaceId := 1;
    Frame.Path := 'f.txt';
    Frame.Hash := 'h5';
    Frame.Content := 'v5';
    Frame.ThroughChangeId := 5;
    Check('keyframe', Store.PutKeyframe(Frame, Err), Err);
    Check('prune', Store.Prune(1, 10, Err), Err);
    Check('keyframe survives at the horizon',
      Store.KeyframeBefore(1, 'f.txt', 10, Frame, Found, Err), Err);
    Check('and was found', Found, 'no keyframe after prune');

    WriteLn('all checks passed');
  finally
    Hasher.Free;
  end;
end.
