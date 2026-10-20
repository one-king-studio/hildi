# Component Specification: Command Tool

> **SUPERSEDED.** The policy source, approval outcomes, store settings, and audit
> described here are replaced by [Tool Approvals](../Tool_Approvals/FEATURE.md)
> and [Sessions and Ledger](../Sessions_And_Ledger/FEATURE.md). The parser, the
> required `reason`, the shell-profile parameter, and the synchronous executor
> carry forward.

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

`hildegard.helper.command.tool` turns the pure decisions of
[`Command_Policy_v1.SPEC.md`](Command_Policy_v1.SPEC.md) into an agent tool. It
advertises `run_command`, parses the model's arguments, loads the policy,
obtains operator approval when required, executes the command through the
existing process runner, returns the combined output and exit status to the
model, and records an audit trail. The policy itself lives behind an injectable
source so the tool is testable without SQLite and without running processes.

v1 is Unix-first: the default shell profile is `/bin/bash -c` with POSIX syntax.
The profile is a value, so a future Windows profile is additive.

> **Revision (v1.1):** approval is now requested per simple-command segment, with
> outcomes once / exact / wildcard / deny. Persisted patterns are argument-aware
> (see `Command_Policy_v1.SPEC.md`). `TApprovalOutcome.aoAllowAlways` became
> `aoAllowSpecific` and `aoAllowWildcard`.

## Requirements

### Functional

- [ ] Register a `run_command` tool with `TToolRegistry`, advertising the
      documented parameter schema.
- [ ] Parse the JSON arguments; require `command`; accept optional `cwd` and
      `timeout_ms`, and read the shared required `reason` (see
      [`Tool_Reason_v1.SPEC.md`](Tool_Reason_v1.SPEC.md)).
- [ ] Pass the reason into the approval request and into the audit record.
- [ ] Parse the command with `Command.Policy` using the profile's syntax mode and
      classify it against the loaded policy.
- [ ] Classify each segment; if any segment is **deny**, do not execute and
      return an error tool result naming that segment.
- [ ] For each segment that is **ask**, consult the approval handler with that
      segment; with no handler, deny. **allow once** proceeds without persisting;
      **allow specific** persists `=<exact argv>`; **allow wildcard** persists
      `<executable> *`. Persisting updates the in-run policy so a wildcard covers
      later matching segments without another prompt.
- [ ] Execute synchronously through an injectable executor that wraps
      `TCommandRunner`; collect combined stdout/stderr and the exit code.
- [ ] Cap the output returned to the model with an explicit truncation marker.
- [ ] Map timeout and cancellation to the existing 124/130 conventions.
- [ ] Record an audit entry for every decision/outcome.
- [ ] Never raise; all failures become error tool results.
- [ ] When the store is unavailable, the tool is still registered using
      `TMemoryCommandPolicySource` with `DefaultCommandPolicy` (ask everything,
      deny nothing); "allow always" lasts for the session only. The tool is
      never silently disabled.

### Non-Functional

- [ ] Leak-clean under `make test-leak`: the runner thread is joined and every
      owned object is freed on all paths.
- [ ] The tool holds no global state; one instance per session.
- [ ] POSIX/shell specifics come only from the profile value, never hard-coded in
      the tool body.
- [ ] The policy source, executor, and approver are all injectable, so the tool
      is tested with fakes and no SQLite, no network, and no real process.

## Contracts & Interfaces

> Contracts as Pascal type declarations. No method bodies.

### Public API

```pascal
unit hildegard.helper.command.tool;

interface

uses
  hildegard.helper.agent, hildegard.helper.command.policy;

type
  { Shell description. v1 ships DefaultShellProfile (POSIX). }
  TShellProfile = record
    Executable: string;   // '/bin/bash'
    Switch: string;       // '-c'
    Syntax: TShellSyntax; // ssPosix
  end;

  TCommandToolConfig = record
    Shell: TShellProfile;
    DefaultCwd: string;        // '' => process cwd
    DefaultTimeoutMs: QWord;   // 0 => ProfileDefaultTimeoutMs
    MaxOutputBytes: Integer;   // 0 => DefaultMaxOutputBytes
  end;

  { Outcome of one execution. Started=False means the runner could not begin. }
  TCommandExecution = record
    Output: string;
    ExitCode: Integer;
    TimedOut: Boolean;
    Cancelled: Boolean;
    Started: Boolean;
    Error: string;
  end;

  { Execution seam. The real implementation wraps TCommandRunner; tests use a
    fake. Returns False only on infrastructure failure. }
  ICommandExecutor = interface
    function Execute(const AProfile: TShellProfile; const ACommand,
      AWorkDir: string; ATimeoutMs: QWord;
      out AExecution: TCommandExecution): Boolean;
  end;

  { Policy persistence seam. The store-backed implementation reads/writes
    settings and audit; tests use an in-memory fake. }
  ICommandPolicySource = interface
    function LoadPolicy(out APolicy: TCommandPolicy; out AError: string): Boolean;
    { Persists an allow pattern: '=<exact argv>' or '<executable> *'. }
    function SaveApproval(const APattern: string; out AError: string): Boolean;
    procedure RecordAudit(const AEntry: TCommandAuditEntry);
  end;

  { TCommandDecision, TCommandPlan, and TPolicyDecision come from
    hildegard.helper.command.policy. }

  TCommandAuditEntry = record
    Id: string;
    Command: string;
    Reason: string;        // the model's stated reason for the call
    Decision: TCommandDecision;
    Approval: string;      // 'policy' | 'once' | 'always' | 'denied' | ''
    ExitCode: Integer;
    TimedOut: Boolean;
    OutputBytes: Integer;
    CreatedAtMs: Int64;
  end;

  TApprovalRequest = record
    Command: string;          // the whole command line
    SegmentCommand: string;   // the individual simple command being approved
    Segment: TCommandSegment;
    Reason: string;           // the model's stated reason for the call
    Decision: TSegmentDecision;
  end;

  { aoAllowOnce: run only now. aoAllowSpecific: persist this exact command.
    aoAllowWildcard: persist the executable with any arguments. aoDeny: refuse. }
  TApprovalOutcome = (aoAllowOnce, aoAllowSpecific, aoAllowWildcard, aoDeny);

  { Called by the tool on the loop's (calling) thread, once per segment that
    needs approval. Return the outcome. }
  TApprovalHandler = function(const ARequest: TApprovalRequest):
    TApprovalOutcome of object;

  TCommandTool = class
  public
    constructor Create(const AConfig: TCommandToolConfig;
      ASource: ICommandPolicySource; AApprover: TApprovalHandler = nil;
      AExecutor: ICommandExecutor = nil);
    { Registers run_command with the registry. }
    procedure Register(ATools: TToolRegistry);
    { Matches TToolHandler; registered by Register. Public for direct testing. }
    function Run(const AArgumentsJson: string;
      out AResult: string; out AError: string): Boolean;
  end;

function DefaultShellProfile: TShellProfile;

const
  CommandToolName = 'run_command';
  ProfileDefaultTimeoutMs = 30000;
  DefaultMaxOutputBytes = 32768;
```

### Policy sources (same unit)

```pascal
type
  { Session-only fallback for when no store is available. Never persists:
    "allow always" lasts for the process, audits are discarded. Intended for
    DefaultCommandPolicy (ask everything, deny nothing), so the tool stays
    enabled but every command is approved by hand. }
  TMemoryCommandPolicySource = class(TInterfacedObject, ICommandPolicySource)
  public
    constructor Create(const APolicy: TCommandPolicy);
    function LoadPolicy(out APolicy: TCommandPolicy;
      out AError: string): Boolean;
    function SaveApproval(const APattern: string;
      out AError: string): Boolean;
    procedure RecordAudit(const AEntry: TCommandAuditEntry);
  end;

  { Reuses the existing requests table for audit (Kind='command'); policy lives
    in settings. The store is opened by the owner; this source never opens it. }
  TStoreCommandPolicySource = class(TInterfacedObject, ICommandPolicySource)
  public
    constructor Create(AStore: TSqliteStore);
    function LoadPolicy(out APolicy: TCommandPolicy; out AError: string): Boolean;
    function SaveApproval(const APattern: string; out AError: string): Boolean;
    procedure RecordAudit(const AEntry: TCommandAuditEntry);
  end;

const
  SettingPolicyAllow = 'command.policy.allow';
  SettingPolicyDeny = 'command.policy.deny';
  SettingPolicyRoots = 'command.policy.roots';
  SettingPolicyAllowInterpreters = 'command.policy.allow_interpreters';
  SettingPolicyApproved = 'command.policy.approved';
```

### Required change to `hildegard.helper.process`

`TCommandRunner` currently hard-codes `/bin/bash` and `-c`. Add two constructor
parameters (defaulted, so existing callers are unchanged):

```pascal
constructor Create(const AId, ACommand: string; ATimeoutMs: QWord = 0;
  const AWorkDir: string = ''; AOnOutput: TOutputEvent = nil;
  const AShellExecutable: string = '/bin/bash';
  const AShellSwitch: string = '-c');
```

The tool's executor passes the profile's `Executable`/`Switch`. No other runner
behaviour changes.

### Data Contracts

Tool parameters (advertised JSON schema):

```json
{
  "type": "object",
  "properties": {
    "command":    { "type": "string",  "description": "Shell command to run." },
    "reason":     { "type": "string",  "description": "Short reason this command is needed." },
    "cwd":        { "type": "string",  "description": "Working directory." },
    "timeout_ms": { "type": "integer", "description": "Timeout in ms (0 = default)." }
  },
  "required": ["command", "reason"]
}
```

The `reason` property is guaranteed by the shared tool contract
([`Tool_Reason_v1.SPEC.md`](Tool_Reason_v1.SPEC.md)); the schema is shown with it
included to reflect the advertised result.

Tool result text returned to the model (successful classification):

```
exit_code: <n>
<combined stdout/stderr, capped>
```

- On truncation, append a line: `[output truncated at <MaxOutputBytes> bytes]`.
- On timeout, the exit code is `124`; on cancellation, `130`.
- A denied command returns **False** with `AError = 'denied by policy: <reason>'`;
  the loop renders it as an error tool result. The command is not executed.

Policy settings encoding: `allow`, `deny`, `roots`, and `approved` are JSON
arrays of strings (parsed with `fpjson`); `allow_interpreters` is `'1'`/`'0'`.
`LoadPolicy` returns `Allow` merged with `approved`; a missing/blank setting is
an empty array, and a malformed setting is an `AError` (the tool then fails
closed).

### Event Contracts

None. The executor's runner callback fires on the runner thread, but the executor
collects under a critical section and joins the runner before returning, so the
tool itself is single-threaded on the loop's thread.

## Architecture

### Prior Art & Reuse

- `hildegard.helper.process` (`TCommandRunner`) - execution, streaming, timeout,
  cancellation. Only the shell/switch parameterisation is added.
- `hildegard.helper.command.policy` - parsing and classification (this feature).
- `hildegard.helper.agent` (`TToolRegistry`, `TToolHandler`, `TToolSpec`) - tool
  contract and dispatch.
- `hildegard.helper.store` (`GetSetting`/`SetSetting`/`EnqueueRequest`/
  `FinishRequest`) - policy persistence and audit. The existing requests table is
  the audit log; no migration is added.
- `fpjson`/`jsonparser` - argument and settings encoding.

### Component Boundaries

- **Responsibilities:** tool advertisement, argument parsing, policy loading,
  approval orchestration, synchronous execution, output capping, audit.
- **Dependencies:** `command.policy`, `agent`, `process`, `store`, `fpjson`.
- **Side effects:** runs a subprocess; reads/writes store settings; writes audit
  rows; may prompt on the terminal via the approver.

### Data Flow

1. `Register` adds a `TToolSpec` (name, description, schema) and `Run`.
2. `Run` parses arguments; missing/invalid `command` -> `False` with error. The
   shared contract has already guaranteed `reason` is present and non-empty.
3. `LoadPolicy`; on error -> fail closed (`False`).
4. `ParseCommand`; refuse parse errors and empty commands.
5. Pre-scan segments: any deny -> audit, return `False`.
6. For each segment: allow -> proceed; ask -> approver for that segment
   (nil = deny), persisting the selected pattern and updating the in-run policy.
7. `ICommandExecutor.Execute` the whole command line (joins the runner thread).
8. Cap output, format result, audit (with reason), return `True`.
9. Any exception is caught and converted to `False` with `AError`.

### Integration Patterns

- Synchronous; the executor owns and joins the `TCommandRunner`.
- Ownership: the tool owns neither the registry, the source, nor the store; it
  owns the default executor when one is not injected and frees it in `Destroy`.

## Validation Rules

### Input

- `command` must be a non-empty string; `cwd` must be a string if present;
  `timeout_ms` must be a non-negative integer if present.
- **HTML entities in `command` are decoded before parsing.** Models write
  `&lt;`, `&gt;`, `&amp;`, `&quot;`, `&apos;` (and numeric `&#NN;`/`&#xHH;`)
  assuming markdown rendering; the shell would see literal text. The common set
  is decoded once, so `echo a &lt; b` runs `echo a < b` and
  `cat f &gt;&gt; log` appends. An entity preceded by a backslash is left
  alone (`grep '\&lt;' f` searches the literal text `&lt;`), and the decode is
  single-pass (`&amp;lt;` becomes `&lt;`, not `<`). The decoded command is what
  the splitter, the tier, the approval asks and the transcript all see.
- Invalid JSON, missing `command`, or wrong types -> `False` with a clear error;
  never a crash, never execution.

### Output Guarantees

- Returned output never exceeds `MaxOutputBytes` plus the truncation marker.
- `ExitCode` is `0..255`, or `128+signal` as normalised by the runner.
- Every path that reaches execution or denial has a corresponding audit entry.

## Error Handling

### Error Types

- **Validation:** bad tool arguments -> `False`, `AError` describes the field.
- **Policy:** store read/write failure -> fail closed (`False`).
- **Policy denial:** -> `False`, `AError = 'denied by policy: ...'`.
- **Execution:** non-zero exit is a successful tool result carrying the code;
  timeout -> `124`; cancellation -> `130`; failure to start -> `False`.

### Error Contracts

The tool uses the existing `TToolHandler` convention: `False` + `AError` becomes
an error tool result; `True` + `AResult` is content. No `TLLMError` is produced
here.

## Testing Requirements

> What to test; the implementer decides how. Named fpcunit methods in
> `tests/test_command_tool.pas`, plus one addition to the process suite.

### Unit Tests

- [ ] `TestRegisterAddsRunCommandSpec`
- [ ] `TestMissingCommandArgumentFails`
- [ ] `TestInvalidJsonFails`
- [ ] `TestAllowExecutesAndReturnsOutput`
- [ ] `TestDenyDoesNotExecuteAndFails`
- [ ] `TestAskWithNoApproverDenies`
- [ ] `TestAskAllowOnceExecutesWithoutPersisting`
- [ ] `TestAskAllowWildcardExecutesAndPersists`
- [ ] `TestAskAllowSpecificPersistsExact`
- [ ] `TestAskAllowSpecificNoArgsPersistedExact`
- [ ] `TestCompoundCommandApprovedPerSegment`
- [ ] `TestWildcardApprovalCoversLaterSegments`
- [ ] `TestAskDenyDoesNotExecute`
- [ ] `TestTimeoutReports124`
- [ ] `TestOutputIsTruncatedWithMarker`
- [ ] `TestPolicyReloadedEachCall`
- [ ] `TestLoadPolicyErrorFailsClosed`
- [ ] `TestAuditRecordedForAllowDenyAndOutcome`
- [ ] `TestReasonPassedToApprover`
- [ ] `TestReasonRecordedInAudit`
- [ ] `TestMissingReasonNotExecuted`
- [ ] `TestHandlerNeverRaises`
- [ ] `TestDefaultShellProfileIsPosixBash`
- [ ] `TestNoLeaks` (enforced by `make test-leak`)

### Integration Tests

- [ ] `TestProcessRunnerUsesProvidedShell` (in `test_hildegard_helper.pas`):
      a custom switch proves the shell parameter is honoured.
- [ ] `TestStoreCommandPolicySourceRoundTrip` (in `tests/test_command_tool.pas`,
      `{ $IFDEF }`-gated or using the existing store test fixture): sets policy
      settings, loads them back, saves an approval, writes an audit row, and
      queries it.
- [ ] `TestMemoryPolicySourceAsksThenRemembers`: the fallback asks by default,
      remembers an approval for the session, and discards audits safely.
- [ ] `TestRoundTripAgainstFakeProvider`: the model calls `run_command`, the
      fake executor returns output, and the loop feeds the result back (uses the
      existing LLM test fakes).

## Performance Targets

- Negligible overhead beyond the subprocess; policy load is a handful of indexed
  setting reads.
- Output capping bounds memory and context-window growth.

## Security Considerations

- The tool is a privilege boundary: it only executes after the policy engine and
  (when required) an explicit human approval.
- No handler with no approver, no execution: absence of an approval path is a
  denial, never a bypass.
- The command runs through the same shell the operator exposed; the tool adds no
  second evaluation of the command text.
- `MaxOutputBytes` bounds what a hostile command can push into the model context.
- Audit records are the accountability trail; they must include the exact command,
  the model's stated reason, and the decision, and must never include secrets
  (the tool never sees the LLM key).
- The reason is untrusted, model-authored display text: it is shown and stored,
  never executed or used to make the policy decision.

## Success Criteria

### Functional

- [ ] All contracts implemented; `run_command` executes, gates, and audits.
- [ ] All error scenarios handled; `make check` passes.

### Quality

- [ ] Tested entirely with fakes (no SQLite, network, or real process required
      for the tool tests).
- [ ] No leaks; shell specifics confined to `TShellProfile`.
- [ ] The CLI can wire it in a few lines with no changes to `TToolHandler`.

## Future Considerations

- A console approver and CLI flags (`--no-shell`, `--shell`, `--yes-for-this-run`)
  in `examples/agent_cli.pas`.
- A Windows shell profile (`cmd.exe`, `ssCmd`) once the foundation gaps close.
- Streaming command output to the transcript while the command runs.
- Per-tool policy reuse: the same allow/ask/deny engine gating non-shell tools.
- Structured typed tools (read/write/list) that bypass shell parsing entirely.
