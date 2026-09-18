# Component Specification: Agent CLI v1

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

`hildegard-helper-agent` is a Unix-style command-line agent. Like a standard
system utility it does one thing well from the shell's point of view: it emits
text. Internally it can do whatever the agent's tools allow. It runs
interactively by default, or once for a given prompt, and streams output like
`tail` until it finishes or the user exits.

The output is a legible transcript that distinguishes the user prompt, reasoning,
tool calls, and the final answer, and it is designed to be piped - for example
`agent -p "..." | less -R`, where `$PAGER` supplies scrolling and vim motions.

Two units implement it:

- `hildegard.helper.cli` - pure command-line parsing and usage text.
- `hildegard.helper.transcript` - stateful rendering of a turn to a `TStream`.

## Requirements

### Functional

- [ ] Interactive mode by default when stdin is a terminal.
- [ ] Non-interactive ("once") mode when a prompt is supplied or stdin is piped.
- [ ] `-p/--prompt TEXT` (or `-p -` / a positional prompt) runs a single turn.
- [ ] Read all of stdin as the prompt when stdin is piped and no prompt is given.
- [ ] `--no-reasoning` / `--reasoning`, `--no-tools` / `--tools`,
      `--no-user`, `--color` / `--no-color`, `-s/--system`, `-m/--model`,
      `--endpoint`, `-h/--help`.
- [ ] Render labelled, blank-line-separated sections; streaming text is emitted
      as it arrives.
- [ ] `--max-tps N` paces streamed text/reasoning to at most N deltas per second
      (`0`, the default, is unlimited) so fast models stay readable.
- [ ] Colored on a terminal, plain when piped (`AnsiEnabled`).
- [ ] Clear exit codes: 0 success, 1 runtime/config failure, 2 usage error.

### Non-Functional

- Pure parsing and rendering are unit-testable with no terminal.
- No full-screen UI, no buffering of the whole transcript, no new dependency.
- The loop stays single-threaded; the CLI is a thin adapter.

## Contracts & Interfaces

```pascal
unit hildegard.helper.cli;

type
  TTriState = (tsDefault, tsOn, tsOff);
  TCLIMode = (cmInteractive, cmOnce);

  TCLIOptions = record
    Mode: TCLIMode;
    Prompt: string;              // '' when not supplied
    PromptFromStdin: Boolean;    // '-' was given
    SystemPrompt: string;
    Model: string;
    Endpoint: string;
    ShowUser: Boolean;
    ShowTools: Boolean;
    Reasoning: TTriState;         // tsDefault => on interactive, off once
    MaxTokensPerSecond: Integer;  // 0 = unlimited
    ColorMode: TTriState;
    Help: Boolean;
  end;

  ECLIError = class(Exception);

{ AArgs excludes the program name. Raises ECLIError on unknown/incomplete
  options. Defaults: interactive, show user/reasoning/tools, colour auto. }
function ParseCLIOptions(const AArgs: array of string): TCLIOptions;
function UsageText: string;
```

```pascal
unit hildegard.helper.transcript;

type
  TTranscriptOptions = record
    ShowUser: Boolean;
    ShowReasoning: Boolean;
    ShowTools: Boolean;
    MaxTokensPerSecond: Integer;  // 0 = unlimited; paces text/reasoning deltas
  end;

  { Renders one or more turns to AOutput as labelled sections. Colours come from
    hildegard.helper.ansi (no-ops when disabled). Methods map to the agent
    events; BeginTurn starts a user section. }
  TTranscriptWriter = class
  public
    constructor Create(AOutput: TStream; const AOptions: TTranscriptOptions);
    procedure BeginTurn(const AUserText: string);
    procedure OnReasoning(const AText: string);
    procedure OnText(const AText: string);
    procedure OnToolCall(const AId, AName, AArguments: string);
    procedure OnToolResult(const AId, AName, AResult: string; AOk: Boolean);
    procedure WriteError(const AMessage: string);
    procedure EndTurn;
  end;
```

### Output Format

The user prompt is always a shell-style marker, in both modes, so output looks
the same whether typed or echoed:

```
> what time is it?
```

Sections are separated by one blank line. In **plain mode** (no colour - piped or
`--no-color`) each section is labelled so the transcript stands on its own:

```
> what time is it?

[reasoning]
The user wants the time; call get_system_time.

[tool get_system_time]
args: {}

result: 2026-09-18T20:15:00Z

[assistant]
It is 20:15 UTC.
```

In **colour mode** (a terminal) the labels are omitted because colour already
distinguishes the sections: reasoning is dim, the tool call is a cyan
`name(args)` line, results are green (`  -> ...`), errors red, and the answer is
plain:

```
> what time is it?

The user wants the time; call get_system_time.

get_system_time({})

  -> 2026-09-18T20:15:00Z

It is 20:15 UTC.
```

Rules: suppressed sections are omitted entirely along with their separator; the
answer streams after its section break; a failure renders as red `  !! ...` (or
`[error]` in plain mode).

Pacing: when `MaxTokensPerSecond > 0`, each text/reasoning delta is emitted no
faster than one per `1000 / MaxTokensPerSecond` milliseconds. A delta is treated
as one token (approximate: SSE deltas are usually a token or a few characters).
Tool sections are never paced. This is intentionally simple and single-threaded
(the delay happens in the event callback), see the ceiling noted in the unit.

### Rate-limiting ceiling

Pacing sleeps inside the event callback, which runs on the thread reading the
provider stream. This holds back socket reads; for typical chat responses the OS
buffer absorbs it, but a very low rate on a very long response could, in theory,
stall the connection. `ponytail:` if that is ever observed, move rendering to a
consumer thread with a queue and leave the reader unblocked.

## Defaults and Mode Selection

- Prompt supplied (`-p`, `--prompt`, `-`, or a positional) => once mode.
- Otherwise, stdin a terminal => interactive; stdin piped => once (prompt read
  from stdin).
- Interactive echoes a `> ` prompt and relies on the terminal's echo for the
  prompt line; once mode prints `> ` plus the prompt itself, so both look the
  same. The `--no-user` flag hides the echoed prompt in once mode.
- Reasoning defaults on for interactive, off for once/piped; `--reasoning` forces
  it on, `--no-reasoning` off. Tools default on. `--no-user` hides the user
  section.

## Testing Requirements

`test_cli.pas`:

- [ ] `TestDefaultsToInteractive`
- [ ] `TestPromptImpliesOnce`
- [ ] `TestPositionalPrompt`
- [ ] `TestDashPromptReadsStdin`
- [ ] `TestNoReasoningAndNoToolsFlags`
- [ ] `TestMaxTpsFlag`
- [ ] `TestColorFlagsSetTriState`
- [ ] `TestModelSystemEndpointFlags`
- [ ] `TestLongFlagsWithEquals`
- [ ] `TestHelpFlag`
- [ ] `TestUnknownOptionRaises`
- [ ] `TestMissingValueRaises`

`test_transcript.pas`:

- [ ] `TestUserSectionRendered`
- [ ] `TestAssistantSectionRendered`
- [ ] `TestReasoningSectionRenderedWhenEnabled`
- [ ] `TestReasoningSuppressedWhenDisabled`
- [ ] `TestToolSectionsRendered`
- [ ] `TestToolsSuppressedWhenDisabled`
- [ ] `TestSectionsSeparatedByBlankLine`
- [ ] `TestErrorRendered`
- [ ] `TestNoEscapesWhenColorDisabled`
- [ ] `TestHeadersHiddenWhenColorEnabled`
- [ ] `TestPacingDelaysOutput`

## Security Considerations

- API keys are never accepted as command-line flags (visible in `ps`); they come
  from the environment or `.env`.
- The transcript never prints the API key.

## Future Considerations

- A `--pager` convenience that pipes through `$PAGER`.
- `--json` output for scripting.
- Multiple prompts / a script file.
