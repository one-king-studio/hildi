# Implementation Plan: [Component Name] v[version]

**Related Specification:** `[Component_Name]_v[version].SPEC.md`
**Related Feature:** `../FEATURE.md`

## Overview

Task breakdown for the component specified in
`[Component_Name]_v[version].SPEC.md`. Tasks are checkboxes; update them in
real time as you work. Each implementation task starts with a failing test.

## Implementation Tasks

### Phase 1: Setup & Foundation

- [ ] **Create branch**: `feature/[feature-name]/[component-name]`
- [ ] **Add the test unit** to the `uses` clause of `tests/hildegard_helper_tests.pas`
- [ ] **Define shared types** in `src/hildegard.helper.[component].pas` (interface section only)

### Phase 2: Core Implementation

For each public behaviour, follow the TDD loop
(`docs/guidelines/spec-driven-development.md`, Stage 4).

- [ ] **Test**: `<TestCase method>` in `tests/test_[component].pas` - fails (red)
- [ ] **Implement**: minimum in `src/hildegard.helper.[component].pas` - passes (green)
- [ ] **Refactor**: tidy while green
- [ ] **Repeat** for the next behaviour

### Phase 3: Concurrency & Cleanup (if applicable)

- [ ] **Test**: threads join and objects are freed (leak-clean)
- [ ] **Implement**: correct `WaitFor`/`Free` and guarded shared state

### Phase 4: Example & Docs

- [ ] **Update the example** in `examples/` to exercise the new behaviour
- [ ] **Doc comments**: `{** ... }` on the public interface (fpdoc style)
- [ ] **Update the SPEC** if the implemented behaviour diverged

### Phase 5: Validation

- [ ] **Run**: `make test SUITE=<new tests>` (green)
- [ ] **Run**: `make test` (whole suite)
- [ ] **Run**: `make test-leak` (no leaks)
- [ ] **Run**: `make check` (all gates)

## Dependencies & Ordering

### Must Complete Before Starting

- `<Task A>` must be done before `<Task B>`
- Types in the interface section must be defined before tests that use them

### Can Be Done in Parallel

- Independent test cases
- Example updates alongside tests

### Critical Path

1. Types and contracts
2. First failing test
3. Minimum implementation
4. Remaining behaviours
5. Example, docs, `make check`

## Files to Create/Modify

### New Files

```
src/hildegard.helper.[component].pas
tests/test_[component].pas
```

### Modified Files

```
tests/hildegard_helper_tests.pas   (add the new test unit to uses)
examples/...            (exercise the new behaviour)
Makefile                (only if new sources need new targets)
```

## Success Criteria

- [ ] All tasks above checked
- [ ] Every acceptance criterion maps to a passing test
- [ ] `make check` passes (tests + leak gate)
- [ ] Example demonstrates the feature
- [ ] Implementation matches the specification

## Notes & Considerations

- Record deviations from the specification here, with the reason
- Performance and thread-safety notes
- Anything discovered that suggests a spec revision
