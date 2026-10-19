# OptiX diagnostic disposition

Authorized continuation, 2026-10-19.

The retained GVDB exception program prints the device exception and launch
coordinates, then paints the affected output pixel opaque black. The unified
ray-tracing API has no exception shader stage. Treat backend failures as host
errors and failed completion instead of presenting a black pixel as a successful
render. Keep the retained program until broader reference-retirement gates pass.

Add a separate CUDA device factory enabling OptiX SDK context validation. Keep
DeviceDesc layout, the existing factory and all unified shader/pipeline interfaces
unchanged. The validation factory requires OptiX enabled and fails explicitly if
OptiX is unavailable. Forward SDK diagnostics with tag and severity through the
existing IMessageCallback. Wire sample --validation to this opt-in path for CUDA
ray tracing and supply a callback for ordinary CUDA errors as well.

Validate descriptor errors before driver initialization, exercise normal local
SBT/clone rays with SDK validation, and use an isolated process to provoke trace
depth overflow and verify diagnostics/failed completion. Fatal CUDA contexts must
not be reused. Test installed exports and affected samples; record any SDK-dependent
behavior precisely. The SDK 9 optix_types.h recommends context validation for
stack/trace-depth debugging; user exception flags are for application control flow.

## Execution record and verification

Implemented in NVRHI `c17545a` and samples `fcfe14f`. The original DeviceDesc and
unified interfaces are unchanged. SDK validation is enabled by the separate
factory; tagged callback severity is preserved. The sample CUDA helper now
supplies a callback and honors --validation for RT.

- Focused factory, local RT, validated RT, isolated fault and header/ABI tests:
  **6/6**, 5.81 seconds; expanded CUDA/header/ABI suite **12/12**, 9.76 seconds.
- Static and shared standalone CUDA suites: **9/9 each**, 6.77 and 5.39 seconds.
- Installed consumers: static **2/2**, shared **1/1**. Both resolve the new export;
  the static consumer additionally runs the artifact contract test.
- OptiX-disabled factory contract: **1/1**; validation returns unsupported without
  initializing the driver, while malformed descriptors still return invalid args.
- Interactive analytic/asset and fluid analytic samples pass with CUDA SDK
  validation; successful local SBT/clone validation has **zero memcheck errors**.
- Full Windows regression: **360/360**, 201.12 seconds, without skips.

The isolated negative test observed TRACE_DEPTH_EXCEEDED with launch index
[0,0,0] and four further occurrences, OPTIX_ERROR_VALIDATION_FAILURE, zero
submission and failed completion. It exits without destructing or reusing the
faulted context. Message wording is not made part of the public ABI. SDK 9
provides its internal diagnostic exception program in validation mode; no
application exception stage or per-pixel recovery is added.

Logs are under `build/m5-optix-diagnostics`. The earlier graphics-only matrix
remains 270/270; this slice changes the CUDA-specific sample branch. Inventory
now has 36 owned-validated, 14 sample-validated, 27 portable-foundation, 23 partial
and zero pending roles. This is an inventory disposition, not project completion.
Packed velocity/subcell ownership, remaining exact legacy exports and visual/
performance/platform gates remain. No retained source is retired.
