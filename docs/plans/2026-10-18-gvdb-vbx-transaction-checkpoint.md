# M5 transactional VBX ownership checkpoint

Status: implemented and validated on Windows, 2026-10-18. The broader [ownership plan](2026-10-18-gvdb-unified-volume-ownership.md) remains in progress.

## Execution record

Samples `d522c84` implements transactional host/atlas adoption and the additive public `IGVDBSerializer`/`IGVDBSaveTicket` interfaces. Import prepares an independent host, exact original atlas placement and a complete replacement channel set. It advances identity/revisions and swaps storage inside the stable host object only through the existing `recordAndPublish` path. Stale host/configuration/publication changes reject the ticket. Preparation failure leaves the live volume unchanged.

Exact import preserves all logical channel bytes, including aprons and unused slots. Normal generation uploads and repacking regenerate aprons and therefore remain a separate policy. CPU pool/node borrows are invalidated on adoption; bare node IDs must be paired with the host epoch. The owner validates graph/placement, bounds and device limits before publication.

The serializer retains its owner. Load returns an existing generation ticket; save freezes one authenticated snapshot's placed topology, channel order and immutable metadata, then records explicit readback. After the caller submits and waits, the save ticket returns an owned NVRHI blob even if the owner/serializer have been released. No operation opens, submits or waits on a command list. Metadata includes all transform vectors, voxel size and all 256 grid-name bytes; channel mutations and repacking in the same host epoch retain it. Old snapshots keep their own metadata across later imports. Clear/reconfigure drops metadata from subsequent generations. Save overrides are copied into the ticket and do not alter the source snapshot.

## Verification results

- Full aggregate Release build passed. The affected host/owner/API/voxel/adoption/serializer matrix passed **34/34** in 11.70 seconds. Evidence: `build/m5-serializer-final-{configure,build}.log`, `build/m5-serializer-tests.log/xml`.
- Complete graphics-only build passed with CUDA Toolkit discovery disabled. The same affected slice passed **27/27** in 10.19 seconds. Evidence: `build/m5-serializer-graphics-{configure,build,tests}.log`, JUnit `build/graphics-only/m5-serializer-graphics-tests.xml`.
- Private adoption fixtures pass all four APIs, clean native graphics validation and zero CUDA memory errors: `build/m5-adoption/{dxbc,dxil,spirv,ptx}-smoke.log`, graphics `*-native.log`, and `cuda-memcheck.log`.
- Public synthetic and real explosion fixtures pass native D3D11/D3D12/Vulkan validation: `build/m5-serializer-{dx11,dx12,vk}-{validation,asset-validation}.log`. Both CUDA memory checks report zero errors: `build/m5-serializer-memcheck.log` and `build/m5-serializer-asset-memcheck.log`.
- Isolated static/shared API packages each pass **3/3 ABI checks**. Installed consumers each pass **1/1 ABI plus 1/1 actual CUDA save/load** with CUDA Toolkit/ShaderTool discovery disabled. The shared case crosses the DLL boundary. Evidence: `build/m5-contract/serializer-api-{shared,static}-{configure,build,test,install}.log` and `serializer-installed-{shared,static}-{configure,build,test,cuda-test}.log`.

The public fixture uses signed leaves, apron 2, a 3x2x1 grid with reversed sparse slots 5 and 2, five distinct byte patterns including NaN/-0 and poisoned unused/apron bytes, all metadata fields, old snapshots after a second import, GPU fill followed by save, stale/foreign tickets, aliased output rejection, and destruction before submission/completion. The real explosion asset preserves every logical channel byte and each original leaf/slot association on all four APIs. The private fixture additionally checks copied candidate isolation, stable host address, frozen topology export and metadata across repacking.

The first synthetic run compared the padding of `SnapshotDesc`, causing four false failures while all four real-asset tests passed. The fixture now compares actual fields; all four synthetic tests then passed, followed by the complete affected matrices above. Initial and corrected logs remain `build/m5-serializer-first-tests.log/xml` and `build/m5-serializer-followup-tests.log/xml`. Review also corrected aliased output/diagnostic handling before final validation. These are affected-slice results, not another complete project CTest matrix.

## Limits and next work

The public serializer accepts one nonempty uncompressed supported VBX grid and one to 32 dense logical channels numbered 0..N-1. Empty snapshots and holey channel masks fail explicitly; no renumbering occurs. Saving emits canonical VBX 1.11 and preserves represented data rather than original file encoding. Channel void values are not in VBX and default to zero. Explicit GPU/blob budget violations return out-of-memory; errors caught inside the existing boolean/string CPU codec, including its allocation exceptions, retain that codec's invalid-input classification. Budgets do not cap parser CPU allocations. [Usage and restrictions](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBNvrhiSerializer.md) are documented.

Dense candidate rebuild/accumulate with survivor remapping for point/voxelizer operations remains separate from exact import. Remaining voxel families, public point/voxelizer factories, raw-stream conversion, and consumer migration are still in progress. Linux, real multi-GPU execution, broader presentation/performance comparisons and reference retirement remain open.
