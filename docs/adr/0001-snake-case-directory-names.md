# 0001. Directory names are `snake_case`

- Status: Proposed
- Date: 2026-10-04

## Context

`docs/conventions/naming.md` required directory names to be `kebab-case`:

> Directory names **must** be `kebab-case`: lowercase words separated by hyphens.
> Good: `shader-tools`, `render-passes` â€?Bad: `shaderTools`, `Render_Passes`, `RenderPasses`

In practice almost every directory in the three first-party trees is a single lowercase word, where
`kebab-case` and `snake_case` are indistinguishable: `core`, `engine`, `render`, `app`, `shaders`,
`tools`, `tests`, `doc`, `adr`, `plans`, `thirdparty`. The rule therefore had very little to constrain,
and only four directories in the whole tree actually contain a separator:

| Directory | Note |
| --- | --- |
| `ethereal-donut/thirdparty/shader-tool` | Submodule path; also the upstream repository name `HuazyYang/shader-tool`. Renamed from `shadertool` very recently (donut `d4e24c0`, `ca08c03`; aggregate `1e90a72`, `3d175c3`). |
| `ethereal-donut/thirdparty/jsoncpp-amalgam` | Third-party source drop, upstream spelling. |
| `ethereal-samples` | Submodule path; also the repository name. Referenced from the aggregate's `.gitmodules`. |
| `.vscode/vscode-cpptools` | Editor-generated. |

Meanwhile C++ identifiers, file names and the surrounding code lean on `snake_case` and `PascalCase`;
hyphens appear nowhere in the languages used in this tree, so a hyphenated directory cannot be part of
an include path component that is also an identifier, and it reads inconsistently beside
`nvrhi::fixed_vector`, `donut::engine`, `render_passes`-style naming and the `UPPER_SNAKE_CASE` macro
rule in the same document.

The FrameGraph work (donut ADR 0001) adds the first substantial new directories in a while, which
forced the question before the inconsistency was duplicated.

## Decision

Directory names in `ethereal`, `ethereal-donut` and `ethereal-donut/ethereal-nvrhi` **must** be `snake_case`: lowercase words
separated by underscores.

A single compound word conventionally written without a break takes no underscore: `framebuffer`,
`framegraph`, `thirdparty`.

The rule applies to **new** directories only. The four directories listed above keep their names and
are recorded in `docs/conventions/naming.md` as deliberate exceptions, so that a later reader does not
mistake them for drift or cite them as precedent.

File naming is unchanged: `kebab-case`, `snake_case` or `PascalCase`, never `camelCase`, one consistent
style per directory. Directory and file naming are independent questions â€?an `adr/` directory
containing `0001-snake-case-directory-names.md` satisfies both rules.

## Consequences

### Positive

- Directory names match the dominant convention of the code they contain, and the separator agrees
  with the `UPPER_SNAKE_CASE` macro rule in the same document.
- A directory name is now always a legal C++ identifier component, so a path fragment can be reused as
  a namespace or target-name fragment without transformation.
- No code, build file or submodule path changes: the new rule constrains only directories that do not
  exist yet.

### Negative

- The tree now contains four `kebab-case` directories that contradict the stated rule. They are
  documented as exceptions, but a reader must consult the table to know they are intentional.
- A convention was changed rather than followed, which costs a reader one indirection when they find
  older discussion referring to the `kebab-case` rule.

### Risks

- The exceptions could be cited as precedent for new `kebab-case` directories. Mitigated by stating in
  `naming.md` that they are not precedent, and by keeping the reason for each in the table.
- If `shader-tool` or `ethereal-samples` is ever renamed upstream, the exception table must be updated
  alongside `.gitmodules`.

## Alternatives considered

- **Keep `kebab-case` and rename nothing.** Rejected: the rule conflicts with the `snake_case` and
  `UPPER_SNAKE_CASE` conventions in the same file, and a hyphen cannot appear in an identifier, so the
  directory name can never be reused as one.
- **Keep `kebab-case` and rename the new FrameGraph directories to match.** Rejected on the same
  grounds; it would have entrenched the inconsistency in the largest new subsystem.
- **Adopt `snake_case` and rename all four existing directories.** Rejected: `shader-tool` and
  `ethereal-samples` are submodule paths and repository names, so renaming them touches `.gitmodules`
  in two repositories, the aggregate's CMake paths and the remotes themselves â€?a large, risky change
  with no functional benefit. `shader-tool` had also just been renamed *to* that spelling, so renaming
  it again would churn the same paths twice in short succession.
- **Allow either style.** Rejected: a convention document that permits both constrains nothing, which
  is the problem the rule existed to solve.

## References

- Files: `docs/conventions/naming.md`.
- Related: `ethereal-donut/doc/adr/0001-framegraph-for-donut-render-passes.md` (the work that raised the
  question).
- Prior renames that produced the `shader-tool` exception: donut `d4e24c0`, `ca08c03`; aggregate
  `1e90a72`, `3d175c3`.
- Plan: [`../plans/2026-10-04-framegraph.md`](../plans/2026-10-04-framegraph.md), step 0.
