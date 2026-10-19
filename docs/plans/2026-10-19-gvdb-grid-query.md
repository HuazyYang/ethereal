# Retained scalar-grid queries and velocity diagnostics

Authorized continuation, 2026-10-19.

The retained gvdbReadGridVel is a scalar point lookup of channel3, returning zero
outside topology; it is not the existing three-component MAC/PIC-FLIP utility.
gvdbCheckVal compares an eight-tap Y-face interpolation and a raw surface read.
Its output boundary uses > rather than >=, leaves misses uninitialized, and can
form unaligned byte addresses from half-voxel coordinates. Do not reproduce those
undefined buffer accesses or imply a complete FLIP solver.

Implement an additive public device-only query over an authenticated retained
snapshot, selected R32 channel and canonical PointSet. ScalarVoxel mode returns
the point voxel value and validity. MacYDiagnostic mode returns a safe Y-face
trilinear value and aligned point comparison, with validity and deterministic
zero misses. Use the selected leaf's stored atlas/apron bytes with explicit zero
border; signed floor addressing replaces truncation artifacts. Document the raw
unaligned legacy comparison as a repaired diagnostic, not byte-for-byte recovery.
Coordinates are in the owned volume's unit voxel grid; integer input to the point
factory covers the legacy scalar-query use case. No owner publication is needed.

Prepare retains inputs and validates channel/descriptor/budgets; record emits
Slang raw-buffer sampling and copies output to readback; caller submits/waits and
finishes once. Expose a borrowed GPU result and immutable CPU Float4 tuples,
without adding native API types or changing existing interfaces. Test independent
scalar and MAC references, signed roots, constant/linear/nonlinear data, stored
aprons and border, inactive/missing leaves, retained ownership, exact budgets,
malformed inputs, four APIs, native adapters, memory and installed consumers.

## Execution record and verification

Implemented additive `GVDBNvrhiGridQueryApi` and `GVDBGridQuery.slang` with strict
artifact reflection, retained snapshot/PointSet authentication and checked result
budgets. Output Float4 is (value, comparison, active-leaf validity, zero). Scalar
comparison is zero; diagnostic comparison reads the aligned lower corner. Integer
lookup precedes local fractional decomposition, avoiding unsafe float-to-int casts
and signed subtraction overflow. No existing interface/vtable changes.

The independent test scans explicit leaf boxes and evaluates scalar/eight-tap
sampling in double precision from the published input atlas bytes. Publication
spatially regenerates aprons, so the oracle reads that immutable input rather
than incorrectly treating full upload bytes as unchanged apron data. Tests cover
Float3/4, 0/1/258/513 points, negative/root/deep/inactive/empty cases, apron0/1/2,
constant/linear/nonlinear/IEEE data, channel31, extreme miss coordinates, near-limit
origins, exact budgets, foreign devices, lifetimes and malformed artifacts.

D3D12 optimized a nonfinite weighted sum differently: one expected negative
infinity became NaN. Explicit bit classification handles NaN, zero-weight infinity
and opposite infinities before finite interpolation, and all four APIs now match
the independent oracle. An attempted `precise` loop exposed undefined generated
CUDA temporaries in the installed Slang compiler; the final portable algorithm
does not need it. An initial large-origin fixture exceeded the existing owner's
exact voxel-center domain and was corrected to stay within its documented limit;
that owner limit was not relaxed. Initial test enum/build-environment mistakes
were corrected before acceptance.

- Public ABI/four-API acceptance: **5/5**, 2.65 seconds.
- Affected point/quantization/obstacle/subcell/query regression: **25/25**, 11.86 seconds.
- Native D3D11/D3D12/Vulkan on NVIDIA and AMD: all six routes pass.
- CUDA Compute Sanitizer: zero errors.
- Installed static/shared consumers: **2/2 each**, 1.92/0.45 seconds.
- Graphics-only configure/build with CUDA discovery disabled and query acceptance:
  **4/4**, 2.91 seconds.

Logs are under `build/m5-grid-query`. Last full matrices remain the preceding
subcell checkpoint (365/365 Windows, 274/274 graphics-only); this additive slice
ran the affected tests above. Inventory is **43 owned-validated / 14 sample-
validated / 23 portable-foundation / 20 partial / 0 pending**. Exact unsafe legacy
byte reads are deliberately not compatibility promises. Remaining public point
association/split/marking roles, broad consumer/platform/visual/performance and
retained reference gates remain open. No source retirement is authorized.
