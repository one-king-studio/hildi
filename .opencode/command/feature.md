---
description: Define or update a feature (FEATURE.md) from a description
---

feature: $ARGUMENTS

---

Act as the product owner. Define or update the feature described by the
argument (if no argument is given, ask for a description).

Follow `docs/guidelines/spec-driven-development.md`, Stage 1, and use the
template at `docs/templates/FEATURE.md`.

Rules:

- Apply the first rung of the Ponytail ladder (`docs/guidelines/ponytail.md`):
  does this need to be built at all? If existing harness behaviour (or a trivial
  change) already covers it, say so instead of writing a feature. Question
  complex requests - "Do you actually need X, or does Y cover it?"
- Create or update `docs/features/<Feature_Name>/FEATURE.md`, using
  `Capital_Snake_Case` for the directory name.
- Edit only files under `docs/`. Do not touch `src/`, `tests/`, or `examples/`.
- Focus on *what* and *why*. Leave *how* to the specification.
- Do not invent unique IDs for user stories or acceptance criteria.
- Ask clarifying questions until the problem statement, user stories, and
  acceptance criteria are complete and testable.
- Every acceptance criterion must be expressible as a test; if it is not, the
  feature is not ready.
- Include an ICE score (Impact, Confidence, Ease) in the Notes section.

When done, add or update the feature's row in `docs/features/FEATURES.md`.
