# Retained tricubic surface rendering

Authorized continuation, 2026-10-19.

Implement the retained getTricubic equations explicitly: 27 integer-position
linear atlas fetches, tensor weights (1-t)^2, 2t(1-t), t^2 with
 t=frac(localPosition)*0.5+0.25. Do not substitute Catmull-Rom or the current
trilinear sampler. Preserve atlas-wide clamp addressing and stored apron bytes;
insufficient apron can therefore expose neighboring packed slots, as in the
retained linear-texture implementation. Document this layout-sensitive behavior.

Render density surfaces with hierarchy-biased leaf entry, direct marching step,
fine-step scalar correction, negative +/-0.5 tricubic gradient, optional packed
point color and legacy ambient/diffuse shading. Shadows remain trilinear. Use
geometric leaf DDA and explicit exhaustion status as in the portable ray query.
Guard zero refinement denominator and zero/nonfinite gradient rather than
reproducing undefined/NaN legacy outputs. Bind retained raw snapshots and expose
an explicit --tricubic option in render-to-file; existing modes remain intact.

Validate interpolation against independent tensor-product CPU references,
nonlinear fields that distinguish trilinear interpolation, signed/offset/root
publications, boundary clamp/apron behavior, surface/refinement/normal/shadow
fixtures, exhaustion and malformed inputs. Run all four APIs, both native
adapters, CUDA memory checks, real assets and tests-disabled production. Legacy
visual acceptance remains explicit rather than implied by cross-backend parity.

## Contract clarification during implementation

The GP sampler defaults to linear/clamp, but the retained VBX loader explicitly
selects zero border on all axes (`GVDBSerializer.cpp`). The renderer therefore
supports both, defaulting to zero border for the VBX application. The initial
plan's clamp-only wording is superseded by this source-backed distinction. Both
addressing modes need independent scalar/gradient boundary fixtures. Color uses
actual normalized RGBA8 bytes, consistent with the other portable sample paths.

Refinement is restricted to a finite bracket and fineStep <= 1,000,000. An
unbracketed or degenerate crossing keeps the first accepted sample; gradients
with squared magnitude <= 1e-12 use the opposite ray direction. These deliberately
replace legacy extrapolation/NaN behavior and stabilize constant fields.

The literal 27x8 expansion compiled but caused multi-minute FXC optimization
with border handling. Replacing early returns with selection did not resolve
that cost. The production sampler now combines overlapping weights into an
algebraically equivalent 64-tap stencil in a loop. The CPU reference independently
retains the original 27 linear samples in double precision; numerical comparisons
allow floating-point rounding differences. Interrupted compiler attempts were
restricted to verified project ShaderTool processes; no unrelated process stopped.

## Execution record and verification

The production `OwnedVolumeTricubic` helper consumes retained raw snapshots and
is available through render-to-file `--tricubic` with tests disabled. Analytic
fixtures compare scalar and gradient values against the independent original
27-fetch double-precision reference, including signed origins, apron and border
cases. They cover refinement, clipping, flat normals, color, shadows, sparse
leaf traversal, exhaustion, empty snapshots and malformed arguments.

- Four-API analytic and real-asset tests: **8/8**, 4.56 seconds.
- Analytic and 128x96 explosion renders pass native validation on RTX 4050 and
  Radeon 780M across D3D11, D3D12 and Vulkan (six combinations each).
- CUDA analytic and asset Compute Sanitizer runs: **zero errors** each.
- CUDA/NVIDIA D3D11/Vulkan images are identical. NVIDIA D3D12 and all AMD images
  differ from CUDA in one pixel, by at most one channel byte. Comparison data is
  `build/m5-tricubic/cross-api-images.json`.
- Tests-disabled graphics production, with CUDA toolkit discovery disabled,
  renders the 10,284-leaf explosion on AMD D3D12: 1,670 non-background pixels;
  the image matches the same-adapter development image exactly. One observed
  render/readback took 16.538 ms; this is not a performance acceptance benchmark.
- Complete graphics-only regression: **270/270**, 176.20 seconds, without skips.

Logs and captures are under `build/m5-tricubic`. Inventory now records 36
owned-validated, 13 sample-validated, 27 portable-foundation, 23 partial and one
pending role (OptiX exception disposition). Legacy visual equivalence, broader
performance, Linux and supported native multi-GPU gates remain open. No retained
sources are retired.

Complete Windows regression before the following OptiX diagnostic changes passes
**357/357**, 199.85 seconds, without skips (`full-tests.log`/`.xml`).
