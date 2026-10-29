# Security Policy

## Reporting a vulnerability

**Do not open a public issue.** Email the maintainer at `security@oneking.studio`
with:

- the commit you tested,
- your platform and compiler version,
- what you were able to do that you should not have,
- and, if you have one, the smallest reproduction.

You will get an acknowledgement, an assessment, and a fix or a reasoned refusal.
Credit is offered unless you prefer otherwise.

## What this project is, security-wise

Hildi **runs shell commands on your machine**. That is its function, not a bug.
Everything below follows from that.

**The approval gate is the security boundary.** A command is shown to you, with
its effect classified, before it runs. Treat any way to execute without that
dialog appearing as a vulnerability — that includes:

- a shell construct whose effect is computed as *less* dangerous than it is
  (a write classified as a read, a path escaping the workspace),
- an approval scope broader than the text it was granted for,
- a grant that survives longer than advertised,
- a way to reach the executor without going through the gate.

**The workspace is the confinement boundary.** File tools are confined to the
workspace; a path traversal out of it is a vulnerability.

**Secrets at rest.** The store may contain conversation history, tool arguments,
and command output. It is created under `$XDG_DATA_HOME/hildi` with owner-only
permissions. Anything that weakens that is a vulnerability.

## What is explicitly *not* in scope

- **The model deciding to run a harmful command you approved.** The gate shows
  you the command; approving it is a decision, not an exploit.
- **Prompt injection that produces a visible approval prompt you then accept**
  without reading it. That is the design working as intended, however
  socially-engineered the prompt.
- **Running with `--approval-root` set to something broad**, or granting a
  workspace-wide scope. Those are deliberate operator choices, documented as
  such.
- **A compromised local machine.** An attacker with your user account can read
  the store and the API key directly.
- **The API key reaching your configured LLM endpoint.** That is what the key is
  for.

## Supported versions

Pre-1.0: only the tip of `main` is supported. There are no backports.

## Dependencies

Vendored libraries (SQLite, mbedTLS) are fetched at pinned revisions and
checksummed by the scripts in `scripts/`. A checksum mismatch aborts the fetch.
If you find a vulnerability in a vendored dependency, report it here and to the
upstream project.
