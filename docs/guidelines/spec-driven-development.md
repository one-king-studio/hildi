# Spec Driven Development

Spec Driven Development (SDD) is the structured approach to feature development
used in hildegard-helper. It ensures requirements are defined before implementation
begins, and it pairs naturally with the project's test-driven workflow: the
specification is the source of truth, and the tests are how we prove we met it.

## Overview

SDD follows a five-stage process:

1. **Feature Definition** - What should be built, and why?
2. **Technical Specification** - How will it be built?
3. **Implementation Planning** - What tasks need to be done?
4. **Implementation & Testing** - Build it test-first, tracking progress.
5. **Completion** - Verify, document, and close out.

The artifact chain for a feature lives in one directory:

```
docs/features/<Feature_Name>/
├── FEATURE.md                    # requirements (what/why)
├── <Component>_v1.SPEC.md        # technical design (how)
├── <Component>_v1.TODO.md        # implementation plan (tasks)
└── <Component>_v1.DONE.md        # completed plan
```

## Stage 1: Feature Definition

### Purpose

Define the "what" and "why": the problem, the users, and the acceptance
criteria.

### File Structure

- **Location**: `docs/features/<Feature_Name>/FEATURE.md`
- **Directory naming**: `Capital_Snake_Case`
- **Template**: `docs/templates/FEATURE.md`

### Content Requirements

- Overview, problem statement, and goals
- User stories with acceptance criteria
- Non-functional requirements (performance, reliability, security)
- Success metrics, constraints, dependencies, risks
- Explicit "out of scope"

Keep it about *what* and *why*; leave *how* to the specification.

## Stage 2: Technical Specification

### Purpose

Define the "how": the design, contracts, and behaviour of each component.

### File Structure

- **Location**: same directory as `FEATURE.md`
- **Naming**: `<Component>_v[version].SPEC.md` (start at `v1`)
- **One spec per major component**; several specs per feature are normal
- **Template**: `docs/templates/SPEC.md`

### Content Requirements

- Architecture and component boundaries
- **Prior art and reuse** - which existing units (`src/hildegard.helper.*`), RTL/FCL
  facilities, native platform features, or `deps/` units already cover part of
  this. Design only the gap; see `ponytail.md`.
- **Contracts and interfaces, expressed as Pascal type declarations** - records,
  classes, interfaces, and procedure types for callbacks/events
- Data models and state
- Data flow and integration patterns
- Validation rules and error handling
- Testing strategy: *what* must be tested (the tester decides *how*)
- Performance and security considerations

### Rule: No Implementation Code

A SPEC defines **what and why**, not **how**. Use Pascal type declarations,
contracts, and prose - never method bodies or line-by-line instructions. The
implementer decides the implementation.

## Stage 3: Implementation Planning

### Purpose

Break the specification into an ordered, trackable task list.

### File Structure

- **Location**: same directory as the specification
- **Naming**: `<Component>_v[version].TODO.md`
- **Template**: `docs/templates/TODO.md`

### Content Requirements

- Checkbox tasks grouped into phases
- The specific files each task creates or modifies
- Dependencies and suggested order; call out what can run in parallel
- A **Testing** phase that names the fpcunit test cases to be written
- Clear completion criteria for each task

## Stage 4: Implementation & Testing

### Branch Strategy

- Work on a dedicated branch: `feature/<feature-name>/<component-name>`

### TDD-First

Every task begins with a failing test. The loop is:

1. Add a test in `tests/` that expresses the next SPEC requirement.
2. `make test SUITE=<TestName>` - watch it fail (**red**).
3. Implement the minimum in `src/` to make it pass (**green**).
4. Refactor; rerun `make test SUITE=<TestName>`.
5. `make check` before moving on (all tests + the heaptrc leak gate).

Useful commands:

- `make test SUITE=<suite-or-test>` - one suite or one test method
- `make watch` - rerun the suite on every save
- `make test-leak` - leak-checked run (fails with exit 203 on leaks)
- `make check` - `test` + `test-leak`, the full gate

Tests are fpcunit `TTestCase` subclasses, one `tests/test_<unit>.pas` per unit.
Each acceptance criterion should map to at least one test.

Keep implementation lazy (`ponytail.md`): climb the ladder before writing code,
fix bugs at the root cause rather than the symptom, and mark any deliberate
shortcut with a `ponytail:` comment naming its ceiling and upgrade path.

### Real-Time Tracking

- Update `TODO.md` as tasks complete, not at the end.
- Record deviations from the specification and why.
- Newly discovered work gets a new task; don't silently expand scope.

## Stage 5: Completion

### Verification

- Confirm every acceptance criterion from `FEATURE.md` is met.
- Confirm every task in `TODO.md` is checked.
- `make check` passes cleanly.

### Documentation

- Rename `TODO.md` to `<Component>_v[version].DONE.md`.
- Update the SPEC if the implemented behaviour diverged from it.
- Update `docs/features/FEATURES.md` status.

## Key Principles

1. **Specification-first** - no implementation without a specification.
2. **Test-driven** - tests encode the specification; a solution that cannot be
   tested is a solution not worth doing.
3. **Clear acceptance criteria** - define "done" up front, measurably.
4. **Iterative refinement** - specs are living documents; bump the version for
   major revisions.
5. **Contracts in types** - express interfaces as Pascal types, not code.
6. **Documentation is a deliverable** - every feature has a FEATURE and at least
   one SPEC.
7. **Reuse before design (Ponytail)** - before specifying or building anything,
   climb the ladder: does it need to exist at all (YAGNI), does the codebase
   already do it, does the RTL/FCL, does the platform, does a `deps/` unit?
   See `ponytail.md`.
8. **Question complex requests** - a smaller answer is usually available; agree
   on scope before speccing it.

## Common Pitfalls

- **Skipping the spec** - treat spec creation as mandatory; the templates make it
  cheap.
- **Spec becomes implementation** - if a SPEC contains method bodies, move that
  detail to the code.
- **Stale docs** - update the SPEC when behaviour changes; bump the version.
- **TODO drift** - update `TODO.md` in real time; it is the progress tracker.
- **Untestable requirements** - if you cannot express an acceptance criterion as
  a test, the spec is not finished.

## Commands

- `/feature <description>` - draft or update a `FEATURE.md`
- `/spec <feature>` - draft a `<Component>_v1.SPEC.md` from a feature
- `/implement <spec>` - implement a SPEC test-first

## Related

- `AGENTS.md` - project overview, commands, FPC/platform notes
- `ponytail.md` - the lazy-senior-developer ladder and rules
- `docs/templates/` - FEATURE, SPEC, TODO templates
- `docs/features/` - all feature documentation
