# Contributing

## Pull requests are closed for now

Hildi is **pre-1.0 and moving quickly**. While interfaces, storage layout, and
CLI flags are still changing, accepting contributions would mean asking you to
build on ground that moves under you — and then asking you to rebase it.

**Pull requests are not being merged at this time.** This is a deliberate,
temporary choice, not a judgement about your work.

## Forking is welcome

The MIT licence means you can fork, modify, and redistribute this project for any
purpose, including commercially. That is intentional. If you need different
behaviour today, fork it — you do not need permission.

If you build something on a fork that you think belongs upstream, keep it; if
this project opens to contributions later, a well-shaped fork is the most
persuasive argument for a change we could ask for.

## Issues

Issues are the useful channel right now:

- **Reproducible bugs** — include the commit, your platform, the compiler
  version, and the smallest input that shows the problem.
- **Distribution problems** — anything that makes building or running harder on
  your platform is on-topic and valuable, since portability is the point of the
  project.

Please do not open an issue to request a feature and then implement it as a pull
request; the PR will be closed. Open the issue, describe the need, and let it be
weighed.

## Security

Do not open a public issue for a vulnerability. See [`SECURITY.md`](SECURITY.md).

## Building from a fork

```sh
make deps      # fetch and checksum vendored sqlite, mbedtls, a CA bundle
make check     # build everything, run the suite and the leak gate
```

Two conventions worth knowing before you change anything:

- **The gate is `make check`.** It runs the suite twice (once under a heap
  tracker), and it is the only definition of green. A change that passes one
  pass and fails the other is not done.
- **This project is spec-driven.** Every feature has a `FEATURE.md` and a
  `SPEC.md` under `docs/features/` before it has code. Read
  [`docs/guidelines/spec-driven-development.md`](docs/guidelines/spec-driven-development.md)
  and [`AGENTS.md`](AGENTS.md) — they describe how changes are shaped here, and
  they apply to a fork that hopes to be mergeable later.

## Licence of contributions

If contributions open up in the future, they will be accepted under the project's
MIT licence. No copyright assignment will be required.
