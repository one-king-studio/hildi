# Feature Name

## Overview

Brief description of the feature and its purpose within the harness.

## Problem Statement

The problem this feature solves, or the opportunity it addresses. Who feels the
pain today, and what does it cost them?

Before proposing anything, apply the first rung of the Ponytail ladder
(`docs/guidelines/ponytail.md`): does this need to be built at all, or does
existing harness behaviour already cover it?

## Goals

- Primary goal 1
- Primary goal 2
- Primary goal 3

## User Stories

As a `<type of user>`, I want `<some goal>` so that `<some reason>`.

Example:

- As a harness author, I want to run several subagents concurrently so that I can
  finish a batch of commands faster.

## Acceptance Criteria

The specific, testable conditions that must hold for this feature to be
considered complete.

### Functional Requirements

- [ ] Requirement 1
- [ ] Requirement 2
- [ ] Requirement 3

### Non-Functional Requirements

- [ ] Performance (e.g. startup overhead, throughput)
- [ ] Reliability (e.g. no leaks, graceful failure)
- [ ] Portability (e.g. macOS + Linux)

## Success Metrics

### Quantitative

- Metric 1: `<specific measurable target>`
- Metric 2: `<specific measurable target>`

### Qualitative

- Ease of use, clarity of the API, maintainability

## Constraints

### Technical

- Must build with Free Pascal 3.3.1, `{$mode delphi}`
- Must not depend on platform primitives unavailable on macOS
- Must keep `make check` green

### Business / Time

- Any deadlines or effort limits

## Dependencies

### Internal

- Existing units, specs, or features this builds on

### External

- Third-party units under `deps/`, host tooling, OS facilities

## Risks

- Risk 1: `<description>` - Mitigation: `<strategy>`

## Out of Scope

Explicitly state what this feature does *not* include, to prevent scope creep.

## Future Considerations

Ideas for later enhancement that are intentionally deferred.

## Notes

Additional context. Include an ICE score (Impact, Confidence, Ease; 1-10 each)
when prioritizing against other features.
