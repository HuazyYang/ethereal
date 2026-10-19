# Spray ownership and retained-snapshot rendering

Authorized implementation continuation, 2026-10-19.

Replace production SprayVolume helper GPU ownership with a public volume owner and
retained snapshot. Preserve accumulated density gathering (radius/support1,
subcell4), per-frame scalar/color apron refresh, and center-weight4 smoothing
on every twentieth frame. The new polynomial deposition operator is a distinct
legacy role and must not change spray's established gather behavior.

Use the public two-phase mesh voxelizer, host region activation and dense resample
for the metal asset. Canonical PointSets retain hit/color ordinal correspondence;
legacy nonfinite input rays/point sentinels remain skipped at the sample boundary.
CPU readbacks/classification remain explicit. No shadow SlangVolume or SlangAtlas
may own production volume channels.

Adapt arbitrary-ray query and all five custom display modes to raw snapshot buffer
ranges without copying channels into structured aliases. Validate device, format,
metadata and buffer ranges. Keep original shared traversal equations and the
legacy structured query helper for reference tests. Expose public-host topology
for overlays; diagnostic topology/channel readbacks must not become authority.

Acceptance: independent scalar/color/apron/query/shading/cadence fixtures, retained
snapshot lifetime and invalid-input checks, all existing spray application/input/
window tests, both graphics adapters, CUDA memcheck, graphics-only and production
builds without CUDA toolkit discovery. Compare the 20 captured pre-migration
128x96 three-frame images in build/m5-spray-owned/reference. Record any numerical
or visual changes precisely. Broader project/platform gates remain open.

## Execution record

Implemented public owner publication, two-phase mesh voxelization, host sparse
activation, dense resampling, canonical point preparation, ordinary density/color
gather, aprons and smoothing. Production no longer stores SlangVolume/SlangAtlas
channels. Readbacks remain explicit at the application boundary. Snapshot query
and custom renderer share the original traversal equations using raw buffer views;
the structured query path remains an independent test reference.

Initial root-only fixtures failed D3D11/D3D12 validation and CUDA execution because
a child SRV was null. Query and render now bind an unused two-word missing-child
buffer for this topology. No public owner contract changed. A signed diagnostic
loop warning was corrected. No deviations from the intended ownership scope.

## Verification

Evidence directory: `build/m5-spray-owned`.

- Final rebuild and affected suite: 19/19, 19.18 seconds (`final-tests.log`).
- Existing affected suite: 19/19 (`tests.log`, `tests.xml`). Expanded analytic and
  control suite: 8/8 (`extended-tests.log`), including gradient-based raw offsets,
  retained snapshot lifetime, eight malformed-view cases and failure atomicity.
- Six explicit D3D11/D3D12/Vulkan ? NVIDIA/AMD runs pass native validation
  (`native-*.log`). CUDA analytic/asset memcheck reports zero errors (`memcheck.log`).
- Graphics-only build with CUDA discovery disabled: 15/15 (`graphics-tests.log`).
- Tests-disabled, CUDA-discovery-disabled production: AMD D3D12 native validation
  passes with 651 bricks, 1,000 final hits and 2,744 image hits (`production-run.log`).
- Twenty three-frame 128x96 images: modes 0?3 byte-identical to captured pre-change
  portable references. Mode 4 maximum channel difference 1, changed pixels:
  CUDA177, D3D11 180, D3D12 177, Vulkan179 (`image-comparison.json`). Cause not
  isolated; no claim of exact legacy-image parity.

## Follow-ups

The exact exported legacy ray-buffer contract remains distinct from this sample
snapshot helper. Obstacle-volume subcell mapping, tricubic surface rendering and
OptiX exception diagnostics still need explicit replacement/disposition. Packed
velocity and other partial roles, Linux, supported native multi-GPU routes,
broader visual/performance gates and reference retirement remain open. No
reference retirement is authorized by this checkpoint.
