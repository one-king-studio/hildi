# Source Control Guidelines

This project uses Git for source control. Commits follow the
[Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)
format and include a Gitmoji-style emoji to add a visual indicator of scope.

## Commit Structure

The expected commit structure is:

```
<type>[optional scope]: <emoji> <description>

[optional body]

[optional footer(s)]
```

### Commit Types

The following commit types are allowed:

- `fix` - patches a bug
- `feat` - introduces a new feature or functionality
- `build` - changes that affect the build system or external dependencies
- `chore` - routine tasks, maintenance, or tooling changes
- `ci` - changes to CI configuration files and scripts
- `docs` - documentation-only changes
- `style` - changes that do not affect code meaning (formatting, whitespace, etc.)
- `refactor` - code changes that neither fix bugs nor add features
- `perf` - performance improvements
- `test` - adding or correcting tests

### Gitmoji Usage

Include a relevant emoji after the colon to visually indicate the scope of the
commit. For example:

- `fix: 🐛 Fix login authentication bug`
- `feat: ✨ Add dark mode toggle`
- `docs: 📝 Update README with installation instructions`
- `refactor: ♻️ Simplify component structure`

### Commit Body

Use the commit body to provide additional context when needed:

- Explain the "why" behind the change
- Describe any technical decisions
- Reference related issues or pull requests

### Commit Footers

Use footers for metadata:

- `BREAKING CHANGE:` for changes that require migration steps
- `Closes #123` to link to issues

## Branch Strategy

### Parallel Agent Playgrounds (worktrees)

Multiple agents work the same project in parallel, each in its own **git
worktree** under `.worktrees/` inside the repo (nested worktrees are fine;
the directory is gitignored so the main tree stays clean):

```sh
git worktree add .worktrees/agent-mcp -b agent/mcp
git worktree add .worktrees/agent-tls -b agent/tls
```

- **One playground per agent**, one feature branch per playground. Each
  playground is a full checkout: its own build, its own store, its own
  session sockets - playgrounds cannot collide at runtime, not just at git
  level.
- **Branch naming**: `agent/<topic>` (lowercase, hyphens). A playground
  that finishes its feature starts a fresh branch from the new main; do
  not reuse a merged branch.
- **Main checkout = integrator.** Agent branches never land on main
  directly. The integrator merges one branch at a time (see Integration
  below) and owns the shared doc index (`FEATURES.md`, `HANDOFF.md`) plus
  the tests' `uses` registration - the guaranteed-conflict files. Agents
  work their feature folder, `src/`, and their tests; they do not edit
  integrator-owned files.
- **Rebase discipline (the two moments)**:
  1. *Sync rebase* - every agent session starts with `git rebase main`
     (clean tree first: commit or stash). At main's velocity, stale
     playgrounds turn small conflicts into trench warfare; fresh ones get
     resolved with context. Granular commits stay granular - never squash
     during sync.
  2. *Integration rebase* - the integrator re-confirms the branch is on
     current main, runs `make check`, then `git merge --ff-only`. If it
     cannot fast-forward, the discipline slipped - stop and fix; do not
     merge-commit past it. Linear history is enforced, not hoped for.
- **Dispatcher**: the main Makefile delegates to the denoted playground.
  `.worktrees/ACTIVE` (one-line file) names it: `make agent-tui` builds
  the active playground, `make agent-tui ACTIVE=mcp` overrides for one
  call, `echo mcp > .worktrees/ACTIVE` persists it. The dispatcher
  delegates with `$(MAKE) -C` and never recurses.
- **Hygiene**: searches from the main root are path-scoped (`src/`,
  `docs/`) so recursive tools do not wander into playgrounds; `make
  agents` lists worktrees with ahead/behind vs main and flags stale ones
  (behind by more than ~20 commits).

### Feature Branches

Create feature branches for new development, mirroring the artifact naming in
`spec-driven-development.md`:

```
feature/<feature-name>/<component-name>
```

Example: `feature/agent-loop/llm-client`

### Branch Naming

- Use lowercase with hyphens
- Be descriptive but concise
- Include feature and component context

### Pull Requests

- Create pull requests for all feature branches
- Include comprehensive descriptions
- Link to related issues

## Best Practices

### Atomic Commits

Each commit should represent a single logical change:

- Focus on one aspect of the codebase
- Keep changes small and manageable
- Avoid mixing unrelated changes

### Descriptive Messages

Write commit messages that clearly explain:

- What changed
- Why it changed
- Any implications or side effects

### Regular Commits

Commit frequently to:

- Maintain a clear history
- Reduce merge conflicts
- Enable incremental progress tracking

### Review Before Committing

Always review changes before committing:

- Use `git diff` to see what will be committed
- Ensure no unintended changes are included
- Verify the gate is green (`make check`) for code changes
- Never commit secrets or credentials

## Related Guidelines

- [Spec Driven Development](./spec-driven-development.md) - feature development
  workflow and artifact chain
- [Ponytail](./ponytail.md) - reuse and laziness principles
