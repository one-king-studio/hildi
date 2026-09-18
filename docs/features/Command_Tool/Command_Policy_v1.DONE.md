# Implementation Plan: Command Policy v1

**Related Specification:** `Command_Policy_v1.SPEC.md`
**Related Feature:** `FEATURE.md`

## Overview

Build `hildegard.helper.command.policy`: a pure parser/classifier that turns a
POSIX command line into a `TCommandPlan` and classifies it against a
`TCommandPolicy` as allow/ask/deny. It executes nothing and reads no store, so
this can be built independently of the other components.

> Deviation from template: `main`-only project, no feature branch.

## Implementation Tasks

### Phase 1: Setup & Foundation

- [x] **Add** `tests/test_command_policy.pas` to the `uses` clause of
      `tests/hildegard_helper_tests.pas`
- [x] **Create** `src/hildegard.helper.command.policy.pas` with the interface
      types from the SPEC (no bodies)
- [x] **Create** `tests/test_command_policy.pas` with an empty `TTestCase`

### Phase 2: Parser (TDD)

- [x] **Test**: `TestEmptyCommandAsks`
- [x] **Test**: `TestSingleCommandParsed`, `TestLeadingAssignmentSkipped`
- [x] **Test**: `TestSingleQuotesAndDoubleQuotesStripped`,
      `TestEscapedOperatorIsNotOperator`
- [x] **Test**: `TestSemicolonSplitsSegments`, `TestAndOrPipeSplitSegments`,
      `TestBackgroundOperator`
- [x] **Test**: `TestExecutableWithPathKeepsTokenAndBasename`
- [x] **Test**: `TestRedirectionExtractedFromArgv`, `TestRedirectTargetIsPath`
- [x] **Test**: `TestUnbalancedQuoteAsks`
- [x] **Implement**: `ParseCommand` incrementally until all parser tests are
      green (single scan, quote/escape state, segment operators)
- [x] **Test**: `TestUnresolvedVariablePathIsUnresolved`,
      `TestHomeAndAbsoluteAndRelativePathKinds`
- [x] **Implement**: literal path classification (`pkRelative`/`pkAbsolute`/
      `pkHome`/`pkUnresolved`)

### Phase 3: Classifier (TDD)

- [x] **Test**: `TestDenyBeatsAllow`, `TestDenyPatternMatchesBasename`,
      `TestGlobPatternMatches`
- [x] **Test**: `TestAllowWhenAllSegmentsAllowed`,
      `TestAskWhenAnySegmentUnmatched`
- [x] **Test**: `TestInterpreterAsksUnlessAcknowledged`,
      `TestInterpreterAllowedWhenAcknowledgedAndAllowed`
- [x] **Test**: `TestPathOutsideRootsAsks`, `TestPathInsideRootsAllowed`,
      `TestRelativeDotDotEscapeAsks`
- [x] **Implement**: `ClassifyCommand` in the precedence order from the SPEC
- [x] **Implement**: `IsInterpreter`, `DefaultCommandPolicy`

### Phase 4: Integration

- [x] **Test**: `TestClassifyCompoundCommandWithMixedSegments` - a realistic
      pipeline decides **ask** and names the offending segment

### Phase 5: Validation

- [x] `make test SUITE=TestCommandPolicy`
- [x] `make test`
- [x] `make test-leak`
- [x] `make check`

## Dependencies & Ordering

### Must Complete Before Starting

- None. Independent of `Tool_Reason_v1` and `Command_Tool_v1`.

### Can Be Done in Parallel

- Parser work is independent of classifier tests once the types exist.

### Critical Path

1. Types
2. Parser
3. Path classification
4. Classifier precedence
5. `make check`

## Files to Create/Modify

### New Files

```
src/hildegard.helper.command.policy.pas
tests/test_command_policy.pas
```

### Modified Files

```
tests/hildegard_helper_tests.pas   (add test unit to uses)
```

## Success Criteria

- [x] Every SPEC precedence rule has a passing test
- [x] Unit is pure: no I/O, no globals, no exceptions on arbitrary input
- [x] `make check` passes
- [x] Implementation matches the specification

## Notes & Considerations

- Treat all managed records with `Default`/explicit init; `-Sew` makes uninitialised
  warnings fatal (see `docs/guidelines/testing.md`).
- `ParseError` is data, not an exception; never raise from `ParseCommand`.
- Keep POSIX literals inside the POSIX handling; `TCommandPolicy` and the
  classifier must not branch on syntax beyond passing `ASyntax` to the parser.
- `MatchesMask` handles `*`/`?`; test the basename-vs-full-token matching
  explicitly.
- Deviation: FPC 3.3.1 has no RTL/FCL `MatchesMask` unit, so a small iterative
  `MatchMask` glob matcher (`*`/`?`, case-sensitive) lives in this unit instead
  of pulling a dependency. The SPEC's `MatchesMask` reference is descriptive, not
  binding.
