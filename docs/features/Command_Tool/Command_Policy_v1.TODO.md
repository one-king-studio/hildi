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

- [ ] **Add** `tests/test_command_policy.pas` to the `uses` clause of
      `tests/hildegard_helper_tests.pas`
- [ ] **Create** `src/hildegard.helper.command.policy.pas` with the interface
      types from the SPEC (no bodies)
- [ ] **Create** `tests/test_command_policy.pas` with an empty `TTestCase`

### Phase 2: Parser (TDD)

- [ ] **Test**: `TestEmptyCommandAsks`
- [ ] **Test**: `TestSingleCommandParsed`, `TestLeadingAssignmentSkipped`
- [ ] **Test**: `TestSingleQuotesAndDoubleQuotesStripped`,
      `TestEscapedOperatorIsNotOperator`
- [ ] **Test**: `TestSemicolonSplitsSegments`, `TestAndOrPipeSplitSegments`,
      `TestBackgroundOperator`
- [ ] **Test**: `TestExecutableWithPathKeepsTokenAndBasename`
- [ ] **Test**: `TestRedirectionExtractedFromArgv`, `TestRedirectTargetIsPath`
- [ ] **Test**: `TestUnbalancedQuoteAsks`
- [ ] **Implement**: `ParseCommand` incrementally until all parser tests are
      green (single scan, quote/escape state, segment operators)
- [ ] **Test**: `TestUnresolvedVariablePathIsUnresolved`,
      `TestHomeAndAbsoluteAndRelativePathKinds`
- [ ] **Implement**: literal path classification (`pkRelative`/`pkAbsolute`/
      `pkHome`/`pkUnresolved`)

### Phase 3: Classifier (TDD)

- [ ] **Test**: `TestDenyBeatsAllow`, `TestDenyPatternMatchesBasename`,
      `TestGlobPatternMatches`
- [ ] **Test**: `TestAllowWhenAllSegmentsAllowed`,
      `TestAskWhenAnySegmentUnmatched`
- [ ] **Test**: `TestInterpreterAsksUnlessAcknowledged`,
      `TestInterpreterAllowedWhenAcknowledgedAndAllowed`
- [ ] **Test**: `TestPathOutsideRootsAsks`, `TestPathInsideRootsAllowed`,
      `TestRelativeDotDotEscapeAsks`
- [ ] **Implement**: `ClassifyCommand` in the precedence order from the SPEC
- [ ] **Implement**: `IsInterpreter`, `DefaultCommandPolicy`

### Phase 4: Integration

- [ ] **Test**: `TestClassifyCompoundCommandWithMixedSegments` - a realistic
      pipeline decides **ask** and names the offending segment

### Phase 5: Validation

- [ ] `make test SUITE=TestCommandPolicy`
- [ ] `make test`
- [ ] `make test-leak`
- [ ] `make check`

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

- [ ] Every SPEC precedence rule has a passing test
- [ ] Unit is pure: no I/O, no globals, no exceptions on arbitrary input
- [ ] `make check` passes
- [ ] Implementation matches the specification

## Notes & Considerations

- Treat all managed records with `Default`/explicit init; `-Sew` makes uninitialised
  warnings fatal (see `docs/guidelines/testing.md`).
- `ParseError` is data, not an exception; never raise from `ParseCommand`.
- Keep POSIX literals inside the POSIX handling; `TCommandPolicy` and the
  classifier must not branch on syntax beyond passing `ASyntax` to the parser.
- `MatchesMask` handles `*`/`?`; test the basename-vs-full-token matching
  explicitly.
