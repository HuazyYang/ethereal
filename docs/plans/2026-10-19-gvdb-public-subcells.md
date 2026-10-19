# Public retained-snapshot subcell storage

Authorized continuation, 2026-10-19.

Expose the existing stable support-bin algorithm through a device-only public
operator retaining an authenticated snapshot and PointSet. Share bin construction
with owned gathering rather than create a second association rule. Use inclusive
support [translatedPosition-radius, translatedPosition+1+radius], signed floor
coordinates and active snapshot leaves. Cell order is source leaf-pool index then
local z/y/x (x fastest); inactive slots remain empty. Point order within a cell
is stable input ordinal instead of legacy atomic scheduling. No topology mutation
or implicit submission is permitted.

Prepare checked host cell ranges and original point indices under cell, candidate,
pair, host-byte and GPU-byte budgets. Record a Slang raw-buffer gather that expands
position, optional velocity and color into canonical streams in that exact order.
Caller completion returns an authenticated PointSet built from actual GPU results,
with translated finite XYZ bounds, original component counts/W payloads and exact
velocity/color association. Retain CPU/GPU cell ranges and source ordinals for
consumer queries. Compose the position/velocity quantization factories on the
expanded output for six-byte ushort3 storage; quantization never changes bin
association. This replaces both float and normalized-ushort subcell attribute
transport without a special native CUDA interface.

Test against an independent brute-force cell/point reference: signed and offset
roots, inactive slots, support boundaries and translation, duplicate points,
stable ordinals, all optional attributes, Float3/Float4, no matches/empty sets,
retained ownership after release, exact budgets and failure outputs. Compose both
quantizers and check packed association. Run four APIs, both native graphics
adapters, CUDA memory and installed static/shared consumers. Keep broad platform,
performance and legacy visual gates explicit.

## Implementation decisions

The ticket additionally exposes signed cell origins and source leaf IDs on CPU
and GPU. Inactive locations are zero/UINT32_MAX, so active empty cells remain
distinguishable. This completes the retained gvdbCalcSubcellPos/SetFlag roles;
active roots and signed coordinates are supported deliberately. Fixed source
leaf-pool ordering replaces arbitrary sc_mapping permutations, with exact source
IDs exposed to callers. Stable ordinals replace raced atomic insertion order.

Metadata storage is 24 bytes per cell (8-byte offset/count plus 16-byte location).
For P pairs and total canonical attribute stride S, logical retained host bytes
are 24*C+P*(4+S); nonempty GPU bytes are 24*C+256+4*P+2*P*S+4*A for A absent optional
attributes, in 7+K buffers for K present attributes. Zero pairs need only the two
metadata buffers, or none when C=0. Existing inputs and transient topology/hash
storage are excluded explicitly.

The first transport assertion compared against pre-conversion upload arrays.
Identity affine conversion can alter signed-zero/NaN representation; the fixture
now compares exact bytes with the authenticated canonical PointSet, as required
by this operator's contract. No production result was changed for that fixture.
CPU references independently enumerate cells and points, and check locations,
stable ordinals, translated bounds, actual GPU attributes and composed ushort3
codes. Widths 1/2/4, signed root offset, inactive holes and nonempty no-match sets
are covered. Initial missing test-reader compilation was corrected before testing.

## Verification and remaining gates

- Final public ABI/four-API tests: **5/5**, 3.19 seconds.
- Full Windows regression: **365/365**, 211.39 seconds, no skips.
- Full graphics-only regression with CUDA discovery disabled: **274/274**,
  160.00 seconds, no skips.
- Native D3D11/D3D12/Vulkan validation on NVIDIA and AMD passes all six routes.
- CUDA Compute Sanitizer reports zero errors.
- Final installed static/shared public consumers pass **2/2 each**, 0.37/0.38
  seconds, including cell locations and retained expanded attributes.

Logs are under `build/m5-public-subcells`. The four subcell roles and normalized
ushort transport role now have public Windows acceptance: inventory is **41
owned-validated / 14 sample-validated / 23 portable-foundation / 22 partial /
0 pending**. These are implementation roles, not completion percentages. Broader
consumer migration, Linux, supported native multi-GPU, visual/performance and
retained reference gates remain open. Scalar-grid query/velocity diagnostics are
the next slice. No reference retirement is authorized.
