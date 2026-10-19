# Public point coordinate splitting

Authorized continuation, 2026-10-19.

Replace gvdbSplitPos with an additive device-only API over an authenticated
canonical PointSet. Select position or velocity XYZ and finite translation, retain
source order, and expose separate raw X/Y/Z buffer ranges plus immutable CPU axis
bytes after caller completion. Use one planar GPU allocation and one readback;
no hidden submission/wait. Keep existing interfaces/descriptors intact.

Compute exact min/max from actual completed GPU values. Empty results have zero
bounds and no allocations. Reject missing velocity and nonfinite selected/transformed
XYZ during prepare; preserve optional W/color because the source is immutable.
Legacy padded/clamped position bounds and constant velocity range policy remain
in their existing quantization factories, not this exact splitting query.

Validate independent plane layout, translation and extrema for Float3/Float4,
position/velocity, signed values, 0/1/tail counts, source/operator release, exact
budgets, invalid attributes/axis indices and artifact contracts. Test four APIs,
both native graphics adapters, CUDA memory and installed static/shared consumers.
Keep platform/performance and source-retirement acceptance explicit.

## Execution and verification

Implemented `GVDBNvrhiPointSplitApi` and the `splitPointCoordinates` Slang entry.
One raw allocation contains X then Y then Z; borrowed ranges honor axis*N*4 offsets.
The ticket retains authenticated source/pipeline state and produces CPU planes
and exact bounds from actual GPU readback. Zero translation preserves raw source
bits. Existing interfaces/vtables are unchanged, and there are no native SDK types
in the public API. Initial fixture creation omitted required topology configuration;
the fixture was corrected before acceptance.

Independent references check translated canonical XYZ planes/extrema for Float3/4,
position and velocity, 0/1/259 counts, constant/signed axes, nonfinite unused W,
missing/nonfinite velocity, finite translation overflow, exact budgets, early/invalid
axis outputs, one-use completion, source/operator release, artifact metadata and
actual GPU/CPU coherence. Source nonfinite velocity remains usable when splitting
only position. Installed consumers exercise both attributes after source release.

- Public ABI/four-API acceptance: **5/5**, 3.28 seconds.
- Final affected point/quantization/subcell/insertion/split regression: **25/25**,
  9.88 seconds.
- Six native graphics routes (NVIDIA/AMD D3D11/D3D12/Vulkan): pass.
- CUDA Compute Sanitizer: zero errors.
- Installed static/shared consumers: **2/2 each**, 1.99/0.45 seconds.
- Graphics-only query acceptance: **4/4**, 1.52 seconds, CUDA discovery disabled.

Logs are under `build/m5-point-split`. Inventory is **47 owned-validated / 14
sample-validated / 19 portable-foundation / 20 partial / 0 pending**. Leaf-marker
workflow and remaining exported rendering/consumer contracts continue. Linux,
supported native multi-GPU, broad visual/performance and reference-retirement
gates remain open. No reference source is removed.
