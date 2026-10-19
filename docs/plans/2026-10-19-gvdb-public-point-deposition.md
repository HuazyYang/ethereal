# Public deterministic point deposition

Status: authorized implementation continuation, 2026-10-19.

## Retained equations and corrected scheduling

Implement the three pending roles `gvdbScatterPointDensity`,
`gvdbScatterPointAvgCol`, and `gvdbAddSupportVoxel` through a public owner-bound
factory. Consume authenticated canonical PointSets and publish ordinary generation
tickets; no topology growth, implicit submission/wait or external GPU adoption.

Density adds `1+c*(-3+c*(3-c))`, with `c=distanceSquared/(radius*radius)`, at the
truncated local voxel and optionally its six axis neighbors. The polynomial is
not clamped outside radius. Preserve physical same-brick apron destinations;
expansion does not redirect contributions into adjacent leaf interiors. Color
updates only central voxels: explicit last-input-ordinal RGBA or exact integer
RGB average with alpha255. Average ignores previous color. The unused legacy
amplitude argument is omitted. Stable per-destination lists replace raced scalar
read/modify/write and nondeterministic direct color writes.

Support mode finds the leaf from position+translation first, then offsets by the
PointSet velocity XYZ interpreted as direction times `directionOffset`. It retains
that original leaf, truncates local shifted coordinates, rejects shifted integer
voxels outside the original interior, and updates a 3x3 XZ stencil plus R8 material
value1. This preserves the old fractional negative-local truncation behavior.
Direction W is ignored; all used XYZ operations must remain finite. Require apron
at least1 for expanding modes, positive bounded radius, valid distinct formats/
channels, and explicit point/contribution/allocation budgets.

CPU preparation builds stable CSR association lists with checked bounds and
float operation order. Slang performs polynomial sums and color/material writes.
Dispatch one thread per four voxels so R8 writes own complete words and need no
raced byte updates. Untouched active voxels/aprons keep exact prior bits; unused
slots and tail padding become zero. No implicit apron refresh occurs.

## Verification

Use independently enumerated destinations/equations for central/six-neighbor/XZ
support, original-leaf association, signed/transformed points, duplicate points,
color last/average, inactive/unused slots, apron edges, word-owned R8 writes, empty input,
budgets, invalid fields/foreign objects, stale tickets and retained snapshots.
Run four APIs, both graphics adapters, CUDA memcheck and installed static/shared
consumers. Keep reference kernels and external platform/performance gates open.

## Execution record

Implemented `IGVDBDeposit`, its separate C factory and production Slang entry with
strict offline reflection checks. CUDA uses explicit rounded intrinsics for the
association arithmetic; graphics targets retain precise separate operations.
Disabled optional UAVs receive distinct dummy buffers for D3D11 compatibility.
Host budgeting includes retained upload staging as well as association arrays.

Windows acceptance in `build/m5-point-deposit`:

- ABI plus D3D11/D3D12/Vulkan/CUDA: **5/5**, 3.00 seconds after exact-budget and
  root-only tests. Fourteen nonempty/empty mode fixtures per API, a translated
  narrow-radius case, and root-only/empty-owner checks pass.
- Native debug validation: all six explicit graphics API/adapter combinations
  pass on RTX4050 Laptop and Radeon780M. CUDA memcheck reports **0 errors**.
- Graphics-only build with CUDA toolkit discovery disabled: **4/4**, 3.16 seconds.
- Installed static GVDB API and shared GVDB API consumers: **2/2 each**. Both use
  the shared NVRHI SDK and disable CUDA toolkit discovery. Consumer tests check
  central/axis/XZ scalar values, exact color/material and released factory lifetime.

Initial fixture failures were test defects: snapshot facade identity is not a
publication identity, and an empty optional color stream had an out-of-bounds
source offset. Tests now compare resource/revision identity and omit empty color
streams. Public atlas brick dimensions are even, so an odd logical R8 tail is not
constructible through this API; word ownership is tested, without claiming an
unreachable odd-tail fixture. The kernel still bounds lanes and zeros any tail.

The 100-entry inventory is now 35 owned-validated / 12 sample-validated /
27 portable-foundation / 23 partial / 3 pending. This completes these three
operator roles locally; remaining consumers, kernel roles and external platform,
performance and legacy visual acceptance gates stay open. Reference retirement
remains unauthorized. Continue with spray ownership and retained-snapshot queries.
