unit changes.types;
{ Shared types for the Changes library: a workspace change log with
  hash-anchored patches.

  This unit has no dependency beyond the RTL, and nothing here knows about
  SQLite, sessions, agents or the workspace trust boundary. A consumer supplies
  paths already relative to its root and hashes already computed. }

{$mode delphi}{$H+}

interface

type
  TChangeKind = (
    ckCreated,
    ckModified,
    ckDeleted,
    { A directory was created or removed. It has no content, so it carries
      sizes and no patch. }
    ckDir);

  { Who observed the change. This is on the record rather than inferred, because
    "exact" and "inferred" mean different things to an operator: a tier write
    knows both sides, a spawned program only what a walk could see. }
  TChangeSource = (
    csFileTool,    // the harness's own file tools
    csTier,        // the builtin shell tier, in-process
    csProcess,     // a spawned program, seen by a before/after walk
    csWatcher);    // a periodic walk, later

  TStringArrayLite = array of string;

  { One transition of one file. Both hashes are required: they are what makes a
    patch stateless (it applies or it refuses) and a restore verifiable.
    Patch may be empty while AfterHash is set - a deletion whose bytes were never
    captured, or a capped diff. The record still says something happened, which
    is what an activity view and a staleness rule need. }
  TChangeRecord = record
    Id: Integer;               // assigned by the store on Append
    WorkspaceId: Integer;
    SessionId: string;         // '' => unattributed (a watcher)
    TurnId: Integer;
    MessageId: Integer;        // the tool-result row, when there is one
    Path: string;              // '/'-separated, relative to the workspace root
    Kind: TChangeKind;
    BeforeHash: string;        // '' for a creation
    AfterHash: string;         // '' for a deletion
    Patch: string;             // forward unified diff; '' when not applicable
    PatchBytes: Integer;
    Capped: Boolean;           // the patch was truncated at the cap
    BeforeSize: Int64;
    AfterSize: Int64;
    Source: TChangeSource;
    ExternalSession: string;   // a peer caught writing (CAS residue)
    CreatedAt: Int64;
  end;

  TChangeRecordArray = array of TChangeRecord;

  { A full copy of a path at a point in the log, so replay never walks the whole
    history. ThroughChangeId is the last change this content accounts for. }
  TKeyframe = record
    Id: Integer;
    WorkspaceId: Integer;
    Path: string;
    Hash: string;
    Content: string;
    ThroughChangeId: Integer;
    CreatedAt: Int64;
  end;

const
  { The default bound on a stored patch. A larger diff is truncated and flagged
    Capped; the record is still useful for "what changed" and the staleness
    rule, and the operator is told the diff was cut. }
  DefaultPatchCapBytes = 8 * 1024;

  { A keyframe is written when a path's accumulated patches exceed this multiple
    of its current size... }
  KeyframeSizeFactor = 2;
  { ...or after this many changes, whichever comes first. Bounds replay. }
  KeyframeChangeInterval = 50;

  { The retention window: how many turns of history are kept. Beyond this a
    restore is better served by moving forward than by reaching back. }
  DefaultRetentionTurns = 16;

function ChangeKindToWire(AKind: TChangeKind): string;
function ChangeSourceToWire(ASource: TChangeSource): string;
{ The single-letter code a summary line uses: A, M, D. }
function ChangeKindCode(AKind: TChangeKind): Char;

implementation

function ChangeKindToWire(AKind: TChangeKind): string;
begin
  case AKind of
    ckCreated: Result := 'created';
    ckModified: Result := 'modified';
    ckDeleted: Result := 'deleted';
    ckDir: Result := 'dir';
  end;
end;

function ChangeSourceToWire(ASource: TChangeSource): string;
begin
  case ASource of
    csFileTool: Result := 'file-tool';
    csTier: Result := 'tier';
    csProcess: Result := 'process';
    csWatcher: Result := 'watcher';
  end;
end;

function ChangeKindCode(AKind: TChangeKind): Char;
begin
  case AKind of
    ckCreated: Result := 'A';
    ckModified: Result := 'M';
    ckDeleted: Result := 'D';
    ckDir: Result := 'D';
  end;
end;

end.
