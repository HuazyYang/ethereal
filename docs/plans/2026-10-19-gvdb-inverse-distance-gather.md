# Public inverse-distance level-set gathering

Status: implemented and validated on Windows, 2026-10-19.

## Contract

The retained `gvdbGatherLevelSet_fp16` computes the ordinary minimum of distance
minus radius (fresh scalar 3), but sums normalized RGBA divided by distance,
without dividing by total weights or point count. Its color conversion is
undefined for zero distance and nonfinite/out-of-range integers.

Add a separate `createInverseDistanceGather` factory returning the existing
queryable gather interfaces and using the new offline
`gatherOwnedAtlasInverseDistance` entry. Keep original interfaces, layouts,
factory and ordinary shader entry unchanged. A weighted factory accepts only
fresh LevelSet requests (`accumulate=0`). Existing support, original/evaluated
association, budgets, snapshots, apron preservation and publication contracts apply.
It accepts already decoded public PointSets, composing with public quantization.

Defined color policy: start at RGBA zero; sum each normalized color component
by distance, with no epsilon or weight normalization. Saturate each component
to [0,1] before RGBA8 truncation. At a computed zero distance, a nonzero input
component contributes saturation and a zero component contributes zero. This
corrects undefined legacy behavior and does not claim compatibility with those
casts. Positive contributions permit saturation during summation without changing
the real-arithmetic result. Scalar and empty-cell policies remain unchanged.

## Implementation and acceptance

A distinct entry prevents old ordinary artifacts from silently implementing the
wrong equation. Reuse authenticated source bindings and stable binning; no private
GPU data is adopted and no implicit conversion/submission/readback is added.
Test independent double-distance/color references, actual decoded quantized
positions, zero/near-zero distances, saturation, transparent/zero lanes, signed
coordinates, separate association, empty cells, retained aprons, release/lifetime,
invalid density/accumulation, budgets and stale tickets. Run all four APIs, both
graphics adapters and CUDA memory checking. Keep platform/performance/retirement
acceptance open. Record results here before marking this slice accepted.

## Acceptance record

- Existing ordinary gather and new inverse-distance cases pass all four APIs.
  Independent references cover zero/near-zero distances, transparent lanes,
  saturation, empty input and empty associations, signed support, actual GPU
  decoded points, separate evaluation, budgets, stale tickets and lifetime.
- All six D3D11/D3D12/Vulkan NVIDIA/AMD combinations pass native validation.
  CUDA memcheck reports zero errors. Logs: `build/m5-inverse-distance`.
- Installed static/shared API consumers pass 2/2 each with CUDA Toolkit discovery
  disabled, testing the new exported factory and retained streams. Both use the
  shared NVRHI runtime.
- Complete matrices pass **339/339 in214.85 seconds** and **256/256 in164.09
  seconds**, without failures/skips. Logs and JUnit are `full-tests.*` and
  `full-graphics-tests.*` in that directory. These runs include public point
  quantization, and precede interactive-optix's owned-snapshot migration.
- The first weighted fixture incorrectly described an absent color stream with
  an offset beyond its empty byte range. The public converter correctly rejected
  it; the fixture now separates an uncolored empty set from colored points with
  no active associations. A transient Windows executable-lock link failure
  succeeded on retry. Neither required a production contract relaxation.

Inventory: 100 retained entries, now32 owned-validated,12 sample-validated,
27 portable-foundation,23 partial and6 pending. Normalized-ushort position
quantization preserves canonical auxiliary attributes but does not claim legacy
packed velocity encoding. No source retirement is authorized. Deposition,
remaining consumer ownership and external platform/performance gates continue.
