# Ordered retained-volume composition

Status: implemented and focused Windows validation, 2026-10-20. This completes
the sample adoption of shared section/composition roles, not project acceptance.

`renderOwnedLayers` renders up to 64 retained snapshots in caller-supplied scene
order. Layers carry independent index-space cameras, channels, shading modes,
transfer functions and controls. Only the first layer sees the background;
later layers render over transparent black, pack on the GPU and use exact
integer RGBA8 over. No depth sorting, hidden wait or intermediate CPU readback
is introduced. Empty scenes clear the background. An Off first layer clears
transparent black, while later Off layers are skipped. Mode-specific alpha
is retained, including opaque section and empty-skip misses.

The returned raw RGBA8 buffer has R in its low byte. A separate uint diagnostic
reports nonfinite pack input, NaN depth and negative/exhausted traversal depth.
IEEE bit tests survive D3D11 compiler optimization; an explicit branch prevents
FXC from flattening the diagnostic atomic and avoids successful-pixel atomics.
Invalid extents, backgrounds, devices, snapshots and shading modes are rejected.
Input generations and GPU bindings follow the existing command-list lifetime.

`render-to-file --shade` adopts this path even for one layer. Repeated `--layer`
and `--layer-offset X Y Z` add translated instances in the first input's index
coordinate system. The primary file's repeated instances share its retained
snapshot. The camera still frames the primary volume; section planes are local
to each layer. The application checks GPU diagnostics before writing the PNG.
The legacy application's optional `--duplicate-offset` constructs the matching
reference scene without changing its original default or rendering kernels.

## Correctness evidence

- Independent constant-volume Beer attenuation and packed-byte equations test
  two distinct snapshots, reversed order, first/later Off, transparent deep
  misses, opaque section misses, 17x9 dispatch tails, retained lifetime, error
  reporting and invalid inputs.
- Affected application/algorithm tests: 40/40 Windows. Graphics-only focused
  tests including the mixed-RT correction: 32/32. Native D3D11/D3D12/Vulkan
  validation on both RTX4050/Radeon780M: 6/6. CUDA memory checking: zero errors.
- All 32 original single-volume captures are byte-identical to the pre-adoption
  captures and pass the existing fixture tolerances.
- Three fresh runs of the translated two-explosion reference, 1024x768, offset
  (32,0,0), cover all eight modes and four APIs. Maximum mean RGB errors across
  APIs for modes 0..7: .16948, 0, 0, .18839, .16602, .22514, .45451, .05804.
  RGB p99 is at most one byte. The exact section RGB and alpha 254->255 repair
  are checked separately. The compositor's exhaustive 256^3 byte test remains
  the independent integer oracle.

The comparison runner's two-layer limits are mean RGB .5, RGB p99 two bytes,
mean alpha 1.025 and fraction of pixels with a channel error above eight <=.02.
These allow two sampling boundaries plus the documented approximate-integer
composition difference. Original one-layer limits remain unchanged. Applying
the one-layer alpha limit initially failed as expected; the reference sections
contain alpha 254 in every pixel, while exact integer composition produces 255.
No threshold or shader was changed to reproduce that approximate-alpha defect.

## Performance and remaining gates

The first three-run process medians, including startup, VBX metadata I/O, render,
readback and PNG output, range across modes: retained CUDA 236-294 ms; portable
D3D11 383-725, D3D12 584-753, Vulkan 382-535, CUDA 303-516 ms. These measurements
precede the diagnostic-atomic fast path and are not isolated kernel timings.
Both instances share one logical 1,482,624-byte topology and 41,984,000-byte atlas;
renderer temporaries, transfers and allocator overhead are additional. This is
logical storage, not measured process/GPU peak memory.

Local evidence is in `build/acceptance/layer-reference`, `layer-single-reference`
and the `layers-*`/`native-layers-*` logs. The committed comparison script
reproduces the scene with `--layer-offset 32 0 0 --layer-asset <explosion.vbx>`.
No public ABI changed. Broader scenes, reconstruction benchmarks, GPU topology
integration, Linux and supported real peers remain. Full matrices must use the
final committed aggregate gitlinks before project completion.
