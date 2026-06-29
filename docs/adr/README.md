# Architecture Decision Records

This directory stores Architecture Decision Records (ADRs) for MMForge.

## What is an ADR?

An ADR documents a significant architectural decision, including context,
options considered, and the rationale for the chosen approach.

## Format

Use the template below. Number ADRs sequentially.

```markdown
# ADR-NNN: Title

Date: YYYY-MM-DD
Status: Proposed | Accepted | Deprecated | Superseded by ADR-XXX

## Context

What is the issue that we're seeing that is motivating this decision?

## Decision

What is the change that we're proposing and/or doing?

## Consequences

What becomes easier or harder as a result?
```

## When to Write an ADR

- Introducing a new crate or module boundary
- Choosing between competing libraries or approaches
- Deciding on a file format or protocol
- Changing a public API or data model
- Any decision that would be costly to reverse
