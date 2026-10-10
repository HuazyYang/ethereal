# Architecture decision records

This folder holds the architecture decision records (ADRs) for the **ethereal aggregate**: decisions
that span more than one of its repositories, or that govern the aggregate build and its conventions.

An ADR records one significant design decision: the problem, the choice, what it costs, and what else
was considered. ADRs are kept even after the decision is replaced, so that a later reader can see why
the code looks the way it does. Implementation plans and their execution logs live in
[`../plans`](../plans/README.md). An ADR states *what* was decided and *why*; a plan states *how* the
work was carried out.

Each repository numbers its ADRs from `0001` independently. Cross-repository references are by path,
for example `ethereal-nvrhi/doc/adr/0008-aliasing-barriers-for-virtual-resources.md`.

| Repository | Folder |
| --- | --- |
| aggregate (this one) | `docs/adr`, `docs/plans` |
| `ethereal-donut` | `ethereal-donut/doc/adr`, `ethereal-donut/doc/plans` |
| `ethereal-nvrhi` | `ethereal-nvrhi/doc/adr`, `ethereal-nvrhi/doc/plans` |
| `ethereal-samples` | `ethereal-samples/doc/adr`, `ethereal-samples/doc/plans` |

## When to write one

Write an ADR here when a change:

- affects more than one repository in the aggregate;
- changes a shared convention (naming, directory layout, build options);
- changes the aggregate build or how the submodules fit together;
- picks one of several reasonable designs and the reason is not obvious from the code.

A decision confined to one repository belongs in that repository's folder. Do not write an ADR for
local refactors, bug fixes or formatting.

## Numbering and file names

- Files are named `NNNN-<kebab-case-title>.md`, with a four-digit number that is never reused.
- Take the next free number. Numbers are assigned in order of writing, not of importance.
- Directory names follow [`../conventions/naming.md`](../conventions/naming.md) (`snake_case`); the
  files in this folder are `kebab-case`, one consistent style per directory.

## Status

Each ADR has exactly one status:

| Status | Meaning |
| --- | --- |
| Proposed | Under discussion. The code may not follow it yet. |
| Accepted | In force. The code follows it. |
| Superseded by NNNN | Replaced by ADR NNNN. The text is kept unchanged except for this line. |

An accepted ADR is not rewritten when the decision changes. Write a new ADR, set the old one to
"Superseded by NNNN", and link back from the new one. Corrections of fact (a wrong path, a wrong hash)
may be made in place.

## Template

The format follows Michael Nygard's ADR format, with explicit sections for alternatives and references.

```markdown
# NNNN. Title in the imperative or as a noun phrase

- Status: Proposed | Accepted | Superseded by NNNN
- Date: YYYY-MM-DD

## Context

The forces at play: the problem, constraints, and relevant facts about the code.

## Decision

What was decided, stated so that a reviewer can check code against it.

## Consequences

### Positive
### Negative
### Risks

## Alternatives considered

Each alternative and why it was rejected.

## References

Commits (with repository), files, related ADRs and plans.
```

## Index

| ADR | Title | Status | Date |
| --- | --- | --- | --- |
| [0001](0001-snake-case-directory-names.md) | Directory names are `snake_case` | Proposed | 2026-10-04 |
| [0002](0002-query-cast-replaces-dynamic-cast-in-donut-and-samples.md) | `query_cast` replaces `dynamic_cast` in donut and the samples | Accepted | 2026-10-10 |
