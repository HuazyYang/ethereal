# M5: unified GVDB volume ownership and public API migration

Status: Approved for implementation within the user-authorized migration. Reviewed 2026-10-18; implementation in progress.

This is a source inventory and proposed implementation sequence, not a claim that the public migration is complete. It implements the GVDB portion of the [approved project plan](2026-10-18-ethereal-nvrhi-slang-support.md). The review used root `2e7c3ec`, samples `a310bb5`, and the subsequent working-tree portable scene/fluid additions. No GPU tests or implementation changes were performed for this document.

## Scope and ownership decision

Keep NVRHI's `IDevice`, buffers, binding sets, pipelines, command lists, queries, and RT interfaces as the only execution model. GVDB remains a volume data structure with operation factories. It does not acquire a new device, queue, kernel, or native-pointer abstraction. No NVRHI core interface change is required by this plan.

The production `IGVDBVolume` will own mutable host topology, one shared GPU topology representation, and all channel allocations. Its operators will record ordinary NVRHI commands. CPU serialization/build tools will remain usable without a GPU or SDK. Existing `SlangVolume` and `SlangAtlas` become adapters over that ownership, rather than permanently maintaining independent copies of the hierarchy.

Preserve legacy source, headers, kernels, executables, and captured references in an explicitly selected reference build until the replacement passes the gates below. Never reinterpret a `donut::gp` pointer as an NVRHI interface. This migration changes GVDB interface identities where signatures/vtables change; it does not change the identities of NVRHI interfaces merely because GVDB uses them.

## Source inventory and concrete gaps

All links below are repository sources inspected for this plan.

| Area | Existing behavior and portable implementation | Required integration or missing behavior |
| --- | --- | --- |
| Public objects | [GVDB.h](../../ethereal-samples/src/gvdb_samples/gvdb/GVDB.h) separates volume, voxel operators, point operators, voxelizer, and serializer, but exposes gp devices/queues/buffers/textures/kernels and pointer-bearing `VDBInfo`. | Retain the object roles and CPU-facing operations; replace GPU-facing types and executable contracts explicitly. The old header is not a portable facade. |
| Host pools | [GVDBAllocator](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBAllocator.cpp) grows reservations geometrically, preserves used records, and clears counts without shrinking. [GVDBVolume](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBVolume.cpp) implements activation, parent links, root growth, extents, halo, bounds, and flags. | Extract CPU storage/algorithms without GPDevice includes or eager GPU work; add overflow/index validation while preserving valid-input semantics. Raw node pointers become invalid after pool growth and must be documented accordingly. |
| Portable topology | [packVolume](../../ethereal-samples/src/gvdb_samples/gvdb/slang/GVDBPortableData.cpp) validates and packs 64-byte node records, 8-byte references, level offsets, and atlas maps. [buildTopology](../../ethereal-samples/src/gvdb_samples/gvdb/slang/GVDBTopologyBuilder.cpp) constructs complete snapshots. | Neither is a mutable public volume. Both currently require a root/nonempty leaves; `clear()` and newly configured empty volumes need an explicit valid representation. Builder root anchoring at the minimum leaf differs from incremental legacy root growth; do not replace CPU semantics accidentally. |
| GPU mirrors | [SlangVolume](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBSlangVolume.h) owns one R32 atlas and duplicate topology buffers; [SlangAtlas](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBSlangAtlas.h) owns a raw channel and another copy. Both borrow sample `ComputeRuntime`. | Shared topology ownership, multiple independently changing channels, resource snapshots, upload/readback, and channel publication after ping-pong operations. Borrowed runtime lifetime must leave the public API. |
| Placement and channel storage | Legacy `updateAtlas()` densely assigns active leaves in pool order, grows atlas Z, then copies overlapping texture coordinates during resize. Portable channels cover R8, RGBA8, R32, RGB32, RGBA32. | General remapping across removal, reordered leaves, changed X/Y pitch, and Z growth for every channel. Legacy coordinate-copy behavior does not preserve leaf identity after compaction. New-slot initialization, empty slots, and failure atomicity need defined contracts. |
| Voxel operations | [GVDBVoxelOps](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBVoxelOps.cpp) provides fill, clear, six compute ops, custom kernels, aprons, resample, regional downsample, and reduction. Portable raw/scalar programs implement the core arithmetic. | Dispatch into the selected owned channel, complete format/parameter matrix, `skipOverAprons` and `updateApron` semantics, vector boundary values, custom reflected program dispatch, destination block upload, and reduction excluding inactive slots. Existing wrappers force particular apron schedules and cannot blindly implement every old switch. |
| Point topology and binning | [GVDBPointOps](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBPointOps.cpp) supports rebuild/incremental removal/accumulation, requested full rebuild, strided position/velocity/color streams, bounds, subcells, and insertion/scatter. Portable keys, scan/sort, subcell bins, conversion, gather, and application pipelines exist. | Public state machine and arbitrary offset/stride inputs; shared topology mutation; optional velocity transport; exact normalized-ushort path; directed scatter/support dispatch contracts. Preserve accumulation and rebuild as distinct operations. |
| Persistent reconstruction | [PointFusionVolume](../../ethereal-samples/src/gvdb_samples/samples/point-fusion/PointFusionVolume.cpp) accumulates a CPU leaf set, remaps old scalar/color voxels on GPU, and publishes replacements. Fluid/point-cloud reconstruction have related orchestration. | Extract the reusable placement/remap mechanism. This sample is evidence for a working scalar/color route, not a general mutable 32-channel volume or GPU-only topology builder. |
| Solid voxelization | [voxelizeMesh](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBSlangVoxelizer.h) produces dense R8/R32/S32 output from host vectors. CPU dense-to-sparse construction is implemented. | The public voxelizer takes NVRHI mesh buffers, selected channel and transform; validate/read those buffers or add a direct GPU input path, then activate/publish the result. A documented CPU topology phase is acceptable; a silent change to an unrelated renderer is not. |
| VBX | [portable VBX](../../ethereal-samples/src/gvdb_samples/gvdb/slang/GVDBPortableVbx.h) preserves ordered channels in all five formats, transform, grid name, voxel size, original slots, and normalized bitmask topology. | Connect transactional load and coherent readback/save to volume ownership. Enforce public channel and backend limits before upload. Reject unsupported compression, multi-grid and reuse/layout variants explicitly. |
| Scene consumers | [GVDBScene](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBScene.h) still exposes gp transfer-function resources; portable scene/render helpers already use NVRHI. | Port transfer-function ownership/commit and provide a volume snapshot adapter for viewer, surface extraction, ray query, and RT. Channel replacement must invalidate cached bindings and AS bounds as appropriate. |
| SPH and velocity utilities | Both legacy fluid solvers are SPH. `SlangSphSimulation` implements their pipeline; [transferGridVelocity](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBSlangVelocity.h) implements sparse MAC sampling, PIC/FLIP blending and optional midpoint advection. | Integrate selected scalar velocity channels when needed. A complete FLIP solver is additional future work, not an unported legacy solver. |

The older [GVDBMigration inventory](../../ethereal-samples/src/gvdb_samples/gvdb/slang/GVDBMigration.md) is useful background but predates persistent point fusion and the mixed-scene RT implementation. Its reflection/refraction, deep mesh continuation, and material gaps must not be repeated as current missing functionality. M5 ownership acceptance does not imply that every rendering mode or platform gate in the overall project is complete.

## Proposed public contract

Preserve `IGVDBVolume`, `IGVDBVoxelOps`, `IGVDBPointOps`, `IGVDBVoxelizer`, and `IGVDBSerializer` as reference-counted, queryable GVDB interfaces. Introduce a GVDB API version and new IIDs for changed interfaces; use C factories, `FRESULT`, `noexcept`, cleared failure outputs, and narrow inline convenience wrappers following NVRHI conventions. Names below describe the proposed seam and are not already implemented declarations.

| Old seam | Proposed production seam |
| --- | --- |
| `createGVDBVolume(gp::IDeviceQueue*, vfs, ...)` | Factory descriptor retaining `nvrhi::IDevice*`, a shader artifact source/VFS, and artifact root; no CUDA adapter creation. Filesystem/VFS convenience stays outside the CPU core. The selected NVRHI device determines target artifacts. |
| `getDevice()` / `getQueue()` | `nvrhi::IDevice*` plus explicit `nvrhi::ICommandList*` parameters on recording operations. Queue selection/submission uses NVRHI, not another queue interface. |
| `getChannelTexture()` | Owned buffer channel view: format, dimensions, logical bytes, physical padded bytes, channel index, revision, and retained `nvrhi::BufferHandle`. Optional derived texture views are separate and capability-checked; raw storage is canonical. |
| `GVDBPoolView::gpu` | CPU pool view remains CPU data/count/stride. A GPU snapshot exposes flattened NVRHI node/child buffers and per-level offsets/ranges. Do not pretend each level still has its own independently based pointer. |
| `PointData` | NVRHI buffer, byte offset, byte stride, element count, and explicit component representation. Validate last-element extent by subtraction/division before arithmetic; retain streams while an operation object stores them. |
| `fillVDBInfo` / `getVDBInfoGPU` | Plain `VolumeInfo` plus level metadata and explicit resource bindings. No native pointers or texture/surface handles in shared data. |
| `getKernel` / `computeKernel(gp::IKernel*)` | `IShaderProgram` entry or ordinary NVRHI compute pipeline with documented volume binding slots, reflected parameters, and additional binding sets. Do not retain the old positional CUDA argument ABI. |
| Implicit queue writes and waits | Recording methods enqueue into an open caller command list. Explicit convenience submit/readback methods may block and document that fact; serialization/bounds reads must not hide GPU work behind an apparently CPU-only getter. |

Library internals may share compiled programs/pipelines by device and artifact identity. This is shader caching, not a second execution runtime. Refactor `ComputeRuntime` into reusable recording helpers as needed; the public library must not depend on a sample executable's include directory or the lifetime of its `ComputeRuntime` stack object.

Recording operations never close, execute, or reopen the caller's command list. Multi-phase topology operations that need counts/readback have an explicit submit/readback boundary; they cannot truthfully be one asynchronous call taking only an already-open list. Provide a synchronous convenience orchestration first, with named CPU/GPU phases, then optimize after semantic tests pass. Avoid simultaneous immediate command lists.

### CPU topology semantics

Keep the 64-byte node record and 8-byte `NodeId` serialization layout. Treat native host bitfields as a convenience; encode/decode serialized references explicitly as group, level, and 48-bit index, and use two 32-bit words in shaders. Portable GPU offsets/counts remain bounded by the current 32-bit addressing implementation even though the file reference has 48 index bits.

Preserve these observable behaviors:

- Configuration level order, root/parent/child references, allocated versus active counts, inactive leaf flags, six-face halo activation, and clear retaining capacity/configuration/channel descriptors.
- Point activation floors coordinates, covering-node placement floors negative coordinates, and `computeExtents(level,bounds)` retains its documented subtract-then-truncate convention. Add fixtures for these differences instead of silently substituting one rounding rule everywhere.
- Explicit low-level node/child allocation and root setting remain available. Child lists initialize to null; leaf nodes have no child list. GPU upload validates references before publication.
- Node IDs remain stable during append-only edits in a topology epoch. `clear`, reconfiguration, or a full rebuild invalidates them. Pool pointers are borrowed and may become invalid on any growth; callers reacquire pointers after allocation.
- Manual `Node*` edits cannot be observed automatically. `finishTopology`/commit validates and establishes the new revision, recomputing bounds when requested. Concurrent host editing and recording is unsupported until separately synchronized.

Define a valid empty configured volume with null root, zero active leaves, empty bounds, and no live atlas references. Read-only sampling returns the defined background; voxel operations on no active leaves are no-ops. Shader traversal must test the empty flag/count before loading a root. Do not allocate a fake active brick merely to satisfy the current packer. Empty VBX save behavior must be explicit and tested; until interoperability is verified, return an unsupported-format diagnostic instead of writing stale topology.

### Resource snapshots and submission lifetime

A snapshot holds metadata and retained NVRHI handles for nodes, children, levels, atlas map, and selected channel allocations, with topology/placement/channel revisions. It is an immutable binding description, not a promise that channel contents never change: ordinary writes to a retained allocation still follow command ordering. New allocation publication never changes a previously acquired snapshot's handles.

Take a snapshot when recording an operation or building renderer bindings. Retain its buffers, parameter upload allocations, scratch buffers, bindings, and programs through command execution. Publication after a resize changes the volume's current handles; earlier submissions continue using the earlier generation. Cross-command-list consumers must submit/wait in the correct order, and cross-device resources require the existing public interop path.

Ping-pong operators publish the resulting channel allocation and increment its resource revision. Renderer/scene adapters rebuild bindings when that revision changes; an old raw pointer is not a permanently live view. Topology/bounds revisions also invalidate affected procedural AS inputs. Destruction must honor submitted work without requiring `waitForIdle()` on every ordinary edit.

`commitPools` uploads a validated host revision; `fetchPools` explicitly reads and validates a GPU-authored revision. Define CPU/GPU authority and dirty state so a stale host upload cannot overwrite a newer GPU edit. Fetch does not infer new allocation counts from arbitrary memory: the builder supplies validated counts/root metadata. Caller-owned command lists and resources must belong to the selected device.

## Multi-channel atlas policy

Support up to the existing 32 logical channels. Do not bind all 32 UAVs to every dispatch; run channel-specific or bounded batches for the D3D11 baseline. Keep a single hierarchy and atlas map per volume. Canonical byte strides are 1, 4, 4, 12, and 16 for R8, RGBA8, R32, RGB32, RGBA32. Round physical raw-buffer allocation to four bytes; logical channel data and VBX serialization exclude padding.

R32 algorithms currently use structured float buffers while raw operators use byte-address buffers. Resolve this deliberately: use a validated NVRHI resource supporting both required view kinds, or port those algorithm bindings to canonical raw loads/stores. Do not maintain unsynchronized raw and structured copies or substitute typed `Buffer<T>` on CUDA; pinned Slang typed-buffer CUDA generation is explicitly rejected.

`GVDBChannelDesc` retains value format and boundary semantics. Replace gp sampler metadata with explicit portable sampling/addressing metadata or NVRHI sampler descriptors interpreted by the software sampler. Advertise only implemented modes; texture-only features such as comparison filtering or anisotropy cannot silently become point/trilinear sampling. Existing renderer point/trilinear/color rules remain independent of storage choice.

Placement updates follow this sequence:

1. Capture the old topology/map and every old channel allocation before editing `Node::value`.
2. Construct and validate the destination map. Default placement preserves legacy active-pool ordering and Z growth for predictable CPU/API behavior; an optional stable-slot policy can be added later without being the default.
3. Match surviving leaves by spatial leaf identity within compatible brick configuration. Pool index alone is insufficient across full rebuilds. Reconfiguration changing voxel/brick interpretation is destructive unless an explicit resample operation is requested.
4. Allocate destination storage for every channel before publishing any. Initialize new/unused regions deterministically using channel defaults. Preserve survivor interior bytes; copy aprons only when still valid, otherwise regenerate them against the new topology and boundary value.
5. Record destination-owned remap kernels or safe buffer copies. R8 kernels own complete 32-bit destination words, including words crossing brick boundaries; no overlapping byte stores. RGB32 retains all 12 bytes per voxel. Never perform overlapping compaction in place.
6. Publish the complete metadata/channel generation only after preparation succeeds. Submission dependencies make it usable by later work. Retain old resources for earlier commands. Validation/allocation failure leaves the old published volume unchanged.

No readback is needed merely to relocate atlas contents. CPU topology/key orchestration may read compact point/count data explicitly; that is distinct from native graphics/CUDA interop, whose no-host-staging contract remains unchanged.

Add checked `copyAtlasBlock`/upload and readback APIs with explicit logical source format, byte offset, row/slice pitch, destination voxel bounds, and aliasing policy. Handle R8 unaligned rows without clobbering adjacent bytes. Removing all leaves clears the logical placement; retaining capacity must not expose stale data when a later leaf reuses a slot.

## Operator factories and compatibility details

Operators retain their volume. They acquire its current snapshot when recording, not when the operator factory is created. Factories fail cleanly for missing/incompatible shader artifacts. A generic user program follows explicit volume bindings and reflected uniform packing; library factories do not expose backend kernel names as an ABI.

| Operation family | Required behavior before claiming public parity |
| --- | --- |
| Fill/clear/apron | Cover all advertised formats, interior and unused-slot policy, per-channel void value, apron face/edge/corner propagation, and channel publication. Existing RGB32 raw support is an extension over legacy unsupported surface kernels and should be labeled accordingly. |
| Smooth/grow/noise/cut/expand | Match finite-parameter and format contracts, iteration count, zero-iteration behavior, whether aprons participate, and update timing. Preserve deterministic separate-source/destination writes; do not recreate legacy cross-block races. |
| Resample/downsample/reduce | Preserve index-to-source matrix convention and remap ranges. Use `downsampleRegion` for the legacy inclusive regional placement rule, not the differently defined `downsampleDense`. Reduction sums active interiors only, with a documented floating tolerance. |
| Point rebuild/accumulate | Rebuild removes no-longer-required leaves; accumulate preserves prior leaves/data. Honor support expansion, requested rebuild, minDepth and root growth. Public CPU semantics are not restricted to the legacy GPU builder's one-to-five-level limitation when the replacement supports more; report any extension. |
| Subcells/gather | Float positions, packed colors and optional velocities retain original point association. Empty cells have defined scalar/color results. Density uses max(radius-distance); level set uses min(distance-radius); accumulate starts from previous channel values. |
| Normalized ushort path | Legacy `FP16` is ushort3 normalized over bounds, not IEEE half. Add matching bounds, quantization, decode and velocity transport. Its level-set color kernel sums inverse-distance-weighted colors, unlike ordinary gather averaging; define and test zero-distance behavior explicitly. Calling ordinary gather after quantization is not complete parity. |
| Strided conversion/scatter | Current converter reads byte/ushort/float/software-double into float4 and provides U16 quantization. The public arbitrary source/destination encoding, offsets and strides remain incomplete. Scatter's central/six-neighbor stencil and color-averaging modes need explicit mapping; legacy `amp` is passed but unused in its kernel, so an amplitude correction must be documented as a behavior change. |
| Solid voxelization | Validate finite vertices, indices, bounds, format and transform; preserve surface/inside values and sparse placement. Direct GPU activation is a future optimization if the initial public path uses the existing CPU topology conversion. |

Legacy subcell insertion copies/quantizes velocity attributes, but the three existing density/level-set gather kernels accept those buffers without reading them. Preserve transport where exposed; do not invent a missing velocity-gather solver to satisfy the old signature. `gvdbReadGridVel` and `gvdbCheckVal` are velocity sampling/diagnostic kernels. Additional exported kernels, including obstacle-node mapping and support deposition, need an entry-by-entry disposition in the final CUDA-source retirement inventory even where they have no `IGVDBPointOps` method.

## VBX transaction and metadata contract

Use the standalone parser/serializer as the source of truth; do not restore legacy unchecked reader behavior. Support its existing one-grid, uncompressed atlas layouts for VBX 1.0, 1.11+, and supported 2.x headers, normalized bitmask topology, and all five ordered channel formats. Preserve transform, grid name, voxel size, original slots and channel bytes. Sampler state and arbitrary application material metadata are not serialized by these files and must receive explicit defaults on load.

Load parses/validates all CPU data into a temporary object, checks the 32-channel/public device limits, creates/uploads a complete generation, then swaps it into the volume. Failure leaves the prior volume and output transform unchanged. Do not call dense `updateAtlas` on imported slot coordinates before preserving/remapping imported channel contents.

Save acquires one coherent topology/channel snapshot, ensures GPU-authored topology and channel work is completed, reads logical bytes in bounded chunks, then invokes `saveRawVBX`. It must not combine old host nodes with newer channel placement. The existing serializer's multi-grid behavior warns and loads only grid zero; the portable reader rejects multi-grid input. Keep rejection as a documented compatibility restriction until an explicit grid-selection API is implemented. Compression, topology reuse, and other layouts remain unsupported, rather than silently discarded.

## FLIP scope finding

No complete FLIP solver was found in the inspected legacy GVDB/sample sources. The legacy `fluid-surface/FluidSystem` and `sph_fluid_pool/SPHSolver` implement SPH density, pressure/viscosity forces, and leapfrog integration. GVDB's old particle source contains velocity attribute transport, `gvdbReadGridVel`, and a MAC interpolation diagnostic; it contains no particle-to-grid solver, pressure projection, or FLIP orchestration.

The portable `transferGridVelocity` utility now provides grid-to-particle PIC/FLIP blending and midpoint advection. Its header correctly states that it is not particle-to-grid transfer or a pressure solver. A complete FLIP solver would add new functionality and requires its own design and acceptance tests; it is not an M5 legacy-parity blocker. Preserve SPH as the migrated fluid samples' solver family.

## Disjoint implementation sequence

| Step | Primary files/ownership | Deliverable and dependency |
| --- | --- | --- |
| A. Freeze contract | New public API/types header draft, this plan, interface/header tests | Agree signatures, empty state, revisions, operation submission, error handling, and legacy build separation before parallel implementation. No changes to NVRHI core needed. |
| B. CPU core | New `GVDBHostVolume.*`, extracted shared types, allocator/topology CPU tests | Mutable pools and all CPU semantics, explicit validated pack/unpack, empty topology. Preserve legacy implementation as the comparison oracle. Can proceed independently of GPU storage after A. |
| C. NVRHI owner | New `GVDBNvrhiVolume.*`, shared internal snapshot/storage header, atlas relocation Slang | One device and hierarchy, all channels, generations, commit/fetch, uploads/readback and remap. Depends on A/B contracts. This owner controls shared internal header edits. |
| D. Voxel/serializer adapters | Separate NVRHI voxel operator and serializer files; existing portable shaders/parser reused | Channel-dispatch factories, custom programs, exact regional downsample, transactional VBX. Serializer CPU work can proceed with B; GPU publication needs C. |
| E. Point/voxelizer adapters | Separate point and voxelizer files, targeted subcell/FP16/conversion shaders | Public point streams, rebuild versus accumulate, gathers/scatter, mesh input and sparse publication. Depends on C snapshots and mutation API; do not edit C's internals concurrently. |
| F. Consumers and packaging | Scene transfer-function adapter, portable helper adapters, sample call sites, CMake | Move ownership consumers to unified volume; remove duplicated topology allocation; preserve sample visuals and controls. CPU target has no SDK dependency, runtime target links NVRHI/artifact support, Donut scene integration remains separate. |
| G. Reference retirement gate | Dependency/source inventory and platform CI, reference options | Production targets exclude gpdevice, Thrust, cudart, NVCC and handwritten CUDA kernels. Keep reference source under an explicit option until all accepted comparisons and required platforms pass. |

Avoid linking legacy and migrated definitions of the same GVDB interface/factory symbols into one executable. Initially keep a distinct production header/target while the legacy header/target remains intact; after adapters pass, switch the canonical production include and give reference builds a separate include root/target or namespace. Do not use a macro that gives one IID different vtables across translation units. Parent integration owns CMake target selection and final header promotion.

## Acceptance gates

These are proposed tests, not results from this design pass.

- CPU: node layout/IDs, pool growth and exhaustion, root growth, negative coordinates, extent truncation, active/inactive flags, halo, manual edits, clear/reuse, empty/single-leaf volumes, malformed references and arithmetic boundaries. Compare semantic trees and operation results; require byte/ID identity only where explicitly preserved.
- Ownership on D3D11/D3D12/Vulkan/CUDA: queue an operation, grow/repack/remove a leaf, record a second operation, release old handles/volume, then verify both results. Exercise operator reuse after ping-pong, renderer binding refresh, wrong-device inputs, invalid ranges, and failure without partial publication.
- Atlas: five distinct channel patterns; grow Z, change X/Y pitch, remove a middle leaf, reactivate it, reorder a full rebuild, add/destroy channels, and import non-dense slot maps. Check every surviving interior byte and independent apron expectations, R8 tail words/unaligned blocks, RGB32 stride, and unused-slot initialization.
- Operators: fixtures call the public factories rather than only helper classes. Cover format matrix, skip/update switches, empty/zero iterations, in-place source alias handling, all point encodings/strides, normalized-ushort weighted color including coincident points, and active-interior reductions.
- VBX: all-format/multi-channel load-save-load, legacy assets, bitmask normalization, transform/name/voxel-size/slot preservation, GPU edit then save, truncated/corrupt/overflow input, unsupported variants, and failure preserving an existing volume. Compare data/semantics, not compressed or canonicalized file byte identity.
- Sample integration: point fusion survives repeated topology growth without losing old scalar/color data; fluid reconstruction updates shared resources correctly; compute/RT consumers observe new generations; resample/voxelize and real-asset render captures remain within their independently recorded tolerances.
- Build/package: CPU-only host/VBX tests with GPU SDK discovery disabled; graphics-only runtime without CUDA/OptiX; static/shared public-header/QI/ABI consumer tests; packaged artifact execution without compiler libraries. Windows four-backend and Linux Vulkan/CUDA gates remain distinct; local hardware cannot prove Linux or real multi-GPU results.
- Diagnostics: native graphics validation and CUDA Compute Sanitizer on lifecycle/repack tests. Measure repeated-reconstruction allocations, memory and timings separately from correctness. Reject unexpected CI skips; describe unsupported formats/features explicitly.

## Review decisions before broad implementation

The recommended starting decisions are caller-owned command recording plus explicit synchronous orchestration for CPU-dependent topology phases; canonical raw channel storage; default pool-order placement with real remapping; immutable binding snapshots with resource revisions; and a separate reference build. Review these together with the draft public signatures in step A before assigning B-E concurrently.

The exact remaining work is public ownership/integration and the gaps enumerated above. Existing helper/compiler tests and migrated samples are valuable evidence, but they do not by themselves prove `IGVDBVolume` parity or justify deleting the legacy reference path.
