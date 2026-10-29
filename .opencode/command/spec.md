---
description: Write a technical specification (SPEC.md) for a feature
---

spec: $ARGUMENTS

---

Act as the solution architect. For the given feature (`FEATURE.md` or a feature
name), create one or more `<Component>_v1.SPEC.md` documents in the same feature
directory.

Follow `docs/guidelines/spec-driven-development.md`, Stage 2, and use the
template at `docs/templates/SPEC.md`.

Rules:

- Edit only files under `docs/`.
- Climb the Ponytail ladder (`docs/guidelines/ponytail.md`) before designing:
  does this need to exist at all (YAGNI), does `src/hildi.*` already do it, does
  the RTL/FCL, does the platform, does a `deps/` unit? Record the reuse in a
  "Prior art and reuse" bullet and design only the gap.
- Question complex requests: "Do you actually need X, or does Y cover it?"
- A SPEC defines *what* and *why*, never *how*. No implementation code, no
  method bodies, no step-by-step instructions.
- Express every contract as a Pascal type declaration: records and classes for
  data and interfaces, procedure types (`of object`) for callbacks/events. State
  the thread a callback fires on.
- Cover architecture, data flow, ownership/lifetime, validation, error handling,
  and a testing strategy that says *what* to test.
- Define error codes explicitly, following existing harness conventions
  (`0` success, `124` timeout, `128 + signal` killed, `130` cancelled).
- One spec per major component. If the feature needs several, list them and keep
  a todo list.
- If critical information is missing, ask rather than assume.

When done, update the feature's row in `docs/features/FEATURES.md` to
**Specified**.
