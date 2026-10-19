# Public retained point-to-leaf insertion

Authorized continuation, 2026-10-19.

Replace the retained gvdbInsertPoints/InsertSupportPoints/SortPoints roles through
an additive device-only interface, sharing the already validated subcell attribute
expansion implementation and ticket. Keep existing descriptors and vtables intact.

A new PointInsertion request selects center or velocity-direction support lookup.
Both retain an authenticated snapshot and PointSet. Center lookup uses p+translation;
support lookup uses (p+translation)+velocity*offset with the PointSet's optional
velocity stream as direction. Sorting writes p+translation, not the support point,
and transports all original velocity/color/W payloads exactly. Preserve the legacy
pre-translation z==1e10 no-hit sentinel. Reject nonfinite transformed values.

One cell per source leaf-pool slot exposes stable offset/count, signed origin and
source leaf index. Source ordinals identify every included point exactly once;
per-point leaf/offset are derivable from those ranges. Inactive/missing leaves and
sentinels are excluded. Stable source order replaces raced atomic offsets; fixed
leaf-pool order replaces positional CUDA buffer plumbing. No live topology edits.

Share the existing prepare/record/caller-completion path and GPU gather artifact.
Use checked signed phase-relative host lookup over immutable topology, with count,
work and memory budgets. Validate independent center/support membership, translation,
source attribute association, empty/inactive/signed/shifted cases, sentinel behavior,
exact budgets, retained ownership and malformed inputs. Run four APIs, native
adapters, CUDA memory and installed consumers. Keep broader performance/platform,
legacy visual and source-retirement gates explicit.

## Execution and verification

Implemented `IGVDBPointInsertion` / `createPointInsertion` in the existing subcell
implementation. Existing interfaces/descriptors remain unchanged; explicit
IRHIObject routing keeps canonical IObject identity across both queryable APIs.
An initial ambiguous multiple-base interface table was corrected before testing.
No new shader algorithm or native API dependency: checked two-pass O(N log L)
host association feeds the existing Slang GPU attribute expansion. The insertion
request's velocity stream supplies support direction, and output keeps the
original translated position, never the support lookup position.

Independent brute-force box tests cover signed/offset/inactive/empty topology,
all optional attributes, Float3/4 position and velocity, positive/negative support
offsets, NaN direction rejection with exact center-mode transport, overflowing
support math, exact budgets, retained lifetime and quantizer composition. A
cancelling -1e10 Z translation verifies sentinel rejection occurs before translation.
GPU ranges/locations/ordinals and actual expanded attributes match CPU references.

- Insertion plus existing subcell ABI/four-API acceptance: **10/10**, 5.15 seconds.
- Final affected point/gather/quantization/subcell/grid-query/insertion regression:
  **30/30**, 12.90 seconds, including the final sentinel/overflow cases.
- Six native graphics routes (D3D11/D3D12/Vulkan, NVIDIA/AMD): pass.
- CUDA Compute Sanitizer: zero errors.
- Installed static/shared consumers: **2/2 each**, 1.86/0.50 seconds.
- Graphics-only subcell/insertion acceptance: **8/8**, 3.77 seconds, with CUDA
  discovery disabled during configure/build.

Logs are under `build/m5-point-insertion`. Inventory now records **46 owned-
validated / 14 sample-validated / 20 portable-foundation / 20 partial / 0 pending**.
No positional CUDA ABI or arbitrary atomic scheduling compatibility is claimed.
Marking/split and remaining legacy export/consumer roles, Linux, supported native
multi-GPU and broad visual/performance gates remain open. No source retirement.
