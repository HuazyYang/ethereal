# Public packed velocity quantization

Authorized continuation, 2026-10-19.

The retained gvdbInsertSubcell_fp16 stores normalized unsigned ushort3 velocity
alongside positions; it is not IEEE half. Its host bounds are velocity extrema
without position padding, replacing a constant-axis zero range with one. The
current public quantizer only changes positions and preserves velocity bytes.

Add an ABI-preserving velocity factory using the same generic Slang encode/decode
artifacts and ticket lifecycle. Add an explicit attribute-extrema bounds mode;
keep the existing position factory and descriptors unchanged. Velocity mode
requires an authenticated velocity stream and finite XYZ values, retains the
original component count and W payload, preserves position bounds/bytes and color,
and exposes packed six-byte codes plus an authenticated GPU-decoded PointSet.

Reuse the trusted private point-clone seam for the selected attribute; never
reupload a CPU substitute. Account for decoded velocity storage and copied other
attributes in budgets. Test explicit/extrema bounds, signed and constant axes,
odd counts, Float3/Float4, absent/nonfinite velocity, exact unaffected attributes,
factory identity, ownership, installed exports and four-API native/memory checks.
This supplies the encoding primitive; public subcell storage/orchestration is a
separate follow-up, so the normalized-ushort inventory group remains partial.

## Execution record and verification

The additive `gvdbCreateNvrhiVelocityQuantize` factory reuses the existing raw
Slang encode/decode programs. The private trusted float-attribute clone preserves
position metadata and auxiliary GPU ownership. Existing position behavior and
all descriptor/vtable layouts remain unchanged. AttributeExtrema is velocity-only;
LegacyPadded is position-only. Missing velocity, including optional attributes
absent from empty uploaded sets, is rejected with FE_NOT_FOUND. Nonfinite XYZ is
rejected before GPU recording. Arbitrary Float4 W payloads remain exact.

Initial tests incorrectly expected an empty upload to retain optional velocity;
the test was corrected to honor the existing PointSet contract. A decoded-value
comparison also used relative-to-result tolerance at a cancellation to zero.
D3D decoded code65535 with minimum -257/range257 to approximately -1.53e-5 due to
binary32 reciprocal lowering. The independent actual-code reference now bounds
forward operation error using minimum/range scales; the one-code-interval bound
is unchanged. No CPU substitute or shader-result rounding was introduced.

- API/ABI four-backend acceptance: **5/5**, 4.02 seconds.
- Expanded point/gather/point-cloud regressions: **38/38**, 37.70 seconds.
- All six native D3D11/D3D12/Vulkan adapter combinations pass with no validation
  warnings/errors. PowerShell wraps Vulkan's informational stderr as a native
  error record; the program's severity counter and exit status both pass.
- CUDA Compute Sanitizer: **zero errors**.
- Installed static/shared GVDB consumers, both using the shared NVRHI SDK:
  **2/2 each**, including chained position then velocity GPU quantization.
- Graphics-only build with CUDA discovery disabled: **4/4**, 1.74 seconds.

Logs are under `build/m5-velocity-quantize`. The last full Windows matrix remains
360/360 from the immediately preceding OptiX checkpoint; this slice ran the
38 affected cases above. Inventory counts remain 36/14/27/23/0, with normalized
ushort partial until public expanded subcell storage is implemented. No retained
sources are retired; broader platform/performance gates remain open.
