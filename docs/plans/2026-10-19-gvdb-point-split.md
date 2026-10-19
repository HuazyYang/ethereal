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
