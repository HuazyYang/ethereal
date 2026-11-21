# RDG design versus the legacy framegraph: evaluation

- Date: 2026-10-21
- Design evaluated: [`rdg-design.md`](rdg-design.md) (Draft, 2026-10-21)
- Legacy: `ethereal-rdg-experimental-deprecated.tgz`, the `framegraph` branches archived on
  2026-10-14. Heads: donut `34ea046`, nvrhi `13b60ff`, samples `d2eee6f`, aggregate `6130bc1`.
  The archive also holds the legacy production record, `doc/plans/2026-10-12-rdg-production.md` in
  donut, cited below as PLAN.

The legacy was a working implementation:
- about 18k lines of graph code and 9k lines of tests;
- eleven donut ADRs;
- four ported samples (`deferred_shading_fg`, `variable_shading_fg`, `async_compute_fg`, and VXGI
  behind `-framegraph`).

**Every legacy measurement was taken on Linux, Vulkan, on one RTX 5070 Ti.** The D3D12 and D3D11
paths were "compiled by inspection only" (PLAN:1130).

## 1. Summary

**Where the new design is better.** It is better wherever the graph decides barriers, because the
legacy decided almost none: it called `setTextureState` per slot and left the choice to the nvrhi
tracker. It is also better in:
- cross-queue synchronisation;
- executor cost per frame;
- integrating passes without a parallel set of adapter classes;
- proving plans correct.

**Where it is worse.** The legacy shipped several things the design leaves out or under-specifies:
- what happens across the **frame boundary**: aliasing, cross-queue hazards and state hand-off;
- **opaque pass bodies** that change states internally;
- the **pass lifecycle** around parallel recording;
- **graph features** such as conditional passes and view groups;
- **debug and bisection tooling**.

On top of that, two parts of the design are defective as written: its interface header breaks
nvrhi's COM ABI rule R1, and its worked example (6.11) uses a state that the D3D12 compute queue
cannot hold.

## 2. Better in the new design

| Area | Legacy | New design | Why the new design is better |
| --- | --- | --- | --- |
| Transition granularity | One `TextureSubresourceSet` per slot. Iterated per-view slices are widened to the whole array (`FrameGraphExecute.cpp:524-544`). Edges are per resource version. The cross-frame record holds one state per resource (`:494-520`, `:805-813`) | Interval map over plane × mip × slice (5.3, 6.2) | Mixed per-mip end states and plane-separate access become possible |
| Planes | none | `SubresourceRegion` with a Color/Depth/Stencil mask (5.3, 8.2) | Stencil writes no longer transition the depth plane |
| Read merging | Unions reads within one pass only, and not on Vulkan (`FrameGraphExecute.cpp:948-995`). On D3D12 it can produce ShaderResource\|DepthRead, the combination that asserts on the enhanced path | Read-epoch lattice per backend (6.3) | Merges across whole epochs, and the D3D12 enhanced mapping is explicit |
| Who emits barriers | The nvrhi tracker, with automatic barriers on | Prebuilt `barriers()` arrays; Native mode turns automatic barriers off (8.2, 9.1) | One RHI call per slot. `RelaxedOrder` becomes possible: the legacy `DisableUavBarrierOpt` was reserved and did nothing (`Types.h:430-434`) |
| Split barriers | none (legacy ADR 0008) | 6.4 | |
| Discard | Only through aliasing; new resources relied on Common→UNDEFINED | Inferred discard-before and discard-after (6.6) | |
| Barrier correctness | No verifier: nvrhi decided the barriers | Device-free `VerifyPlan`, golden barrier lists, a reason on every barrier (11.1, 11.3) | |
| Cross-queue primitive | `queueWaitForCommandList` before each execute. D3D12 asserts that the producer was already submitted; Vulkan attaches the wait to the *next* submit (`FrameGraphQueues.cpp:998-1045`) | Timeline `IFence`, with waits and signals inside `submit` (8.3) | Both traps are gone by construction, and the same fences retire frames |
| Retirement | One `IEventQuery` per queue per retired set (`FrameGraphAllocator.cpp:560-640`) | Fence values (9.1) | No query-object churn |
| Vulkan queue families | `Shared_CrossQueue` makes images `CONCURRENT` (nvrhi ADR 0009) | `EXCLUSIVE` with release/acquire (6.8) | Keeps compression. Not yet proven: see 3.1 |
| Heap classes | A tier probe at startup (`FrameGraphAliasing.cpp:85-117`) | Heaps per heap class (7.5) | D3D12 tier 1 is `ALLOW_ONLY_RT_DS_TEXTURES` on slang-next (`d3d12-device.cpp:1232`) |
| Executor cost | Per-slot state calls and per-frame allocations (`FrameGraphExecute.cpp:171,178,234,465,770-818`). Allocations were never measured | Zero allocations, zero `create*` calls, prebuilt arrays (10.1, 10.3) | Legacy VXGI spent 54 µs for 9 passes; at that rate 64 passes exceed the 0.2 ms budget, so prebuilt arrays are needed |
| Pass integration | 11 adapter classes, about 4.4k lines, one registration per object (`framegraph/passes/`) | `IGpuPass` on every pass, several uses per object (13) | No duplicate class tree. The per-call refactors are still needed; the legacy already made them for TAA, ToneMapping, SSAO and Sky |
| Plan reuse | One retained plan with invalidation bits | Plan cache keyed by structural hash (7.7) | More general. But see 3.4 for its cost |
| Persistent state | Keyed by object pointer, with a keep-alive against address reuse (`FrameGraphExecute.cpp:169-189`) | Named registry entries (5.2) | Must be kept per subresource and per physical texture (3.3) |
| Backends | Vulkan measured; D3D12 and D3D11 inspected only; no CUDA | Four profiles, each verified (9.2) | |

## 3. Worse in the new design

### 3.1 Correctness gaps (must fix before acceptance)

1. **Cross-frame aliasing donor.** The first occupant of a heap range in frame N+1 needs an aliasing
   barrier against the last occupant in frame N. The legacy found this bug and fixed it
   (`Placement.cpp:255-329`, `FrameGraphExecute.cpp:715`, legacy ADR 0009). Design 6.7 considers
   only earlier placements in the same frame.
2. **Cross-frame, cross-queue write-after-read.** The first segment on each queue that touches a
   cross-queue resource must wait for the other queues' last submit of the previous frame. Without
   that wait, the D3D12 debug layer reported "in-flight on another queue"
   (`FrameGraphQueues.cpp:1015-1039`). Design 6.8 orders producer → consumer within one frame only.
3. **Frame-boundary state hand-off.**
   - Design 5.2 leaves a persistent resource in its last-use state.
   - When the next frame's first user is on another queue, that state can be illegal there.
   - The legacy got 10 VUIDs per 120 frames from a fragment-stage `srcStageMask` on the compute
     queue before it added a legality check at the wrap (`FrameGraphQueues.cpp:226-317`,
     PLAN:285-299).
4. **The 6.11 example contradicts 6.8.**
   - On D3D12 the compute queue cannot hold DepthRead or PixelShaderResource
     (`FrameGraphQueues.cpp:85-95`), yet 6.11 picks DepthRead\|ShaderRead "across both queues" for
     async SSAO.
   - Vulkan stage masks are queue-restricted too, so the per-queue lattice must cover stages as well
     as states.
   - The queue-legality table is also incomplete. The compute queue additionally forbids
     index/vertex buffers, resolve, shading-rate source and stream-out. The copy queue allows only
     Common and Copy*, and the design never mentions it.
5. **Vulkan clears.**
   - `vkCmdClear*Image` needs `TRANSFER_DST`. The legacy had to re-declare states after clears
     (`FrameGraphExecute.cpp:922-945`, legacy ADR 0007).
   - Design 6.9 lowers Clear to `clearTextureFloat` with automatic barriers off. The plan must
     therefore model a clear as a CopyDest access with transitions around it, or clear inside the
     render pass.
6. **Opaque bodies in Tracked mode.**
   - SSAO, MipMapGen and ToneMapping write a UAV and then read it as an SRV inside one body.
   - Design 9.1 only *reports* such changes, and only in validation builds. In release builds the
     next plan barrier then carries a wrong `before`.
   - The legacy restored the declared states after the body (`OpaqueExternal`,
     `FrameGraphExecute.cpp:1159-1219`). VXGI-style SDK bodies need the same.
7. **The interface header breaks nvrhi's COM ABI rule R1.**
   - `ethereal-nvrhi/doc/com-interface-abi.md` sections 3.2 and 3.3 forbid passing or returning a
     struct by value through a virtual function.
   - The design's `IPassBuilder` and `IRenderGraphBuilder` pass and return `ResourceId` by value.
   - The legacy used enum ids for this reason (`Inspector.h:29`). It also linted the graph headers
     with `abi_lint --api-all` and evolved interfaces through `IFoo1` versions; the design states
     no evolution rule.
8. **The aliasing validation cannot be written as specified.**
   - Design 8.2 validates that aliased resources are in "the same heap", but nvrhi exposes no way to
     ask which heap a resource is bound to.
   - The legacy added `ITexture1/IBuffer1::queryHeapBinding` and checked byte overlap, with nine
     tests (nvrhi patch lines 583-680, `tests/heap-binding.cpp`).
9. **D3D12 discard rules.**
   - `DiscardResource` requires the resource to be in a particular state.
   - Whether a placed resource needs initialising depends on its `ALLOW_RENDER_TARGET` and
     `ALLOW_DEPTH_STENCIL` flags, not on its first access. The legacy skipped the discard for
     UAV-first resources, which leaves a UAV+RT texture uninitialised.
   - Design 6.6 states neither rule.
10. **Alias sync scope and tracker reset.**
    - The legacy used a full first scope (`SYNC_ALL`, `eAllCommands`), because a "Common" transition
      waits for nothing.
    - It also reset the incoming resource's tracker state and forbade `keepInitialState` on aliased
      resources.
    - Design 6.7's "the old resources' last stages" must stay a superset of every stage those
      resources used, and it states neither the reset nor the restriction.

### 3.2 Under-specified mechanisms

- **History pairs.**
  - The legacy swapped the physical objects every frame, unioned the usage flags of both halves,
    and made `wasSlotReallocated` true for exactly one frame (legacy ADR 0010).
  - The design says none of this.
  - Design 10.1 also says persistent pointers are "fixed in the plan", which contradicts a pair
    that rotates.
- **Pass lifecycle.**
  - The legacy had `createPipelines`, `bindResources`, `prepare` and `onResourcesReleased`
    (`Pass.h:87-119`). It also had a rule that `prepare()` may not write a volatile constant
    buffer, enforced by an upload guard.
  - The design has only `Setup` and `Execute`, and `Execute` "may run on a worker thread". So there
    is no serial place to create pipelines, which dominated the legacy's 3.7–6.2 ms first compile
    (PLAN:480). There is also no hook to drop pass caches that pin pooled memory.
- **Parallel recording readiness.** The legacy audited the thread safety of donut helpers. It
  changed `BindingCache` to create outside its lock (option B, with concurrency tests) and guarded
  `CommonRenderPasses::BlitTexture`. The design assumes this has been done.
- **Pooling.** The legacy specified its pool key: the clear value is in it; `debugName`,
  `initialState` and `keepInitialState` are not. Ties break by declaration index, so binding caches
  keep hitting (`detail/ResourcePool.h:47-109`). Design 7.5 states neither the key nor determinism.
- **Extracted and persistent resources.**
  - The legacy's Exported residency stayed poolable. Design 5.2 forces extracted resources into
    dedicated memory.
  - The design has no persistent *buffer* call, although the exposure buffer needs one (legacy
    ADR 0010:99).
- **D3D11 before 11.4.** `IFence` is `FE_UNSUPPORTED` there, so retirement needs an `IEventQuery`
  fallback.
- **Host-kept imports.** The design should say that the graph never drives nvrhi's tracker for a
  host-kept resource. nvrhi's restore at `close()` depends on that.

### 3.3 Missing features

- **Conditional passes.** The legacy had `setPassEnabled`, which costs O(1) on a superset plan, with
  a policy per output when its pass is disabled (white AO, passthrough, or cull the consumers). It
  also had exclusion groups (legacy ADR 0004).
  - In the design a toggle is an `if`, so it changes the structural hash and forces a recompile.
  - Every cached plan keeps its own heaps (6.7), so heap memory grows with the number of cached
    plans.
- **View groups.** The legacy ran a subgraph once per view of an `ICompositeView`, which gave stereo
  and cubemap rendering, and folded the per-iteration temporaries into one allocation. The design's
  only answer is to call `AddToGraph` several times.
- **Runtime debug and bisection switches.** The legacy had:
  - `ForceCommitted`, a bit-exact reference;
  - `NoAliasing` and per-resource `NoAlias`;
  - `BarrierAfterEveryPass`, `FillTransients`, `SerializeQueues` and `StrictValidation`;
  - fault injection with `SkipAliasingBarriers`, for negative tests.

  The design keeps only "Dedicated: a debug option".
- **Tier choice.** The legacy made placed resources opt-in, probed for support at startup, fell back
  with a warning, and estimated placement from the plan on every backend.
- **Tools.** The legacy had:
  - an ImGui visualizer with lifetime bars and pass toggles;
  - per-pass GPU timers;
  - `RunStatistics`, `-stats` and `-recompile N`;
  - deterministic runs (`-fixedstep`, `-frames`, `-screenshot`) and `ab_compare.py` for pixel-exact
    A/B against the original sample;
  - ten device test suites run under three recorders.
- **Sample coverage.** The design ports `deferred_shading` only. The legacy also covered variable
  shading, async compute and VXGI.

### 3.4 Budgets that need correcting

| Budget (10.3) | Legacy evidence | Assessment |
| --- | --- | --- |
| Peak transient ≤ 60 % on the deferred frame | Measured 100 % on all three samples, because everything is live at the lighting pass. Tier 1 saved 0.6 %, 0.7 % and 0 %. 70 % of `variable_shading_fg` memory was history (PLAN:484-485, 546-564) | **Infeasible as written.** Measure over poolable resources, on a graph that has reusable transients (bloom, SSAO chain) |
| Compile miss ≤ 1 ms for 64 passes | 41 µs (105 µs cold), device-free (PLAN:479) | Safe; could be tightened |
| Cache hit ≤ 0.05 ms | The legacy rebind cost 0–1 µs, with no per-frame recording | Recording every frame is new cost; measure it |
| Executor ≤ 0.2 ms | VXGI 54 µs for 9 passes through the tracker | Only reachable with prebuilt barriers (Native mode) |
| GPU and CPU time ≤ original | Within ±1.1 % on all samples | Achievable |
| Parallel recording | Pays off from 16 passes. At 64 passes: 91 µs on one list vs 50 µs with 4 ranges on 4 threads. About 1.4 µs per pass plus 0.7 µs per range; capping ranges at the thread count is best. A range costs 25 µs without `runGarbageCollection` (PLAN:765-800) | Use as the design's crossover rule |

The legacy also found an inflated-savings bug: `naiveBytes` once counted imports, which showed a
false 1.11× saving. The design's plan statistics must exclude imports.

### 3.5 Redundancy

Design 7.4 widens the lifetimes of cross-queue resources, and 7.5 also never aliases them. One of
the two is redundant. The legacy simply excluded cross-queue resources from aliasing
(`Lifetime.cpp:168-174`).

## 4. Equivalent

- **Import contract:** the legacy's `ImportKind{HostTracked, StateDeclared}`, with misuse as a
  compile error (legacy ADR 0009), matches design 5.2.
- **Placement:** both sort by size and place first-fit; the legacy breaks ties deterministically.
- **Scheduling:** both use maximal same-queue segments and one wait per other queue, with transitive
  reduction.
- **Versioned writes and anti-dependencies:** the legacy has explicit write-after-read edges; the
  design has WAR barrier reasons and verifier hazards. An explicit edge is needed once async passes
  are reordered.

## 5. Facts in the design's section 2 to correct

- **Vulkan `Common`** maps to `UNDEFINED` with an empty first scope. It therefore waits for nothing
  and leaves a write-after-read hazard, not only an implicit discard (legacy ADR 0002:159-172).
- **Vulkan memory binding:** `bindImageMemory` and `bindBufferMemory` ignore the bind result and
  always report success. This is still true on slang-next (`vulkan-texture.cpp:412`,
  `vulkan-buffer.cpp:689`).
- **Vulkan queue families:** donut's `DeviceManager_VK::findQueueFamilies` never resets its family
  indices between physical devices. This is still true on slang-next (`DeviceManager_VK.cpp:585`,
  with indices initialised once at `DeviceManager_VK.h:232-235`). It caused the legacy's device loss,
  because compute lists came from a transfer-only family. The fix branch was never merged.
- **Earlier aliasing work:** the legacy already built aliasing barriers (`ICommandList1`), heap
  binding queries and `CONCURRENT` sharing in nvrhi, and bumped the header from 28 to 31. 2.1 is
  right about slang-next, but should cite this earlier work.
- **Vulkan sampled depth:** nvrhi binds sampled depth as `ShaderResource|DepthRead` on Vulkan, and
  needs exact pixel/non-pixel shader-resource states on D3D12 (legacy ADR 0009:178-187). Tracked
  passes must declare exactly these states, or the tracker cross-check (11.2) fires on every
  wrapped pass.

## 6. Legacy defects not to copy

- `canReuse` returns true for resources in different exclusion groups before it checks the queue
  mask (`Lifetime.cpp:165-174`).
- `releasePlaced` drops heaps and placed resources without retiring them
  (`FrameGraphAliasing.cpp:425-434`). It relies on command lists holding references, which native
  `barriers()` arrays may not do.
- Legacy ADR 0002 says there is one heap per queue; the code creates one heap
  (`FrameGraphAliasing.cpp:271-278`).
- Linux Debug runs had no validation layers loaded, so "clean" results were vacuous (PLAN:110).

## 7. Recommended design changes

These follow from section 3. All twelve were applied to `rdg-design.md` on 2026-10-21 (its
section 14.8):

1. **New section: frame boundary.** It covers the previous-frame aliasing donor, the previous-frame
   cross-queue waits, and a legality check on state hand-off at the wrap.
2. **Fix 6.11 and 6.8.** Add a full per-queue legality table (states and stages, including the copy
   queue), and redo the async SSAO example.
3. **Model clears as accesses.** A clear becomes a CopyDest access with transitions, or a clear
   inside the render pass (6.9).
4. **Add a Restore mode** beside Native and Tracked (9.1). It returns a body's resources to their
   declared states, for opaque and SDK bodies.
5. **Make the header R1-compliant.** Ids become `uint64_t`, or are returned through out-parameters.
   Extend `abi_lint` and the header-hygiene test to `RenderGraph.h`, and state an `IFoo1`-style
   evolution rule.
6. **nvrhi additions.** Add a heap-binding query (`IResource::queryHeapBinding`) for byte-overlap
   validation. Check the result of Vulkan `bind*Memory`. Fix the donut queue-family reset in step 0.
7. **State the discard and alias rules.** Cover D3D12 discard states and flags, the full alias sync
   scope, the tracker reset, and the ban on `keepInitialState` for aliased resources (6.6, 6.7).
8. **Pass lifecycle.** Add a serial `Prepare` phase on `IGpuPass` for pipeline creation and uploads,
   and a resource-released hook. Carry over the legacy's upload-guard rule.
9. **Specify history pairs.** State the rotation, the union of usage flags and the one-frame
   `IsNewAllocation`. Add persistent buffers, and keep extracted resources poolable.
10. **Conditional passes.** Add `SetPassEnabled` on a cached superset plan, with output policies, so
    that toggles do not churn the plan cache. Bound the plan cache's memory.
11. **Debug switches and tooling.** Carry over `ForceCommitted`, `NoAliasing`,
    `BarrierAfterEveryPass`, `FillTransients`, `SerializeQueues` and `SkipAliasingBarriers`, the
    deterministic A/B tooling, and per-pass timers.
12. **Budgets.** Correct the memory budget (3.4), add the parallel-recording crossover rule, and add
    sample targets for async compute and variable shading.
