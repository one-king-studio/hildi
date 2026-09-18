---
description: Implement a SPEC (or a task) test-first
---

task: $ARGUMENTS

---

If the argument is a `.SPEC.md` file, implement or continue implementing the
solution it describes, following `docs/guidelines/spec-driven-development.md`
(Stages 3 and 4) and the project constraints in `AGENTS.md`. Otherwise, follow
the provided instructions.

Before writing any code, climb the Ponytail ladder
(`docs/guidelines/ponytail.md`): YAGNI first, then reuse from `src/hildegard.helper.*`,
then the FPC RTL/FCL, then the platform, then `deps/`. Write only the gap. Fix
bugs at the root cause - grep the callers and fix the shared function once, not
each symptom site. Mark deliberate shortcuts with a `ponytail:` comment naming
the ceiling and the upgrade path.

Workflow:

1. Read the SPEC thoroughly, plus its related `FEATURE.md`. If anything is
   unclear, ask before writing code.
2. Create or update the matching `<Component>_v1.TODO.md` from
   `docs/templates/TODO.md`.
3. Work test-first. For each behaviour:
   - Add a failing fpcunit test in `tests/` and watch it fail with
     `make test SUITE=<TestName>` (red).
   - Implement the minimum in `src/` to pass (green).
   - Refactor while green.
4. Keep units in `{$mode delphi}{$H+}`, named `hildegard.helper.<area>`. Add any
   new `tests/test_*.pas` unit to the `uses` clause of
   `tests/hildegard_helper_tests.pas`.
5. Mark tasks complete in the TODO as you go; record deviations from the spec.
6. Run `make check` (all tests + the heaptrc leak gate) before considering any
   task done.
7. When every task is complete and `make check` is green, rename the TODO to
   `<Component>_v1.DONE.md` and update `docs/features/FEATURES.md`.

Respect the FPC/platform constraints in `AGENTS.md` (cthreads first, no
`TSemaphore` on macOS, `TDictionary.AddOrSetValue`, warnings-are-errors).
