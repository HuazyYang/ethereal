# Retained rendering modes and matched reference scene

Status: Windows implementation and focused validation complete; project-wide
acceptance, other scenes and required external hardware remain open.

`OwnedVolumeModes` exposes retained-snapshot voxel, trilinear, depth-alias, deep,
level-set, empty-skip and off rendering. Spray calls the shared renderer and its
duplicate shader is removed. Sampling step, threshold, epsilon, shadow amount/
bias, extinction, albedo, minimum value and alpha cutoff are explicit. Deep mode
also clips at the caller's maximum ray distance. Level-set uses strict-below
sampling and positive gradients. The legacy depth entry is a trilinear alias.

Traversal exhaustion is separate from misses, including shadow, voxel and deep
limits that spray previously treated silently. Miss alpha is zero for deep/off.
The empty-skip diagnostic explicitly preserves the retained PTX's positive
coordinate low-byte wrap and negative-to-zero conversion. Other RGBA8 conversion
saturates finite colors. Transfer lookup subtracts the threshold before applying
the retained 16,300 endpoint in a 16,384-entry table.

`render-to-file --shade 0..7 --reference-scene` restores the original explosion
camera, light, VBX transform, transfer table and shading controls. Default bounds
framing remains available. Analytic tests cover the seven shared modes, controls,
signed coordinates, color modulation, clipping, misses, rejected inputs and limits.
All eight reference modes also have application tests on each API.

## Focused validation

- Shared mode/spray tests: 23/23 Windows; 18/18 graphics-only.
- Final shared-mode/reference-scene tests: 36/36 Windows.
- Native D3D11/D3D12/Vulkan: NVIDIA and AMD adapters, 6/6.
- CUDA Compute Sanitizer: zero errors, including positive diagnostic wrapping.
- Twenty spray captures: modes 0/2/3 unchanged; mode 1 now agrees on all APIs
  (one formerly divergent CUDA pixel changes). Deep mode changes because transfer
  indexing and miss alpha are corrected. New cross-API error is at most one byte.

## Matched explosion images

The optional `CompareLegacyRender.py` runs the retained CUDA executable and all
four portable APIs serially at 1024x768. The retained executable/PTX is unchanged.
Results below are the worst across the four APIs; errors are in byte codes.

| Mode | Mean RGB error | 99th percentile RGB error | Maximum channel error |
| --- | ---: | ---: | ---: |
| Voxel | 0.000041 | 0 | 46 |
| Section 2D | 0 | 0 | 0 |
| Section 3D | 0 | 0 | 0 |
| Empty-skip | 0.000174 | 0 | 127 |
| Trilinear | 0.001660 | 0 | 77 |
| Tricubic | 0.031317 | 0 | 77 |
| Level-set | 0.156445 | 0 | 46 |
| Deep | 0.041792 | 1 | 27 |

The section defaults sample outside this asset, so their identical images are
background checks; the separate section fixture establishes contributing behavior.
The small number of large discontinuities includes voxel faces, wrapped diagnostic
bytes and threshold/shadow decisions. Software float interpolation and bounded
geometric traversal do not promise bit-identical texture-filter/HDDA results.
The explicit fixture limits are mean RGB <=0.25, 99th percentile RGB <=1, mean
alpha <=0.025, and <=1% of pixels with any channel error >8. All captured APIs pass.
These fixture limits are not a claim that every legacy scene has been accepted.

## Timing and storage, separate from correctness

Three serial process runs per mode include startup, loading, rendering/readback
and PNG writing. Median ranges across the eight modes: retained CUDA 231–276 ms;
portable CUDA 301–398 ms; D3D11 542–619 ms; D3D12 579–687 ms; Vulkan 382–470 ms.
The portable reference-view path additionally parses VBX transform metadata.
These are end-to-end measurements, not kernel speed ratios. First-use compilation,
driver caches and machine load affect them.

The portable snapshot reports 1,482,624 logical topology bytes and 41,984,000 atlas
bytes. Legacy reports 1.75 MiB pooled topology and 40.04 MiB atlas. Both preserve the
same atlas extent; pool capacity and driver allocation overhead differ. This is
logical resource accounting, not measured total GPU residency or process peak RSS.
Repeated reconstruction and the other sample families still need broader timing/
memory comparisons.

Local logs/images/three-run metrics are in `build/m5-sections/matched-reference`.
The reproducible comparison script is committed with the samples. No legacy
source retirement or Linux/real-peer completion is claimed.
