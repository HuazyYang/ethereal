# Point-cloud GPU topology integration

The production point-cloud reconstruction now uses Slang key generation, stable
64-bit radix sorting, unique marking, scans and compaction before allocating its
owned tree. Checked signed support enumeration preserves the original asymmetric
support and pre-quantization association. Each batch contains at most 1,048,576
candidates, translated by its integer minimum into the key program's nonnegative
16-bit brick coordinates. The maximum span is checked before float conversion;
this does not narrow the existing reconstruction tree's coordinate domain.
Only compacted GPU results enter the final sorted host set. Stable host ordering
preserves leaf IDs and atlas placement across batch boundaries.

The host allocates authoritative node pools, then the public topology activity
factory applies markers, derives activity, clears child lists and rebuilds all
links on the GPU. Actual fetched bytes pass graph validation before publication
and scalar-atlas allocation. A failed frame leaves the preceding visible snapshot
intact. The real asset has 1,867,648 points, 14,583 leaves and five key batches.

This closes the previously separate key/allocation/link/fetch integration roles.
The retained `GVDBPointOps::allocateUniqueNodes` also allocates nodes on the CPU
after GPU unique-key readback. An autonomous GPU heap allocator is not required
to preserve that behavior. Fixed-pool activity retains inactive allocated nodes;
fresh-frame reconstruction compacts candidates and replaces the owner. Arbitrary
disconnected pools remain rejected, rather than becoming a new public input format.
The general public point API retains its checked signed host topology path.

Radix sorting now reuses one recursive scan workspace across all 64 passes.
At 1,048,576 keys, logical scan buffers fall from 270,541,056 to 4,227,204 bytes;
including radix flags and two output key buffers, scratch falls from 308,289,792
to 41,975,940 bytes. These figures exclude input, binding/constant allocations and
driver overhead. The independent stable-sort oracle now covers 65,539 entries,
including duplicate keys, high bits, partial groups and three scan levels.

Native validation exposed that the old general compute test ignored adapter and
validation options. It now uses the shared device setup and fails on diagnostics.
Actual AMD Vulkan execution then exposed shared-edge double crossings in the
standalone voxelizer. That program now includes the public mesh voxelizer's exact
division implementation, eliminating the duplicate geometry implementation.

## Measurements

Three serial process runs per API compare samples `3864daf` with the integrated
path. The reconstruction test includes startup, asset I/O, reconstruction, CPU
validation and readback. Peak working set is CPU process memory, not GPU memory.
Numbers below are medians, milliseconds / MiB:

| API | Before | Integrated |
| --- | ---: | ---: |
| D3D11 | 2476.76 / 1221.95 | 2480.16 / 1254.61 |
| D3D12 | 2428.17 / 1215.03 | 3164.11 / 1235.68 |
| Vulkan | 2171.87 / 1228.18 | 2570.13 / 1251.09 |
| CUDA | 2409.57 / 1205.70 | 2398.81 / 1207.50 |

The integrated GPU stages add overhead on D3D12 and Vulkan. The workspace
improvement is relative to allocating 64 scan workspaces; it is not a claim that
GPU key discovery beats the preceding host discovery path.

The actual point-cloud scene, 800x600 with eight samples, also has three-run
process measurements against the retained implementation:

| Route | Process ms | Peak CPU MiB |
| --- | ---: | ---: |
| Retained CUDA/OptiX, D3D12 window | 2041.71 | 513.32 |
| Portable D3D12, headless | 4925.56 | 522.42 |
| Portable Vulkan RT, headless | 4021.35 | 511.40 |
| Portable CUDA/OptiX, headless | 7546.01 | 617.26 |

These are end-to-end application costs including reconstruction, pipeline setup,
rendering and PNG output, with different window/headless frontends. They are not
steady-state kernel benchmarks. The portable application is slower on this
fixture; correctness acceptance has no invented performance threshold.

## Validation

Integrated algorithms/reconstruction/asset/rendering tests pass 22/22 on Windows.
All four compute and three RT point-cloud PNGs are byte-identical to the preceding
portable checkpoint. Independent CPU oracles still validate support, topology,
quantization, gathers, smoothing and aprons; the full asset requires multiple
GPU key batches. Final native, sanitizer, graphics-only and full matrix evidence
is recorded in the aggregate status after completion.

Local logs, three-run measurements and image hashes are under
`build/acceptance/point-keys`. Linux and supported real CUDA peers remain external
acceptance gates. The retained implementation remains available.
