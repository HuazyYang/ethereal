# M5 volume owner, public API and spray checkpoint

Status: implemented and validated on Windows, 2026-10-18. The broader [M5 plan](2026-10-18-gvdb-unified-volume-ownership.md) remains in progress.

## Execution record

| Repository / commit | Implemented slice |
| --- | --- |
| ethereal-nvrhi `e4a0e68` | Initialize Vulkan native handles and reject missing handles or queue families before driver dispatch. An uninitialized optional copy queue caused the new lifecycle fixture to crash. |
| ethereal-samples `7959786` | SDK-independent multi-channel GPU ownership, retained generations, prepared publication/readback, versioned queryable API and static/shared packages. |
| ethereal-samples `0c94cd5` | Transactional CPU import of validated serialized topology, including padded/reordered pools and the real VBX asset. |
| ethereal-samples `b47d4d5` | Spray-deposit migration, arbitrary ray queries, translucent viewer overlays and explicit input repeat policy. |

The GPU owner uses one device and topology with up to 32 canonical raw channels. Atlas growth, pitch/apron changes, removal and reordered graphs preserve compatible interiors by signed leaf origin. New slots/channels use their defined background; aprons are regenerated. Channel incarnations prevent removed/recreated channels from inheriting stale content. Preparation allocates and validates before recording; publication records into the caller's open command list and never submits or waits. Snapshots, tickets and readbacks retain required resources after the volume owner is released.

The public facade uses new portable GVDB IIDs and API version 1. Its C factory and public interface outputs clear on failure; concrete C++ preparation preserves existing smart-pointer outputs. DLL interfaces expose plain descriptors, borrowed views and reference-counted objects, not STL ownership. Legacy GVDB symbols and interfaces remain separate. This is an additive implementation, not promotion of the old `GVDB.h` to a completed compatibility facade.

The import bridge preserves graph IDs/order and attributes while recomputing active bounds and discarding atlas placement. It deliberately does not validate/import atlas maps or channel bytes. Coherent GPU VBX load/save remains a later transaction; successful CPU import does not establish serialization parity.

## Verification results

- Complete Release matrix: **231/231**, 194.07 seconds, `build/checkpoint-5-tests.log` and `build/checkpoint-5-tests.xml`.
- Complete isolated graphics-only matrix with `CMAKE_DISABLE_FIND_PACKAGE_CUDAToolkit=TRUE`: **175/175**, 153.75 seconds. Logs are `build/checkpoint-5-graphics-{configure,build,tests}.log`; JUnit is `build/graphics-only/checkpoint-5-graphics-tests.xml`.
- After the full Release run, repeat-policy and nonopaque-overlay tests were strengthened. Twenty of 23 affected checks passed immediately; three new InteractiveScene checks exposed an aliased C-array test baseline. Copying the baseline instance corrected the fixture; those three passed in 3.35 seconds. Both runs are retained as `build/checkpoint-5-followup-tests.log/xml` and `build/checkpoint-5-controls-tests.log/xml`. The complete graphics-only matrix includes these final source changes.
- Owner fixtures pass on D3D11/D3D12/Vulkan/CUDA. Native graphics validation is clean; CUDA Compute Sanitizer reports zero errors. Evidence: `build/m5-owner/{fixed-*,native-*,cuda-memcheck,descriptor}.log`. The fixtures cover five formats, channel 31, raw NaN/negative-zero payloads, grow/reorder/remove/recreate/empty transitions, independent apron bytes, malformed artifact ABI, failed preparation, stale/foreign tickets and pre-submission destruction.
- Public API tests pass 5/5 including ABI. Native graphics checks are clean; CUDA memory checking reports zero errors. Evidence: `build/m5-api-tests.log`, `build/m5-api-{dx11,dx12,vk}-validation.log`, `build/m5-api-memcheck.log`.
- Static and shared installed SDK consumers each pass 3/3: public ABI, concrete ownership linkage, and real CUDA publication/readback after owner destruction. The shared consumer crosses the DLL boundary. Builds disable CUDA Toolkit and ShaderTool discovery and use installed NVRHI. Reusable fixture: `ethereal-samples/src/gvdb_samples/gvdb/tests/api-consumer`; logs: `build/m5-contract/`.
- CPU import passes integrated Release and standalone AddressSanitizer, including 10,284 active explosion leaves, malformed ranges/links, overlapping child pools, truncated padded records, and byte/revision preservation on failure. Final ASan evidence: `build/m5-import-standalone/final-tests.log`.
- Spray's 19 tests and seven focused control/native-window checks pass. Analytic/asset, controls and 1024x768 three-frame application CUDA memory checks report zero errors; the application was checked again after alpha blending changed (`build/spray-application-alpha-memcheck.log`). Final 128x96 pixel bytes match across all four APIs (`build/spray-alpha-cross-api.json`).

The fresh legacy/new spray comparison at 1024x768 has mean absolute RGB difference 0.392708/255, maximum channel difference 93, and 0.9982% of pixels differing by more than eight levels. Geometry/framing and the translucent fan agree closely; line rasterization and faint reference face-grid shading differ. This is tolerant visual evidence, not exact image parity. Captures and metrics are `build/spray-legacy.png`, `build/spray-new-alpha.png`, and `build/spray-legacy-alpha-comparison.json`.

## Limits and next work

GPU publication currently restricts node endpoints and leaf aprons to [-8388607,8388607]; CPU topology supports a wider signed32 domain. Regular atlas dimensions have even pitch, so complete R8 allocations have no odd tail; six-byte rows and brick crossings are tested on GPU, while generic odd raw allocation rounding is a CPU descriptor test. Recording revisions do not imply completion, and void NVRHI commands cannot promise rollback after device loss or partial driver recording.

Next, voxel factories will reuse the same authenticated preparation/publication route, retain unchanged topology/channels, and replace only selected channel allocations. Zero-work tickets must remain one-use while preserving revisions. Point/voxelizer/serializer transactions additionally need validated candidate-host adoption. Consumer adapters must then stop owning duplicate topology and observe resource revisions. The new CPU import is a prerequisite, not a substitute for that integration. Private operator and raw-stream work begun after this checkpoint is not part of the committed/tested results above.

Linux execution, real multi-GPU interop, full interactive presentation comparisons, production reference retirement and controlled performance comparisons remain outstanding.
