# M5 Step B: CPU topology owner

Status: implemented draft, independently CPU-tested on 2026-10-18. This slice remains outside checkpoint 4. The standalone module is registered in the aggregate; samples commit `b0e9af3` records this slice. It follows the [ownership plan](2026-10-18-gvdb-unified-volume-ownership.md) and [Step A contract](2026-10-18-gvdb-nvrhi-contract-draft.md).

## Files and usable boundary

- [GVDBHostVolume.h](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBHostVolume.h) and [GVDBHostVolume.cpp](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBHostVolume.cpp) implement `gvdb::portable::HostVolume`.
- [GVDBHostVolumeTests.cpp](../../ethereal-samples/src/gvdb_samples/gvdb/tests/GVDBHostVolumeTests.cpp) supplies independent CPU semantic and failure tests.
- [GVDBNvrhi.h](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBNvrhi.h) now includes checked `LevelConfig::fromBranching(r4,r3,r2,r1,r0,out)` and rejects fractional integer channel defaults.

The owner uses standard CPU allocation and NVRHI result/value types. It includes no legacy `GVDB.h`/GPDevice, Donut, sample ComputeRuntime, native graphics SDK, CUDA or OptiX header. The host fixture links no NVRHI or GPU runtime binary. The contract fixture's real buffer-descriptor mock additionally needs NVRHI's CPU allocator implementation (`src/core/memory.cpp` privately, `nvrhi_core` in the aggregate). There are no new exported factories, reused legacy interfaces, casts between old/new objects, or changes to NVRHI core APIs.

The mutable owner supports configuration, capacity reservation, typed node and child-list pools, manual edits, activation to a selected level, root promotion, allocated/active lookup, explicit validation/commit, bounds, revision tokens, legacy extent calculation, clearing with capacity retention, region/mask/value/halo batches, and an owned packed topology export. It is single-threaded; clients synchronize access externally.

## Configuration and preserved semantics

`fromBranching` takes root-to-leaf arguments, explicitly assigning `r0` to level zero. Nonpositive values retain the legacy clamp to one. Unsupported positive dimensions and accumulated extent overflow fail and clear the output. Initial capacities remain leaf-first `4,4,2,1,1`. A compile-time and runtime regression proves `r0=5` produces leaf width 32, preventing the recently corrected sample adapters from repeating the argument-order error.

Direct `LevelConfig` accepts one to ten leaf-first levels, with checked power-of-two ranges. A zero initial capacity is normalized to four. Per-pool reservation budgets and the portable 4-GiB addressing bound are checked before allocation. Node records remain 64 bytes; child references remain 8 bytes. Borrowed views report used count, never reservation size.

Point activation floors finite coordinates before conversion. The separate `computeExtents` operation preserves the retained implementation's float division, subtraction of one in float for the upper extent, and truncation toward zero. These rules intentionally differ for negative and sub-cell bounds. Child slots are x-fast. Positive-only and negative-only canonical activation preserve the retained allocation order, parent links, positions and IDs.

The new API names distinguish allocated topology from activity flags: `isAllocated` follows a leaf's presence, while `isActive` additionally checks its nonzero flag. Retained `IGVDBVolume::isActive` actually tests allocation; a future legacy adapter must map that call to `isAllocated`. Activating an already allocated inactive leaf returns its existing ID without silently changing the flag. Bounds and active-leaf counts use flags, matching retained atlas membership.

## Intentional legacy corrections

Two invalid-input paths are corrected rather than copied:

1. Canonical floor-aligned legacy roots cannot span negative and nonnegative coordinates. Growth first prefers the legacy global origin; when necessary it selects an origin compatible with the old root's grid. The new parent contains the **whole previous root extent** and the requested point. This preserves earlier shifted subtrees and all node IDs. Sufficient configured levels are still required; a fixed maximum root is not silently moved or rebuilt.
2. Requesting a higher stop level for a point inside a leaf explicitly creates ancestors. The retained recursion could descend below level zero in that case. Promotion creates no redundant leaf and preserves existing IDs.

Failure to find a representable parent within configured levels returns `FE_UNSUPPORTED` with no logical mutation. Origins and exclusive upper bounds must fit signed 32-bit index space. This CPU range does not promise that every coordinate is representable by the current float-based GPU traversal metadata: Step C must validate that domain before publication.

## Transactions, borrows and revisions

Single-point activation stages growth under a bounded allocation-free undo journal. Region and halo batches use a dynamically sized journal for existing nodes/slots; each journal allocation occurs before the corresponding mutation, so its own allocation failure also rolls back the batch. Existing records and child slots are saved by ID, so pool relocation does not invalidate rollback references. Any validation, range, or allocation failure restores used counts, old records, parent links, root, dirty state, revisions and previously committed bounds. Reservations may remain larger after failure. Therefore any attempted growth can invalidate borrowed pointers even when logical state rolls back; IDs remain stable.

Manual node/list/pool access marks the topology dirty. A mutable borrow expires at the next topology commit: callers must reacquire through an edit method before modifying another generation. `finishTopology` checks record levels, valid origins, root ownership, reciprocal links, correct child-cell positions, correct child-list levels, unique ownership of every allocated list, and complete connectivity. Strict decreasing levels exclude cycles. Cross-level child lists are rejected before indexing, including lists whose allocation is smaller than the parent's slot range.

A successful finish recomputes active bounds/count and advances the topology revision, including an unchanged explicit finish. Configure and clear also advance the epoch, invalidating old IDs even when subsequent allocations reuse their bits. Overflow fails instead of wrapping. `reserve` changes capacity without changing logical revision. Step B does not advance placement revisions.

Manual edits are not transactions: a failed finish leaves those edits dirty for the caller to repair, while keeping the last published bounds/count/revision. `validate` reports their validity without publishing. This is distinct from automatic activation's strong logical rollback guarantee.

## Region, masks, values and halo

The new region methods take validated `CellExtents`, explicit source element counts for masks/values, and an output `uint64_t selected`. They activate level `extents.level-1` in z/y/x loops with x varying fastest. The selected count includes cells already represented by nodes, rather than counting only new allocations. Level-zero and empty extents are successful no-ops. Resolution, inclusive index bounds, cell width, total count, and cell-to-index multiplication are checked before traversal. Nonempty missing/short source spans fail without mutation.

Masks select any nonzero byte. Values use the exact strict `value > threshold` comparison: equal values and NaNs do not pass a finite threshold, positive infinity does, and a NaN threshold selects nothing. The CPU helper deliberately preserves this IEEE behavior rather than imposing an unrelated finite-data rule. Selections are resolved into tags before pool growth, so an input span may borrow existing host pool bytes safely for the duration of the call.

Halo tags all candidates before changing topology. It considers exactly six face neighbors, including neighbors outside the requested extent, and then activates tagged cells in the same x-fast order. Newly created cells cannot propagate another ring in the same call. Lookup uses allocated leaves, including `flags==0`, matching retained `IGVDBVolume::isActive`. At higher levels this means **leaf presence at the sampled cell origin**, not occupancy anywhere in a parent cell: a parent without a leaf at its origin does not become a halo source. Repeated higher-level calls may therefore select an already allocated parent again; the selected count preserves that behavior. Neighbors outside signed 32-bit index space are absent rather than wrapping.

Every batch has all-or-nothing logical behavior. If any later activation exceeds configured root extent, pool budget, or available memory, all earlier activations in that batch roll back and `selected` is zero. This intentionally corrects the retained methods' silent partial-success counts. Previously committed bounds/revisions stay unchanged; successful batches only mark topology dirty and still require `finishTopology`. Reservations may grow even after rollback, so callers reacquire pool pointers.

## Empty state and the Step C seam

`packTopology(PackedHostTopology&)` requires a finished graph, validates it again, and replaces the output only after successful preparation. The export owns its node and child words plus level records, bounds, root metadata, revision and active-leaf count. It survives clearing or destroying the mutable owner. Combined offsets and byte lengths are checked for portable addressing.

A configured cleared owner exports valid level descriptors, null root index `UINT32_MAX`, zero pool words, zero bounds and zero active leaves. It never invents a fake leaf. An allocated but entirely inactive graph may retain its root and node records while still reporting zero active leaves. Step C gates atlas allocation and dispatch on the active count in both cases.

This export is deliberately **not** `slang::PackedVolume`. It has no channel bytes, atlas map, or assigned placement, and must not be submitted directly to current sampling shaders. CPU nodes initialize `atlasInterior` to `(-1,-1,-1)` and remain unplaced unless explicitly edited by an importer. Step C obtains an owned packed copy, assigns placement in that copy, and builds atlas-map entries whose `leaf` field is the level-zero pool index. The GPU snapshot is authoritative for placement; publication does not secretly mutate CPU pools. GPU channel ownership, survivor remapping and placement/content revisions remain in the separate owner.

## Validation performed

MSVC 19.44 C++17 normal and AddressSanitizer builds passed. Independent checks cover:

- Fixed positive/negative allocation-order goldens, pool IDs, parent origins, x-fast links, bounds and exact packed offsets.
- Signed cross-zero growth through multiple shifted roots, preservation of earlier leaf IDs, and same-position higher-level promotion.
- Configured maximum-extent rejection and an injected per-pool budget failure after a new root and old-root path were prepared; rollback restores all earlier records and links.
- Reservation growth, failed reconfiguration, clear/capacity retention, epoch changes, record reinitialization and canonical empty export.
- Manual malformed geometry, reciprocal links, duplicate children, wrong-level/smaller child lists, inactive/active lookup and publication refusal before commit.
- Legacy truncating extents, nonfinite/out-of-range input, signed coordinate endpoints, and 800 deterministic signed points checked against an independent floor-grid map.
- Snapshot byte ownership after source clear and the Step A branching-order/fractional-byte/point-stream descriptor regressions.
- X-fast 2 x 3 x 2 region order; independent threshold indices 1, 4 and 9; equal/nextafter/NaN/infinity comparisons; nonboolean masks; explicit source-length and malformed extent rejection.
- Simultaneous six-face halo counts 6 then 18; absent diagonal/corner propagation; shared gaps; signed neighbors; inactive sources; neighbors outside the extent; and higher-level leaf-origin behavior.
- Whole-batch region and halo failure after earlier successful cells, a 256-leaf batch exhausting a 200-node budget after more than 30 existing parents were touched, and selection spans borrowing a node pool that grows during the call.

AddressSanitizer reported no errors. A second agent independently reviewed growth, graph connectivity and rollback; its mutable-borrow finding is resolved by the explicit commit lifetime contract and defensive traversal checks.

From a Visual Studio developer shell at the workspace root, with `build/m5-contract` already created:

```powershell
cl /nologo /std:c++17 /EHsc /utf-8 /W4 /wd4324 `
  /Iethereal-nvrhi/include `
  ethereal-samples/src/gvdb_samples/gvdb/GVDBHostVolume.cpp `
  ethereal-samples/src/gvdb_samples/gvdb/tests/GVDBHostVolumeTests.cpp `
  /Febuild/m5-contract/GVDBHostVolumeTests.exe /Fobuild/m5-contract/
./build/m5-contract/GVDBHostVolumeTests.exe
```

For memory instrumentation, add `/fsanitize=address /Zi` and use the executable name `GVDBHostVolumeTests-asan.exe`. Private logs are `build/m5-contract/GVDBHostVolumeTests-build.log`, `GVDBHostVolumeTests.log`, `GVDBHostVolumeTests-asan-build.log`, `GVDBHostVolumeTests-asan.log`, and `GVDBNvrhiContractTests.log`. C4324 suppression covers expected aligned portable GPU metadata padding.

## Proposed integration and remaining scope

[GVDBHostVolume.cmake](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBHostVolume.cmake) defines the CPU-only `gvdb_host_volume` static target and build alias `gvdb::host_volume`. It accepts NVRHI header includes from the existing `nvrhi` target or an explicit `GVDB_NVRHI_INCLUDE_DIR`; the host target does not link NVRHI or discover native SDKs. The descriptor fixture links only `nvrhi_core` when present, or compiles its CPU allocator source for a standalone source-tree test. `BUILD_TESTING=OFF` omits fixtures. Otherwise the targets are `gvdb_host_volume_tests` and `gvdb_nvrhi_contract_tests`, registering `gvdb_host_volume` and `gvdb_nvrhi_contract` CTests. The descriptor fixture needs only the CPU allocator and the host fixture links only the CPU static target.

The integration line from `src/slang_compute/CMakeLists.txt` is:

```cmake
include("${CMAKE_CURRENT_SOURCE_DIR}/../gvdb_samples/gvdb/GVDBHostVolume.cmake")
```

A fresh standalone Debug configure/build passed both CTests without SDK discovery; logs are `build/m5-contract/cmake-{configure,build,test}.log`. The root agent registered the module and built both targets in the isolated graphics-only configuration. Both integrated CTests pass (0.28 seconds) with CUDA Toolkit discovery disabled; results are `build/m5-host-graphics-tests.log` and `build/graphics-only/m5-host-tests.xml`. Step C's owner can include the guarded module and link `gvdb::host_volume`. Package exports and a stable interface/factory boundary require separate review.

This is the first CPU ownership slice, not full legacy public API parity. Removal/compaction policy, host unpack/import, GPU-authored topology fetch, channel ownership, partial transfers, VBX serialization, operator factories and legacy convenience adapters remain later tasks. Existing `GVDBPortableData.cpp`, production kernels, sample adapters and legacy sources are unchanged by this slice; aggregate CMake adds the CPU module include.
