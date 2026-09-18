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
