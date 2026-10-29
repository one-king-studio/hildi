# Agent to Agent (A2A)

## Overview

Today Hildi is a local execution core: it runs host shell commands and file
operations through a bounded-concurrency pool, gated by an approval dialog. This
feature lets it participate in a wider mesh — to **receive work from other
agents**, and to delegate work to them, regardless of where those agents run.

The idea is deliberately narrow. An agent is only useful where it can act, and
that is usually one machine. A2A is the seam that lets an agent elsewhere hand
Hildi a task and get a result back, without requiring either side to be
reachable from the internet in any particular way.

This document is an intentional sketch. It records the shape of the idea and the
constraints that follow from it; it does not specify a wire protocol.

## Problem Statement

An agent can reason and delegate internally, but it can only act inside the
environment it runs in. A user's laptop, home server, or CI box is out of reach,
so work on the machines the user actually cares about falls back to copy-pasting
commands and reporting results by hand — slow, error-prone, and outside the
agent's awareness.

Making a device reachable is awkward in the usual direction. Most devices sit
behind NAT and a firewall, so a design that waits for something to connect *in*
needs a public address, port forwarding, or a tunnel. An outbound-first
connection avoids all of that.

Applying the first rung of the Ponytail ladder (`docs/guidelines/ponytail.md`):
the execution core already exists. The genuine gap is narrow — how peers find
each other, how a request is carried and correlated with its result, and what
security policy surrounds executing a request that originated elsewhere. No
general RPC framework, no server implementation, no UI.

## Goals

- Let a peer agent submit a request and receive its outcome, providing the
  result is trustworthy.
- Keep the approval gate authoritative. A request from a peer is a *proposal*,
  not a grant; the same dialog that guards a local instruction must guard a
  remote one.
- Work across NAT and firewalls without inbound reachability.
- Fail visibly. A peer that goes away must not leave a request silently pending.
- Stay small enough that the core harness remains lean when A2A is unused.

## Non-Goals

- A general-purpose RPC or messaging framework.
- A hosted service, control plane, or account system.
- Multi-tenant anything. This is one operator reaching their own agents.
- Replacing the local approval model with a remote trust model.

## Design Sketch

Three pieces, in the order they matter:

1. **Identity.** A peer is a key, not an account. Trust is established by an
   explicit pairing step and persisted locally; there is no central authority
   whose compromise compromises every installation.

2. **Transport.** Outbound-first, so no peer needs a public address. The existing
   session socket and protocol carry a local session; A2A generalises that
   envelope to a peer that may be anywhere, rather than inventing a second one.

3. **Policy.** An inbound request resolves through the same approval engine as a
   local instruction, with the originating peer as part of the ask. An operator
   can therefore grant a narrow capability to a specific peer, and refuse it to
   every other.

## Open Questions

- Does a peer request need its own approval bucket, or does it reuse the effect
  classes the shell already computes?
- When the operator is not present, what is the default — deny, or a scoped
  standing grant per peer?
- Is delivery at-least-once with idempotent execution, or exactly-once with a
  durable queue? The store already has a change log to build on.

## Status

**Proposed.** No code. This document replaces the earlier `Remote_Agent_Link`
feature, which specified one particular server's endpoints; A2A keeps the useful
part — an agent reachable from outside its own environment — and drops the
dependency on any specific back end.
