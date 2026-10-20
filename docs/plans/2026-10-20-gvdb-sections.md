# Retained section and compositing contracts

Status: focused Windows acceptance complete; broader project gates remain.

`OwnedVolumeSections` renders immutable R32 snapshots with optional RGBA8 color.
The 2D contract uses integer pixel XZ coordinates and composites the transfer value
over black. The 3D contract samples a forward section plane and blends it over the
surface beyond the plane. Both use the retained 16,384-entry transfer table and
`trunc(saturate((value-isovalue)/(maximum-minimum))*16300)` indexing, with opaque
RGBA8-precision output. Parallel/behind-camera planes start tracing at the camera;
this repairs the retained positive-NOHIT plane sentinel. Traversal exhaustion is
reported separately from misses. Empty publications render defined backgrounds.

Spray now calls the shared 3D renderer. Removing its omitted transfer threshold
changes 32 of 12,288 pixels (maximum channel difference 85) in the three-frame
128x96 section capture. The resulting captures match byte-for-byte across all four
APIs. This is a documented correction, not exact agreement with the previous path.

`compositeOverRGBA8` accepts checked structured-uint ranges and produces a fresh
GPU buffer with no hidden wait. Read-only input aliasing is supported. Each channel
uses `min(255, (source*255 + destination*(255-sourceAlpha))/255)` with integer
division. All 16,777,216 source/destination/alpha triples pass exact comparison on
each API. The retained CUDA PTX's approximate division/FMA differs in 253,281 pixels
and 503,719 channel bytes, with maximum difference 1 and mean absolute channel
difference 0.007506. Integer arithmetic intentionally removes backend rounding
variation. `CompareLegacyComposite.py` reproduces this optional reference check
using the CUDA Driver API and NumPy; it is not a production dependency.

Validation:

- Affected Windows section/spray tests: 23/23; final section fixture: 4/4.
- Graphics-only section/spray tests: 18/18.
- Native D3D11/D3D12/Vulkan validation: both NVIDIA and AMD adapters, 6/6.
- CUDA Compute Sanitizer: zero errors.
- Analytic section tests cover threshold indexing, color, signed sparse misses,
  empty snapshots, no-hit/behind/parallel planes, limits and rejected controls.
- Compositor tests cover exact exhaustive bytes, offsets, guards, overlapping
  inputs, empty input and invalid alignment.

Local evidence is under `build/m5-sections`. This sample utility adds no public
installed ABI. Broad legacy scene comparisons, multi-volume composition adoption,
individual rendering modes, performance and Linux remain open. The inventory's
section/compositing group remains partial until those consumer gates close.
