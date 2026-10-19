# Public obstacle-volume subcell mapping

Authorized continuation, 2026-10-19.

Replace gvdbMapExtraGVDB with a device operator consuming two authenticated,
retained snapshots. For each active source leaf, find the active obstacle leaf
containing the source leaf origin, using signed half-open bounds. Repeat that
obstacle leaf pool index for every subcell of the source brick. Missing obstacle
leaves, inactive source leaves and unmapped output slots yield UINT32_MAX.

Support identity source-pool ordering and a copied unique source-leaf-to-output
slot map, with UINT32_MAX exclusions. Subcell width is a power of two dividing the
source leaf width. Output contains contiguous X-fast subcells per output brick;
all entries in one brick have the same ID, as in the retained helper. No position
transform, overlap test or per-subcell geometric lookup is implied.

Preserve NVRHI recording/submission ownership: prepare validates/allocates, record
uses the caller's open list, finish requires caller completion. Keep both old
snapshots alive independently of owners; no volume publication or CPU topology
mutation occurs. Reject foreign facade objects and mismatched devices. Provide
explicit GPU output and immutable completed CPU values with checked budgets.

Repair legacy root-only/outside/negative/upper-face bugs with checked traversal;
do not preserve undefined accesses. Acceptance covers independent geometric
leaf-box references, signed/deep/root-only/empty/inactive topologies, different
leaf widths, permutations/holes, retained lifetimes, invalid inputs, exact budgets,
artifact contract rejection, four APIs, native adapters, CUDA memcheck and package
consumers. Reference retirement and broader platform gates remain separate.

## Execution record and verification

Implemented additive `IGVDBObstacle`/ticket and separate C factory, production
Slang shader, strict artifact ABI validation, installed module/docs and public
consumer tests. Both GPU and completed CPU results are explicit. Empty output
allocates no GPU buffers; six-buffer budgets include valid fallback topology
bindings. No old interface was changed and no reference removed.

Evidence: `build/m5-obstacle`.

- ABI + four backend tests: **5/5**, 3.51 seconds (`tests.log`). Independent box
  references cover signed six-level trees, root-only/outside faces, inactive and
  empty volumes, distinct leaf widths, copied permutations/exclusions/holes,
  exact budgets, GPU/CPU equality, retained lifetime and failed-input atomicity.
  Separate device instances verify rejection of foreign source/obstacle snapshots
  and command contexts. Malformed artifacts are rejected before dispatch.
- All six explicit NVIDIA/AMD graphics API combinations pass native validation
  (`native-*.log`). CUDA memcheck reports **0 errors** (`memcheck.log`).
- CUDA-discovery-disabled graphics build: **4/4**, 2.81 seconds.
- Installed static/shared GVDB consumers: **2/2 each** (1.87/0.89 seconds), using
  the shared NVRHI SDK without CUDA toolkit discovery. Copied slot ownership,
  signed root, hole values and released owner/operator lifetime are exercised.

Initial failures were fixture/build-driver defects: a narrowing NodeId conversion,
a dynamically grown fixture exceeding its configured root extent, and locale
mishandling of a BOM in the temporary package driver. They were corrected with
an explicit checked-domain index conversion, an enclosing signed test root, and
UTF-8-sig input decoding. No production algorithm correction was required by
these failures. Output semantics deliberately repair the old skipped root-only
source and unchecked obstacle bounds; those are documented deviations from
undefined legacy behavior.

Inventory is 36 owned-validated / 12 sample-validated / 27 portable-foundation /
23 partial / 2 pending. Tricubic rendering and OptiX exception disposition remain
pending, alongside partial-role, platform, visual/performance and reference gates.

Post-checkpoint complete Windows regression: **349/349**, 211.71 seconds, no skips
(`build/m5-obstacle/full-tests.log` and `full-tests.xml`). This includes the spray
ownership migration and precedes the new tricubic renderer.
