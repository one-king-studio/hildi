# Component Specification: ANSI Terminal Styling

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

`hildegard.helper.ansi` is a zero-dependency helper for colour and emphasis in
terminal output. It emits SGR escape sequences, and it disables itself when
output is not a terminal (or when the user asks for no colour) so piped or
logged output stays clean. It never buffers, moves the cursor, or reads input -
it only wraps text.

This exists because FPC ships no ANSI colour helper; `crt` and `ncurses` take
over the console and are unsuitable for streaming line output.

## Requirements

### Functional

- [ ] Emit 24-bit foreground colour, bold, and dim sequences.
- [ ] Disable all sequences when not writing to a terminal, when `TERM=dumb`, or
      when `NO_COLOR` is set.
- [ ] Allow an explicit override (force on/off) for the CLI.
- [ ] Return the input unchanged when disabled.

### Non-Functional

- No external dependency; macOS and Linux.
- No output side effects; pure string functions plus two stateful settings.

## Contracts & Interfaces

> Contracts as Pascal type declarations. No method bodies.

```pascal
unit hildegard.helper.ansi;

type
  TAnsiColor = record
    R, G, B: Byte;
  end;

const
  AnsiBlack, AnsiRed, AnsiGreen, AnsiYellow: TAnsiColor;
  AnsiBlue, AnsiMagenta, AnsiCyan, AnsiWhite, AnsiGray: TAnsiColor;

function Color(AR, AG, AB: Byte): TAnsiColor;

{ Current setting, detected at unit initialisation: enabled iff stdout is a TTY,
  TERM <> 'dumb', and NO_COLOR is unset. }
function AnsiEnabled: Boolean;
procedure AnsiSetEnabled(AValue: Boolean);

{ '' when disabled. }
function AnsiFg(const AColor: TAnsiColor): string;
function AnsiReset: string;

{ Wrap AS in the style, or return AS unchanged when disabled. }
function AnsiBold(const AS: string): string;
function AnsiDim(const AS: string): string;
function AnsiStyled(const AS: string; const AColor: TAnsiColor): string;
```

## Architecture

### Prior Art & Reuse

- ANSI SGR is a platform feature; no library is needed. `isatty` is called
  through libc (`external 'c'`) for portability, matching how tests set
  environment variables.
- `crt` / `ncurses` are explicitly rejected (console takeover).

### Component Boundaries

- **Responsibilities:** colour detection, sequence construction, wrapping.
- **Dependencies:** `SysUtils`, libc `isatty`.
- **Side effects:** none.

## Testing Requirements

`test_ansi.pas`:

- [ ] `TestColorBuildsRecord`
- [ ] `TestFgEmitsTruecolorWhenEnabled`
- [ ] `TestDimWrapsAndResetsWhenEnabled`
- [ ] `TestDisabledReturnsTextUnchanged`
- [ ] `TestDisabledFgIsEmpty`
- [ ] `TestEnabledToggleRoundTrip`

Each test sets `AnsiSetEnabled` explicitly and restores the previous value, so
the suite is independent of whether it runs under a TTY.

## Security Considerations

None beyond emitting escape sequences; styling carries no data.

## Future Considerations

- Background colour, underline, hyperlinks (OSC 8).
- Named 256-colour palette.
