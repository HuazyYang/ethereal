# Implementation plans

This folder holds implementation plans for work that spans more than one repository of the ethereal
aggregate, or that changes the aggregate itself.

A plan describes *how* a piece of work is carried out: the steps, their order, the commits, and how the
result is verified. The design decisions behind the work are recorded separately as architecture
decision records in [`../adr`](../adr/README.md). A plan links to the ADRs it implements, and each ADR
links back to its plan.

A plan for work confined to one repository belongs in that repository's `doc/plans` folder.

## When to write one

Write a plan for work that spans several commits or repositories (the aggregate, `ethereal-donut`,
`ethereal-nvrhi`, `ethereal-samples`), or that needs a reviewed order of steps so that every commit still
builds.

## File names

- `YYYY-MM-DD-<slug>.md`, where the date is the day the plan was approved and `<slug>` is a short
  kebab-case description, for example `2026-10-04-framegraph.md`.
- Directory names follow [`../conventions/naming.md`](../conventions/naming.md) (`snake_case`); the
  files in this folder are `kebab-case`, one consistent style per directory.
- Do not rename a plan when its status changes.

## Status

The first lines of each plan give its status and dates:

| Status | Meaning |
| --- | --- |
| Draft | Being written or reviewed. Not yet agreed. |
| Approved | Agreed. Work may be in progress. |
| Done | All steps finished. The plan is a historical record. |
| Abandoned | Stopped. Say why in the plan. |

## Structure

A plan should contain:

1. **Context:** the problem and the decisions already taken, with links to the ADRs.
2. **Steps:** what each step changes, in which repository, in what order.
3. **Verification:** builds, tests and runs that show the result works.

When the work is done, add:

4. **Execution record:** per step, what was done, the commits (with repository and short hash), and
   every deviation from the plan with its reason. Where the code differs from the plan, the code wins:
   do not edit the plan text to match the code; record the deviation.
5. **Verification results:** what was actually run and what passed or failed.
6. **Known issues and follow-ups:** failures found along the way, whether they were caused by the work,
   and open tasks.

Keep local user paths, machine names and credentials out of plans. Use repository-relative paths.

## Index

| Plan | Status | ADRs |
| --- | --- | --- |
| [2026-10-04-framegraph.md](2026-10-04-framegraph.md) | Draft | root [0001](../adr/0001-snake-case-directory-names.md); donut [0001](../../ethereal-donut/doc/adr/0001-framegraph-for-donut-render-passes.md) |
| [2026-10-04-nv-asteroids-migration.md](2026-10-04-nv-asteroids-migration.md) | Done | ethereal-samples [0001](../../ethereal-samples/doc/adr/0001-nv-asteroids-on-the-ethereal-dev-object-model.md) |
| [Slang support mega project](2026-10-18-ethereal-nvrhi-slang-support.md) | Approved; implementation in progress | See plan |
| [Depth-map Slang migration](2026-10-18-depth-map-slang-migration.md) | Approved; Windows validation recorded | See plan |
| [Mixed mesh/volume Slang RT](2026-10-18-mixed-scene-slang-rt.md) | Approved; fourth checkpoint | See plan |
| [Unified GVDB volume ownership](2026-10-18-gvdb-unified-volume-ownership.md) | Approved; implementation in progress | See plan |
| [GVDB NVRHI contract](2026-10-18-gvdb-nvrhi-contract-draft.md) | Additive owner/API implemented; adapters in progress | See plan |
| [GVDB host ownership](2026-10-18-gvdb-host-volume-step-b.md) | Implemented CPU slice; validation recorded | See plan |
| [GVDB owner/API and spray checkpoint](2026-10-18-gvdb-volume-owner-api-checkpoint.md) | Windows validation recorded; adapters remain | See plan |
| [GVDB voxel API checkpoint](2026-10-18-gvdb-voxel-api-checkpoint.md) | Initial public operators validated; broader adapters remain | See plan |
| [GVDB transactional VBX checkpoint](2026-10-18-gvdb-vbx-transaction-checkpoint.md) | Exact import/coherent save validated; consumers remain | See plan |
| [GVDB point conversion checkpoint](2026-10-19-gvdb-point-conversion-checkpoint.md) | Raw conversion validated; public point factories remain | See plan |
| [GVDB filters and dense rebuild checkpoint](2026-10-19-gvdb-filters-dense-rebuild-checkpoint.md) | Six filters and transactional replacement validated; append/consumers remain | See plan |
| [GVDB append and owned renderer checkpoint](2026-10-19-gvdb-append-render-checkpoint.md) | Stable-ID accumulation and first owned renderer validated; public points/remaining consumers continue | See plan |
| [GVDB public points, reduction and custom renderer checkpoint](2026-10-19-gvdb-public-points-reduction-custom-checkpoint.md) | Public point/reduction APIs and custom owned rendering validated; remaining adapters continue | See plan |
| [GVDB owned resample checkpoint](2026-10-19-gvdb-owned-resample-checkpoint.md) | Public transformed resampling validated; gather and remaining consumers continue | See plan |
| [GVDB ordinary gather and owned depth-map checkpoint](2026-10-19-gvdb-gather-depth-checkpoint.md) | Gather and depth-map ownership validated; point-fusion integration continues | See plan |
| [GVDB point support, apron overrides and owned surface checkpoint](2026-10-19-gvdb-point-apron-surface-checkpoint.md) | Full Windows matrices validated; point-fusion adoption continues | See plan |
| [GVDB owned point-fusion and snapshot viewer checkpoint](2026-10-19-gvdb-owned-point-fusion-view-checkpoint.md) | Point-fusion and all snapshot viewer modes validated; dense query acceptance continues | See plan |
| [GVDB public regional downsample checkpoint](2026-10-19-gvdb-public-downsample-checkpoint.md) | Both full Windows matrices validated; resample ownership continues | See plan |
| [GVDB resample consumer checkpoint](2026-10-19-gvdb-resample-consumer-checkpoint.md) | Owned resample and full Windows matrices validated; 3d-print ownership continues | See plan |
| [GVDB 3d-print ownership checkpoint](2026-10-19-gvdb-print-ownership-checkpoint.md) | Owned publication/viewing validated; public mesh voxelizer remains | See plan |
| [GVDB public mesh voxelizer checkpoint](2026-10-19-gvdb-public-voxelize-checkpoint.md) | Public two-phase voxelizer and 3d-print validated; remaining point-cloud/gather and platform gates continue | See plan |
| [GVDB owned point-cloud and separate gather evaluation checkpoint](2026-10-19-gvdb-owned-point-cloud-checkpoint.md) | Both full Windows matrices validated; public quantization continues | See plan |
| [GVDB public point quantization](2026-10-19-gvdb-public-point-quantization.md) | Implemented; Windows API/sample/package acceptance recorded | See plan |
| [GVDB inverse-distance gather](2026-10-19-gvdb-inverse-distance-gather.md) | Implemented; full Windows matrices and installed consumers pass | See plan |
| [GVDB interactive owned snapshot](2026-10-19-gvdb-interactive-owned-snapshot.md) | Implemented; focused Windows acceptance and exact captures pass | See plan |
| [GVDB fluid owned snapshot](2026-10-19-gvdb-fluid-owned-snapshot.md) | Implemented; focused Windows acceptance recorded | See plan |
| [GVDB public point deposition](2026-10-19-gvdb-public-point-deposition.md) | Implemented; four APIs, native validation and installed consumers pass | See plan |
| [GVDB spray owned snapshot](2026-10-19-gvdb-spray-owned-snapshot.md) | Implemented; focused Windows, native, memory and production acceptance recorded | See plan |
| [GVDB obstacle-volume mapping](2026-10-19-gvdb-obstacle-mapping.md) | Implemented; four APIs, both native adapters, memory and installed packages pass | See plan |
| [GVDB tricubic surface](2026-10-19-gvdb-tricubic-surface.md) | Implemented; four APIs, both native adapters, memory and production acceptance pass | See plan |
| [OptiX diagnostics](2026-10-19-optix-diagnostics.md) | Implemented; SDK validation, isolated failure, installed packages and full Windows regression pass | See plan |
| [GVDB velocity quantization](2026-10-19-gvdb-velocity-quantization.md) | Implemented; four APIs, both native adapters, memory and installed packages pass | See plan |
