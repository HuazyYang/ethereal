# M5 Step A: additive NVRHI ownership contract draft

Status: review draft, 2026-10-18. This slice is intentionally outside checkpoint 4. It follows the [M5 ownership plan](2026-10-18-gvdb-unified-volume-ownership.md), and does not implement a replacement public volume, operators, GPU publication, or VBX serializer.

## Files and dependency boundary

- [GVDBNvrhi.h](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBNvrhi.h): concrete header-only data types, arithmetic/descriptor validation, immutable retained binding descriptions.
- [GVDBNvrhiContractTests.cpp](../../ethereal-samples/src/gvdb_samples/gvdb/tests/GVDBNvrhiContractTests.cpp): standalone CPU fixture, with no aggregate CMake integration.

The header includes only NVRHI's public API, standard C++ headers, and the existing SDK-free portable GPU layout header. It does not include `GVDB.h`, GPDevice, Donut, a sample `ComputeRuntime`, CUDA, OptiX, Vulkan or DirectX headers. There are no exported factories or new interface IIDs that could imply a working runtime implementation.

The draft uses `gvdb::portable` to coexist with the preserved `gvdb` legacy definitions. It deliberately avoids `gvdb::nvrhi`, which would change lookup of `nvrhi::` inside existing GVDB namespaces. Promotion of the public names and binary ABI is a later reviewed change. `c_DraftContractRevision` is a source draft marker, not a runtime version check.

## Decisions represented in the draft

| Concern | Concrete representation and limit |
| --- | --- |
| Node identity | Bitfield-free `NodeId` encodes group, level, and a checked 48-bit index. The all-ones reference is null. The new 64-byte `Node` preserves parent, child-list and mask offsets. These are new namespaced types, not casts of legacy objects. |
| CPU storage | Borrowed host pool views expose data/count/stride. Growth invalidates pointers. The future CPU core must validate edits before commit and preserve the documented legacy activation/extent rules. |
| Configuration | `LevelConfig` and its validator retain one to ten levels, log dimensions supported by the existing packer, and a signed 32-bit index-space extent bound. The checked `fromBranching(r4..r0)` helper preserves legacy nonpositive clamping and explicitly maps `r0` to the leaf. Capacity settings do not allocate anything. |
| Raw channels | All five existing formats retain byte strides 1, 4, 4, 12 and 16. `describeChannel` checks products before multiplication, returns logical bytes separately from four-byte physical padding, and enforces the current portable shader address range. Device allocation limits can be smaller. |
| Empty state | An unallocated atlas has all three dimensions zero; partial-zero shapes are invalid. Snapshot metadata defaults to a null root. A configured empty volume additionally requires zero active leaves, zero bounds, no live atlas references, and valid configuration. Existing shader entry guards and packer support remain to be implemented. |
| Boundary values | Channel outside/apron values use storage units: whole integer components in `[0,255]` (fractional values are rejected), finite float values. This does not change the existing normalized RGB *fill-operation* parameter semantics. |
| Resource ranges | `BufferView` retains an NVRHI buffer and uses an explicit byte length; zero is empty, never an implicit remaining range. Raw views require four-byte alignment, raw support, no structured stride, and UAV support when writable. |
| Point streams | Retained raw buffers have explicit offsets, strides, component encoding and count. Last-element validation uses subtraction/division to reject overflow. Format declaration does not claim every gather/conversion operator already supports it. |
| Revisions | Epoch, topology and placement revisions are distinct from channel allocation/content revisions. The checked increment helper rejects exhaustion. A recorded content revision does not indicate GPU completion. |
| Snapshots | `BindingSnapshot` copies metadata and retains the device plus all buffer handles, including up to 32 independently selected channels. It has no setters or assignment. Device is released after its buffer members. New volume publication cannot change an old snapshot's bindings; ordered writes can still change those buffers' contents. |
| Recording | `RecordingContext` borrows the actual NVRHI device/list for a call. It does not wrap, create, open, close or submit a list. Future operators validate available device/provenance information before recording; list openness remains a caller precondition because NVRHI exposes no open-state query. |
| CPU-dependent work | The documented sequence is GPU recording, caller submission/completion, explicit readback and CPU validation, host edit, recording upload/repack, and publication. No synchronous behavior is hidden behind a CPU getter. |

`BindingSnapshot` construction is a retention operation, not a validity certificate. Step B/C must validate the complete graph, dimensions, resource descriptors, same-device provenance and revision relationships before publishing it. In particular, the Step A fixture cannot prove resource lifetime across GPU submissions or cross-device rejection.

Canonical raw storage chooses a concrete direction for R32: current structured-float shader consumers need raw-load/store adapters when integrated. D3D11 cannot be assumed to accept simultaneous structured/raw buffer creation flags. Maintaining two unsynchronized representations or using typed CUDA buffers is not an acceptable adapter.

## Next seams requiring review before B/C

1. Keep these value types as the descriptor vocabulary, then add new queryable GVDB interfaces and C factories with new IIDs only alongside their implementations. Do not alter NVRHI core interfaces or reuse a legacy GVDB IID for a new vtable.
2. Implement the CPU owner and complete validation of empty/nonempty topology, pool references, host dirty state, and pack/unpack. The current alias to `slang::VolumeInfo`/`LevelInfo` avoids duplicate GPU layouts; shared layout promotion can move their definition without changing bytes.
3. Implement one NVRHI volume owner retaining the selected device and shared topology. It publishes snapshots only after every channel allocation/remap has been prepared successfully. Failed allocation or validation preserves the previous generation.
4. Define upload/readback and recording methods with explicit completion boundaries. Public getters return retained snapshots or borrowed host data with documented invalidation; they do not silently wait or launch work.
5. Add serializer/operator adapters and source-compatible convenience only after the owner has multi-channel repack, empty-state, revision and submission-lifetime tests on the selected APIs.

A final binary boundary should expose interfaces and fixed-layout descriptors rather than exporting the C++ `BindingSnapshot` value class as a DLL ABI. This draft makes no ABI-stability promise for `std::array`-containing value types.

## Validation performed

The standalone fixture compiled and ran with MSVC 19.44, C++17, including only `ethereal-nvrhi/include`; the original fixture linked no NVRHI, CUDA, OptiX, graphics or compiler library. The later real `IBuffer` descriptor mock additionally compiles NVRHI's CPU `src/core/memory.cpp` (or links `nvrhi_core` under CMake), because `BufferDesc::debugName` uses its allocator; it still needs no device/backend or GPU SDK. It passed reference encoding/overflow, field layout, level extent limits, all five channel byte layouts, R8 padding, empty shapes, large-range rejection, finite/byte boundary values, missing resources, explicit stream ranges, immutable metadata copying and revision exhaustion checks.

Reproduce from a Visual Studio developer shell at the workspace root:

```powershell
cl /nologo /std:c++17 /EHsc /utf-8 /W4 /wd4324 `
  /Iethereal-nvrhi/include `
  ethereal-samples/src/gvdb_samples/gvdb/tests/GVDBNvrhiContractTests.cpp `
  ethereal-nvrhi/src/core/memory.cpp `
  /Febuild/m5-contract/GVDBNvrhiContractTests.exe `
  /Fobuild/m5-contract/
./build/m5-contract/GVDBNvrhiContractTests.exe
```

Create the private output directory first. Warning C4324 is expected padding caused by the existing aligned GPU layout members. An additional clang-cl attempt was blocked before the draft header by the installed Clang 18.1.8/MSVC STL compatibility requirement (the installed STL requires Clang 19 or newer). No compiler installation or toolchain workaround was made.

No GPU run, aggregate build, API export, package integration, or production consumer migration was performed in Step A.


The subsequent [Step B CPU owner](2026-10-18-gvdb-host-volume-step-b.md) now implements and independently tests the topology-only boundary. Samples commit `b0e9af3` integrates its CPU module and tests; the subsequent GPU owner remains in progress.

## Step C preparation: agreed CPU/GPU seam

This section is design preparation outside checkpoint 4. No GPU owner, exported interface, production adapter, build integration or GPU result is implied.

The CPU implementation now exposes `HostVolume::packTopology(PackedHostTopology&)` in [GVDBHostVolume.h](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBHostVolume.h). It requires a finished, validated graph and preserves the output on failure. The owned export contains `VolumeInfo`, level records, raw node/child words, topology revisions and the active-leaf count. It intentionally contains no atlas map, channel data or placement revision. Step C must not submit that export directly to existing sampling kernels.

The NVRHI owner composes one `HostVolume` with channel descriptors and the current retained GPU generation. It obtains an owned packed copy, assigns active leaf atlas positions in pool order, and builds a slot map whose `AtlasNode.leaf` is the level-zero pool index. Placement modifies only this copy. CPU nodes remain unplaced (`atlasInterior == -1`) unless explicitly edited by an importer; their graph validator ignores placement. Placed node bytes in a published snapshot are the authoritative GPU metadata. A future legacy facade can expose an explicit placement view; publication must not silently write back into CPU pools.

Configured empty topology has a null root, zero pools/bounds and valid level descriptors. A graph containing allocated but entirely inactive leaves can retain its root. Both have active-leaf count zero: the owner publishes no live atlas, and recording skips atlas dispatches. It must neither invent a dummy active leaf nor divide by an empty atlas shape. Private dummy resources used to satisfy reflected bindings are not public live channel allocations.

## Minimal owner and transaction boundary

The first implementation belongs in new `GVDBNvrhiVolume.*`, a shared private generation header if needed, a new atlas-remap Slang source, and independent tests/CMake. It uses NVRHI, standard C++ and the portable GVDB headers only. The test harness may create backend devices separately; neither the owner nor its public header includes `ComputeRuntime`, Donut or native SDK headers.

The following are working operation seams, not a frozen DLL ABI:

1. Create an owner from an NVRHI device, configuration and offline artifact bytes. Retain the device and load the target-checked artifact through `nvrhiCreateShaderProgram`; find the compute entry and derive its layout through `IShaderProgram`. Filesystem/VFS convenience can remain an external adapter. No Slang compiler library is needed at execution time.
2. Edit/finish the composed `HostVolume`, edit channel descriptors, then `prepareGeneration(placement, uploads)` without recording GPU work. Preparation copies CPU uploads, validates the complete export and all arithmetic, checks revision exhaustion, determines placement and survivor mapping, and creates every buffer, constant buffer, pipeline and binding set. A failed preparation leaves the current published generation and every old channel unchanged.
3. Return an owner-issued prepared-generation ticket. It retains a unique owner identity tag, the base publication generation, prepared host epoch/topology revision, destination metadata/resources, previous sources and all dispatch objects. The identity tag is retained rather than comparing an owner object's address, preventing allocator address reuse from accepting an old ticket.
4. `recordAndPublish(RecordingContext, ticket)` validates identity, unused-ticket state, base generation and unchanged/finished host revision before any command. It records uploads/remaps into the caller's list and publishes the complete snapshot only after recording calls have been issued. The ticket is single-use. A stale ticket fails before recording; abandoning a prepared ticket releases its allocations without changing the volume.
5. Snapshot acquisition copies/retains metadata and resources, with no GPU work. Full-channel readback has explicit prepare/record/complete phases: the owner creates staging, the caller records/submits/waits using NVRHI, and a completion step maps the staging resource and returns logical bytes. A content revision is never interpreted as completion. Partial byte/row/slice upload adapters and GPU-authored topology fetch are follow-on operations, not implicit behavior of CPU getters.

Initial placement retains the legacy default 16 x 16 x 1 brick grid and configurable apron, with Z growing as needed. Tests use small explicit grids. Repacking may change X/Y pitch, compact active pool order or preserve compatible spatial leaves across a rebuild. An explicit preserve/discard policy distinguishes relocation from destructive reconfiguration; incompatible leaf interpretation must reject preserve mode instead of implicitly resampling. Channel format/storage changes increment the resource revision; recording writes increments content revision. Host topology and owner placement revisions remain distinct. A channel descriptor also has an internal incarnation token: deleting and recreating the same index/format starts with defaults rather than accidentally preserving the old channel. Survivor preservation requires the same incarnation, not merely the same numeric channel slot.

### Recording, provenance and failure limits

`ICommandList::getDevice()` and `getDesc()` allow rejection of a wrong device or a copy-only recording context. There is no public query proving a list is currently open; openness remains a caller precondition checked by normal NVRHI validation. The owner never opens, closes, executes or waits on the caller's list. Recording replaces compute state, so callers rebind their subsequent state normally. Caller submission order and cross-queue waits establish dependencies between generations.

Public `IBuffer` has no owning-device query. The first slice therefore publishes only allocations created by this owner and authenticated owner-issued tickets. It must not advertise arbitrary external buffer adoption as provenance-validated. Future external inputs need an explicit caller contract or a managed allocation/import path. Existing native interop remains the supported cross-device route.

NVRHI recording calls such as `writeBuffer`, `setComputeState` and `dispatch` return `void`. Atomicity covers validation, allocation, program/binding preparation and whole-generation publication; it cannot promise rollback of device loss, backend recording failures or previously recorded commands. No old allocation is used as a repack destination. Binding sets keep `trackLiveness=true`; recorded resources, constants, sources and pipelines follow NVRHI execution lifetime, while snapshots retain their device and allocation handles. Ordinary volume edits/destruction must not insert `waitForIdle`.

## Canonical raw relocation kernel

Use one channel per dispatch so the D3D11 baseline does not require 32 simultaneous UAVs. All five formats remain raw: R8_UINT, RGBA8_UINT, R32_FLOAT, RGB32_FLOAT and RGBA32_FLOAT have byte strides 1, 4, 4, 12 and 16. Buffers have `structStride=0`, raw views and UAV support. Structured-float consumers require an explicit raw-load adapter; simultaneous raw/structured flags and CUDA typed buffers are not a portability shortcut.

Each invocation owns exactly one complete destination 32-bit word. It resolves each of that word's four bytes independently, which handles R8 words crossing rows, slices or brick boundaries and preserves RGB32's 12-byte stride. It writes the word once, with no overlapping byte stores or atomics. Dispatch metadata includes word count and final valid-byte count so an allocation at the 4-GiB address boundary does not require representing 4 GiB in a single 32-bit byte-count field.

A destination leaf-index-to-old-atlas-interior table matches surviving leaves by signed world origin and compatible leaf configuration, never by pool index. For every destination interior/apron voxel, the kernel consults the new topology, resolves its active destination leaf, and uses that leaf's old-source mapping to read an old **interior** voxel. Newly activated or missing neighbors use the channel's validated void value. Thus removal/growth regenerates faces, edges and corners without copying stale old aprons or reading destination writes from another thread. Survivor payload bytes are copied without float conversion. Unused slots and physical tail padding are zero; active new interiors and missing-neighbor aprons use `voidValue`. This deliberately makes the previously broad unused-region initialization rule precise.

Topology nodes/children use raw buffers; level metadata and atlas maps retain their existing structured 64/16-byte records. Every reflected binding, including unused module globals, gets a prepared valid resource. Empty public buffers may use private dummy resources only for that binding requirement. Reflection verifies the expected resource types/registers/constant layout before pipeline creation; no positional CUDA argument ABI is introduced.

## Independent first-slice acceptance

The minimum GPU fixture executes through this owner on D3D11, D3D12, Vulkan and CUDA, without sample `ComputeRuntime`:

- Upload five distinguishable per-leaf/per-voxel/per-component byte patterns, including nonbinary RGBA, RGB32's third component and R8 tail bytes. Verify logical bytes and deterministic padding independently on CPU.
- Grow Z, change X/Y pitch, remove a middle leaf, reactivate it, and rebuild the same signed spatial leaves in a different pool order. Check every surviving interior byte, new-leaf defaults, zero unused slots and independent face/edge/corner apron expectations.
- Exercise empty configured, allocated-but-inactive and single-leaf graphs. Publish empty then reactivate a slot and prove old bytes do not reappear. Check inactive nodes have no atlas position. Delete and recreate a channel at the same index/format and verify its old content is not inherited.
- Record work using generation A, prepare/publish B, then release the owner and old application handles before submission/completion. Readbacks of both generations must retain their original bindings and data. Reusing an operator must acquire B rather than a cached raw pointer from A.
- Reject wrong-device/copy-only contexts, wrong-owner/stale/reused tickets, invalid ranges/configurations, malformed artifacts and revision exhaustion before publication. Inject a preparation allocation/budget failure after some channels have been allocated and verify that none of them replaces the previous generation.
- Run native graphics validation and CUDA Compute Sanitizer on relocation/lifetime cases. Build a graphics-only consumer with CUDA discovery disabled and verify offline artifact execution without compiler libraries. These are proposed gates, not completed results.
