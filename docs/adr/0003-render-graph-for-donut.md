# 0003. A new render graph for donut on the ethereal-dev RHI

- Status: Accepted (2026-11-05)
- Date: 2026-10-21; rebased onto ethereal-dev on 2026-11-01

## Context

donut composes frames by hand. Each sample owns its render targets, calls passes in statement order and
relies on nvrhi's automatic barriers. That leaves three gaps:

- **Barriers cost more than they need to.** The nvrhi tracker never merges texture read states, so a depth
  buffer that is depth-tested and sampled costs several transitions per frame.
- **Transient memory is never reused.**
- **Lifetimes are hidden.** Some passes keep their own transients and history, where nothing else can see
  them.

The earlier design (`ethereal-donut/doc/RdgDesign.md`, 2026-10-12) made the unmerged `framegraph` branches
the production path. Those branches are no longer available locally. Its plan
([`plans/2026-10-04-framegraph.md`](../plans/2026-10-04-framegraph.md)) was never approved.

On `ethereal-dev` (nvrhi ADRs 0011-0014), ethereal-nvrhi now has:

- four backends: CUDA (with OptiX), D3D11, D3D12 and Vulkan;
- per-backend graphics factories and `IGraphicsSwapChain`;
- offline Slang shader containers, with reflection on `IShader` and `IShaderLibrary`;
- `IInteropDevice`, which shares memory and queue order between a CUDA device and a D3D12 or Vulkan
  device;
- a version policy under which interfaces change in place and `c_HeaderVersion` stays 28.

Its barrier surface is still the per-command-list tracker. There are no split, aliasing, discard or
queue-ownership barriers, and no public fence object. The cross-queue primitives are
`queueWaitForCommandList` and, on Vulkan, semaphore waits that are queued onto the next submission.

The new graph must meet five requirements:

1. no DSL;
2. outstanding handling of state transitions and state overlap;
3. the ethereal-dev RHI on all four backends;
4. generic build, compile and execute, isolated from donut's shipped passes;
5. a performance-oriented design, with measured budgets.

## Decision

Build a new render graph as described in [`../rdg-design.md`](../rdg-design.md).

1. **C++ only.** The graph is recorded each frame through COM-style interfaces. There is no graph
   language and no builder object.
2. **Four objects.**
   - A persistent resource registry holds what survives between frames: persistent resources and
     their states, the plan cache, heaps and pools, caches, fences and retirement.
   - A graph, bound to one registry and reused across frames, creates and imports the frame's
     resources and records passes and each use's data into a frame arena. Each pass declares its
     accesses in `Setup`, through an `ISetupContext` valid for that call only.
   - `IRenderGraph::Compile` turns the graph into a cached plan (`ICompiledRenderGraph`) with
     prebuilt barrier arrays, makes no device calls, and freezes the graph until its next `Reset`.
   - `IRenderGraph::Execute` runs the plan. There are no separate compiler and executor interfaces.
   - The plan cache must beat the no-cache baseline (`maxCachedPlans = 0`) on measured frame cost,
     or it is removed after step 5.
3. **Transitions are computed per subresource,** planes included, from an abstract access vocabulary.
   - Resources are named by one `ResourceId`, a 64-bit enum holding an index and a version, so it
     can cross virtual calls under nvrhi's ABI rule R1. Accesses name an `nvrhi::SubresourceRegion`
     (mips, slices and a Color/Depth/Stencil plane mask).
   - Per-backend state lattices merge compatible reads across whole read epochs.
   - UAV ordering is explicit.
   - Split barriers, aliasing barriers and discards are inferred.
   - Each transition is placed on a queue that can perform it. A per-queue legality table covers
     both states and stages.
   - The frame boundary is part of the plan:
     - aliasing against the previous frame's last occupant;
     - cross-queue waits on the previous frame's work;
     - a legal state hand-off at the wrap.
   - Clears are accesses with their own slot.
   - A device-free verifier checks every plan, including two consecutive frames and plan switches.
4. **ethereal-nvrhi is extended in place, without a header-version bump,** as its version policy
   now prescribes.
   - A new `IResource` base sits under every resource interface. It carries no type tag (backends
     use `QueryInterface`), and exposes `queryHeapBinding`, which aliasing validation needs.
   - Vulkan `bind*Memory` checks its result.
   - `ICommandList` gains `barriers(const ResourceBarrier*, uint32_t)`. `ResourceBarrier` is a
     D3D12-style union of transition, UAV and aliasing barriers, with split, discard and
     queue-ownership flags.
   - `ICommandList` also gains `setExplicitBarrierScope`, a validation aid: inside the scope the
     validation layer reports every barrier-changing call.
   - Transitions carry a new `SubresourceRegion`, which the graph's accesses share.
     `TextureSubresourceSet` is not changed, so no binding or framebuffer layout moves.
   - A new timeline `IFence` arrives together with `IDevice::submit`, which takes fence waits and
     signals, plus queue-level fence wait and signal calls and a multi-fence CPU wait. CPU waits
     have defined poll, finite and infinite-timeout behaviour; an infinite timeout blocks until the
     value is reached.
   - Async compute uses compute-queue command lists; on CUDA these are streams.
   - The tracker remains as the fallback. On D3D11 before 11.4, frames are retired with
     `IEventQuery`.
   - Queued waits (the Vulkan swap-chain acquire, Vulkan interop) ride on the graph's first
     graphics submission, and the back buffer is used on the graphics queue only.
   - Graphs that share data across a CUDA and a graphics device import the interop objects and are
     ordered by `IInteropDevice`'s queue waits. One graph per device.
5. **The graph sits in the `render/` folder of `donut_render`, and the passes join it directly.**
   - The generic code is the `RenderGraph*` files, which may include only nvrhi, `donut/core` and
     each other. A header-hygiene test enforces this.
   - Every donut pass derives from one base, `donut::render::IGpuPass`, and adds itself to a graph
     through `AddToGraph`. There is no adapter layer.
   - Changes to the existing passes are additive; their immediate entry points keep working.
   - A pass has four calls: `Setup`, a serial `Prepare` (pipelines and uploads), `Execute`, and
     `OnResourcesReleased`.
   - Pass bodies run in one of three modes: Native, Tracked, or Restore (for bodies that change
     states internally). Native bodies run inside an explicit-barrier scope.
   - Per-use frame data must be trivially destructible (`NewFrameData`). A pass can create
     transients scoped to itself through its setup context.
   - A header-only, type-keyed blackboard (`FrameData`) lets optional features share ids.
   - Histories have 2 to 8 layers (`GetHistory`), after RPS's temporal resources; TAA's pair is the
     two-layer case.
   - The compiler is an internal list of phases. The verifier, the dumps and the debug switches
     are phases in it, and the list is not exposed through the ABI.
   - Passes can be toggled with `SetPassEnabled` on a superset plan, with an output policy for when
     a pass is disabled, and grouped into exclusion groups. Toggling never reallocates memory.
   - `app::IRenderPass` is renamed `app::IAppLayer`. The `DeviceManager` members follow it
     (`AddLayerToFront`, `AddLayerToBack`, `RemoveLayer`, `m_vLayers`), and `ImGuiRenderPass`
     becomes `ImGuiLayer`. This keeps the name `nvrhi::IRenderPass` free for the RHI's future
     render-pass object.
6. **Performance is an acceptance criterion.**
   - A plan-cache hit costs ≤ 0.05 ms for 64 passes.
   - A steady-state frame makes zero heap allocations and zero GPU-object creations.
   - Barrier count and GPU and CPU frame time must be no worse than the hand-written samples.
   - The memory budget applies to poolable transients on a graph that can reuse them. On the
     deferred frame it is reported, not gated.
   - Debug switches (`ForceDedicated`, `BarrierAfterEveryPass`, `SerializeQueues`, …) and pixel-exact
     A/B tooling ship with the graph.
7. **Branches.** Work happens on new `rdg` branches started from aggregate `main` (nvrhi and donut
   `ethereal-dev`, samples `main`) in all four repositories.
   Nothing from the `framegraph` branches is reused. `RdgDesign.md` becomes "Superseded by aggregate
   ADR 0003", and the 2026-10-04 framegraph plan becomes "Abandoned".
8. **Lessons from the legacy framegraph are adopted.**
   [`../rdg-legacy-evaluation.md`](../rdg-legacy-evaluation.md) compared this design with the
   deprecated branches, and its twelve recommendations are part of the design (its section 14.8).
   A second pass during the ethereal-dev rebase added six more (items 13-18). The legacy's code is
   not reused.

## Consequences

### Positive

- One compiler serves four backends. D3D11 and CUDA still get a verified plan.
- A cached plan replays prebuilt barrier arrays with one RHI call per slot.
- Barriers, memory and queue waits are measurable, and each barrier records its reason.
- Shipped passes stay usable outside the graph.

### Negative

- Not bumping the header version leaves ABI breaks undetected. These changes alter virtual tables:
  - `barriers` is appended to `ICommandList`, which shifts `d3d12::ICommandList` and
    `cuda::ICommandList`;
  - the fence calls are appended to `IDevice`, which shifts `d3d12::IDevice`, `vulkan::IDevice` and
    `cuda::IDevice`;
  - `IResource` is inserted under each resource interface.

  No existing struct layout changes.

  As a result, nvrhi, donut, the samples and installed consumers must always be rebuilt together, and
  `nvrhiVerifyHeaderVersion` cannot catch a mismatched binary.
- Two barrier sources coexist during migration: the plan, and nvrhi's automatic barriers in Tracked
  passes.
- Placing the graph in `donut_render` means isolation is enforced by an include rule, not by a link
  boundary.
- The `app::IAppLayer` rename touches 5 donut and 43 sample files, with no alias.
- The reflection cross-check covers only shaders built as containers. donut's own passes load plain
  bytecode, so they are not checked.
- Six passes that had no base become reference counted, so their owners change.
- More mechanism than the legacy had: the frame-boundary patching, the masked schedules, the Restore
  mode and the debug switches each need tests.

### Risks

- **D3D12 enhanced barriers have failed here before.** The 2026-10-16 failure was `AccessBefore =
  NO_ACCESS` with a defined layout. The new lowering needs debug-layer and GBV coverage from its first
  commit.
- **Vulkan split barriers may not pay off.** Events may cost more than they save, so their use is
  policy-limited.
- **Vulkan placed aliasing is blocked** until `createHeap` honours `memoryTypeBits`. Even then, the
  legacy measured under 1 % savings on the deferred samples, so the Placed tier is opt-in.
- **The D3D12 enhanced alias form** (outgoing resources to `NO_ACCESS`, then the incoming one from
  `UNDEFINED` with `DISCARD`) must be checked against the specification in step 1.
- **D3D12 was never exercised by the legacy.** Its D3D12 paths were only reviewed, never run, so
  none of its lessons were proven there.
- **CUDA fences have an ordering constraint.** They are emulated with an event ring, so a wait must be
  enqueued after its signal. The graph always submits producers first, and validation rejects the
  reverse order.
- **Vulkan ownership transfers are unproven.** The legacy used `CONCURRENT` sharing instead. If
  release/acquire pairs fail validation or cost more than they save, the fallback brings
  `CONCURRENT` back for cross-queue resources.

## Alternatives considered

- **Restore the `framegraph` branches.** Rejected. They were discarded by request, they are not
  available, and they predate the current RHI.
- **AMD RPS as the compiler.** Rejected. It has no barrier or recording callback, so we would have to
  compile against its internals, and upstream has been dormant since 2024.
- **The nvrhi tracker alone.** Rejected because it cannot meet requirement 2. It is kept as the
  fallback.
- **A separate `IBarrierCommandList` interface and an API version bump.** Rejected in review in
  favour of extending `ICommandList` in place.
- **Binary `IEvent` objects for cross-queue sync.** Rejected for four reasons:
  - D3D12 has no GPU event.
  - A `VkEvent` cannot cross queues.
  - Binary events need reset bookkeeping.
  - Timeline values give transitive reduction and frame retirement for free.
- **A separate `donut_rdg` library.** Rejected in review. The graph sits in `donut_render`.
- **A `render/rdg` subfolder with adapters in `render/rdg_passes`.** Rejected in review. The passes
  derive from one base and add themselves to the graph.
- **Builder objects** (`IRenderGraphBuilder` producing an immutable `IRenderGraph`, and an
  `IPassBuilder` handed to `Setup`). Rejected in review on 2026-11-04. Since 2026-11-05 their methods
  belong to the graph (resources and passes) and to `ISetupContext` (access declarations).
- **Resource creation and importing on `IResourceRegistry`.** Tried and withdrawn on 2026-11-05: the
  registry keeps only what survives between frames.
- **Passes that keep their per-use data themselves,** found through a `GetPassId` on the contexts.
  Withdrawn in review on 2026-11-05 in favour of `void* data` records in the frame arena.
- **"Data and operations are separate objects" as a design rule.** Dropped in the same review.
- **A string-keyed blackboard, as in Filament** (`std::unordered_map<std::string_view,
  FrameGraphHandle>`). Rejected on 2026-11-05: it allocates every frame, turns misspelled keys into
  empty entries at run time, and its `operator[]` resets the entry it is asked for.
- **Separate `IRenderGraphCompiler` and `IRenderGraphExecutor` objects.** Folded into
  `IRenderGraph` on 2026-11-05, as in Filament: once the data/operations rule was dropped, they
  bought nothing that the registry and the plan object do not already give.
- **A setup interface per pass kind, as in Unity.** Not adopted: one `ISetupContext` with
  compile-time validation keeps the ABI smaller.
- **An `IResource::getResourceType` tag.** Rejected in the same review in favour of
  `QueryInterface` on the derived interface.
- **Separate `TextureRef` and `BufferRef` handles.** Rejected in review in favour of one
  `ResourceId`.
- **A `planeMask` member on `TextureSubresourceSet`.** Rejected in review. It would grow
  `BindingSetItem` from 40 to 48 bytes and move `FramebufferAttachment` members. A separate
  `SubresourceRegion` leaves those layouts alone.
- **Replace nvrhi with shader-slang/slang-rhi.** Rejected. The requirement is the ethereal-dev RHI,
  which already borrows slang-rhi's CUDA execution model.

## References

- Design: [`../rdg-design.md`](../rdg-design.md)
- Legacy evaluation: [`../rdg-legacy-evaluation.md`](../rdg-legacy-evaluation.md), from
  `ethereal-rdg-experimental-deprecated.tgz` (donut `34ea046`, nvrhi `13b60ff`, samples `d2eee6f`)
- Reference survey: `D:/ps/Chrome-Download/rdg_frame_graph_reference_projects.md` (RPS, O3DE Atom,
  Filament, Unity SRP, azhirnov/FrameGraph, slang-rhi)
- ethereal-nvrhi `ethereal-dev` (`123d105`):
  - `include/nvrhi/nvrhi.h`, `cuda.h`, `vulkan.h`, `d3d12.h`
  - `include/nvrhi/factory.h`, `swapchain.h`
  - `include/nvrhi/interop.h`, `shader-reflection.h`
  - `src/common/state-tracking.cpp`
  - `doc/com-interface-abi.md` §3.4; ADRs 0011 (CUDA/OptiX), 0012 (containers, reflection, version
    policy), 0013 (`IInteropDevice`), 0014 (per-backend factories and swap chains)
- Superseded: `ethereal-donut/doc/RdgDesign.md`;
  [`../plans/2026-10-04-framegraph.md`](../plans/2026-10-04-framegraph.md)
- Plan: [`../plans/2026-11-05-render-graph.md`](../plans/2026-11-05-render-graph.md); the RHI changes get
  their own nvrhi ADR in its step P1.0.
