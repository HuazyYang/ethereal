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
