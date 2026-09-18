# Component Specification: Environment File Loading

**Related Feature:** [FEATURE.md](FEATURE.md)

## Purpose

`hildegard.helper.env` loads a simple `.env` file into the process environment so
operators can keep local configuration (for example the LLM API key and model) in
one untracked file instead of exporting variables every session. It is
deliberately minimal and never overrides variables already present in the
environment - the shell wins, which is the safe precedence for secrets.

## Requirements

### Functional

- [ ] Parse a `.env` file into name/value pairs.
- [ ] Support comments, blank lines, an optional `export ` prefix, surrounding
      whitespace, and single/double quoted values.
- [ ] Apply parsed pairs without overriding existing environment variables.
- [ ] Return how many variables were applied; a missing file is a no-op (0).
- [ ] Never log values.

### Non-Functional

- Pure parsing (no environment mutation) is separately testable.
- Unix (macOS/Linux) environment setting via libc `setenv`.

## Contracts & Interfaces

```pascal
unit hildegard.helper.env;

type
  TEnvPair = record
    Name: string;
    Value: string;
  end;

  TEnvPairArray = array of TEnvPair;

{ Pure: parse text into pairs. Ignores comments/blank lines, strips an optional
  'export ' prefix, trims whitespace, and removes matching surrounding quotes.
  A line without '=' or with an empty name is skipped. }
function ParseDotEnv(const AText: string): TEnvPairArray;

{ Apply pairs, skipping any whose Name already exists in the environment.
  Returns the number applied. }
function ApplyEnv(const APairs: TEnvPairArray): Integer;

{ Read APath, parse, and apply. Returns the number applied; 0 if absent. }
function LoadDotEnvFile(const APath: string): Integer;
```

## Architecture

### Prior Art & Reuse

- No parser library is needed; the format is line-oriented and trivial.
- Environment setting matches the existing test technique: libc `setenv` on Unix
  (FPC has no cross-platform setter).

### Component Boundaries

- **Responsibilities:** file reading, parsing, non-overriding application.
- **Side effects:** sets process environment variables (only for keys not already
  present).

## Validation Rules

- `Name` must be non-empty and contain no `=`; otherwise the line is skipped.
- Values are taken verbatim after trimming and quote removal; no interpolation,
  variable expansion, or inline-comment stripping in v1.

## Testing Requirements

`test_env.pas`:

- [ ] `TestParsesSimplePairs`
- [ ] `TestIgnoresCommentsAndBlankLines`
- [ ] `TestStripsExportPrefix`
- [ ] `TestTrimsWhitespaceAndQuotes`
- [ ] `TestKeepsEqualsInValue`
- [ ] `TestSkipsMalformedLines`
- [ ] `TestApplySkipsExistingEnvironment`
- [ ] `TestLoadMissingFileIsNoOp`
- [ ] `TestLoadAppliesNewVariable`

Apply/load tests use a uniquely named variable and clear it first so they do not
depend on the host environment.

## Security Considerations

- Existing environment variables are never overwritten.
- Names and values are not logged.
- `.env` files are gitignored.

## Future Considerations

- Variable expansion and inline comments.
- Walking up parent directories to find the nearest `.env`.
