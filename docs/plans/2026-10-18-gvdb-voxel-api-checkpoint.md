# M5 owned-volume voxel API checkpoint

Status: implemented and validated on Windows, 2026-10-18. The broader [ownership plan](2026-10-18-gvdb-unified-volume-ownership.md) remains in progress.

## Execution record

Samples commit `d00cfc1` adds SDK-independent fill, clear, same-format copy and apron reconstruction over the existing volume owner. The new public `IGVDBVoxelOps` factory retains its volume and returns the same one-use generation tickets accepted by `IGVDBVolume::recordAndPublish`. It never opens, submits or waits on command lists. No existing public volume vtable or IID changes.

Only written channels receive replacement allocations and resource/content revisions. Unchanged topology and channel resources remain shared. CPU placement is immutable and shared between generations; each recorded dispatch retains its own pipeline. Source/destination raw buffers are distinct, and one shader invocation owns every destination word, including R8 row and brick crossings. Copy preserves NaN payloads and signed zero. Aprons use all destination boundary components and integer sparse traversal. Empty, zero-mask, same-channel-copy and zero-apron cases return authenticated one-use no-op tickets without GPU allocation or revision changes.

Legacy fill conventions are retained explicitly. Filling coordinate-zero planes corrects a retained launch defect; RGB32 fill is an extension over unsupported legacy float3 surface writes. Unused slots are zeroed. The [operator contract](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBNvrhiVoxelOps.md) records these policies and incomplete operation families.

## Verification results

- Aggregate Release build passed. Owner, existing public API, new core/public voxel and contract checks passed **19/19** in 7.98 seconds. Evidence: `build/m5-voxel-aggregate-{configure,build,tests}.log`, JUnit `build/m5-voxel-aggregate-tests.xml`.
- Isolated graphics-only affected build and checks passed **15/15** in 5.94 seconds with `CMAKE_DISABLE_FIND_PACKAGE_CUDAToolkit=TRUE`. Evidence: `build/m5-voxel-graphics-{configure,build,tests}.log`, JUnit `build/graphics-only/m5-voxel-graphics-tests.xml`.
- Private core fixtures pass D3D11/D3D12/Vulkan/CUDA; native graphics validation is clean and CUDA Compute Sanitizer reports zero errors. Evidence: `build/m5-voxel/{dxbc,dxil,spirv,ptx}-smoke.log`, graphics `*-native.log`, and `cuda-memcheck.log`.
- Public fixtures pass all four APIs, clean native validation and zero CUDA memory errors. Evidence: `build/m5-contract/voxel-api-*-smoke.log`, `*-validation.log`, and `voxel-api-memcheck.log`.
- Installed static and shared consumers each pass **2/2 CPU checks plus 1/1 CUDA execution**. They verify ABI, concrete core linkage and actual factory/fill/apron/readback after owner/operator destruction, including the DLL boundary. Package and consumer builds disable CUDA Toolkit and ShaderTool discovery. Evidence: `build/m5-contract/voxel-installed-{shared,static}-{configure,build,test,cuda-test}.log`; package logs are `voxel-api-{shared,static}-{configure,build,test,install}.log`.

Independent CPU fixtures compare every byte for five formats, signed neighboring bricks, vector boundaries, raw NaNs/negative zero and unused slots. They also cover channel 31, unchanged resource revisions, retained old snapshots, operator reuse after repacking, stale/foreign tickets, failed preparation and destruction before submission. A separate numerical equation checks the retained sine fill. These are affected-slice results, not a new complete project matrix.

## Next work and limits

Smooth/grow/noise/cut/expand, custom dispatch, resample/reduction, arbitrary atlas block transfers and point/voxelizer factories remain unfinished at the public ownership layer. Transactional host adoption and coherent VBX load/save are next: preserve original slot coordinates and every logical byte on import, stage CPU/GPU state together, and save from one retained generation. Existing generation uploads regenerate aprons and therefore cannot substitute for exact VBX import. Raw-stream conversion is developing separately.

Consumer adoption, Linux execution, real multi-GPU validation, presentation comparisons and reference retirement remain open. The prior complete matrices are recorded in the [fifth checkpoint](2026-10-18-gvdb-volume-owner-api-checkpoint.md).
