# 0003. A new render graph for donut on the slang-next RHI

- Status: Proposed
- Date: 2026-10-21

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

On `slang-next`, ethereal-nvrhi now has:

- four backends: CUDA, D3D11, D3D12 and Vulkan;
- Slang artifacts with reflection;
- an interop contract.

Its barrier surface is still the per-command-list tracker. There are no split, aliasing, discard or
queue-ownership barriers, and the only cross-queue primitive is `queueWaitForCommandList`.

The new graph must meet five requirements:

1. no DSL;
2. outstanding handling of state transitions and state overlap;
3. the slang-next RHI on all four backends;
4. generic build, compile and execute, isolated from donut's shipped passes;
5. a performance-oriented design, with measured budgets.

## Decision

Build a new render graph as described in [`../rdg-design.md`](../rdg-design.md).

1. **C++ only.** The graph is built each frame through COM-style builder interfaces. There is no graph
   language.
2. **Data and operations are separate objects.**
   - A reusable builder records into a frame arena and produces an immutable graph.
   - A device-free compiler turns the graph into a cached plan with prebuilt barrier arrays.
   - An executor runs the plan.
   - A persistent resource registry holds what survives between frames.
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
4. **ethereal-nvrhi is extended in place, without a header-version bump.**
   - A new `IResource` base sits under every resource interface. Besides the resource type it
     exposes `queryHeapBinding`, which aliasing validation needs.
   - Vulkan `bind*Memory` checks its result.
   - `ICommandList` gains `barriers(const ResourceBarrier*, uint32_t)`. `ResourceBarrier` is a
     D3D12-style union of transition, UAV and aliasing barriers, with split, discard and
     queue-ownership flags.
   - Transitions carry a new `SubresourceRegion`, which the graph's accesses share.
     `TextureSubresourceSet` is not changed, so no binding or framebuffer layout moves.
   - A new timeline `IFence` arrives together with `IDevice::submit`, which takes fence waits and
     signals, plus queue-level fence wait and signal calls and a multi-fence CPU wait. CPU waits
     have defined poll, finite and infinite-timeout behaviour; an infinite timeout blocks until the
     value is reached.
   - Async compute uses compute-queue command lists; on CUDA these are streams.
   - The tracker remains as the fallback. On D3D11 before 11.4, frames are retired with
     `IEventQuery`.
5. **The graph sits in the `render/` folder of `donut_render`, and the passes join it directly.**
   - The generic code is the `RenderGraph*` files, which may include only nvrhi, `donut/core` and
     each other. A header-hygiene test enforces this.
   - Every donut pass derives from one base, `donut::render::IGpuPass`, and adds itself to a graph
     through `AddToGraph`. There is no adapter layer.
   - Changes to the existing passes are additive; their immediate entry points keep working.
   - A pass has four calls: `Setup`, a serial `Prepare` (pipelines and uploads), `Execute`, and
     `OnResourcesReleased`.
   - Pass bodies run in one of three modes: Native, Tracked, or Restore (for bodies that change
     states internally).
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
7. **Branches.** Work happens on new `rdg` branches started from `slang-next` in all four repositories.
   Nothing from the `framegraph` branches is reused. `RdgDesign.md` becomes "Superseded by aggregate
   ADR 0003", and the 2026-10-04 framegraph plan becomes "Abandoned".
8. **Lessons from the legacy framegraph are adopted.**
   [`../rdg-legacy-evaluation.md`](../rdg-legacy-evaluation.md) compared this design with the
   deprecated branches, and its twelve recommendations are part of the design (its section 14.8).
   The legacy's code is not reused.

## Consequences

### Positive

- One compiler serves four backends. D3D11 and CUDA still get a verified plan.
- A cached plan replays prebuilt barrier arrays with one RHI call per slot.
- Barriers, memory and queue waits are measurable, and each barrier records its reason.
- Shipped passes stay usable outside the graph.

### Negative

- Not bumping the header version leaves ABI breaks undetected. These changes alter virtual tables:
  - `barriers` is appended to `ICommandList`, which shifts `d3d12::ICommandList`;
  - the fence calls are appended to `IDevice`, which shifts `d3d12::IDevice` and `vulkan::IDevice`;
  - `IResource` is inserted under each resource interface.

  No existing struct layout changes.

  As a result, nvrhi, donut, the samples and installed consumers must always be rebuilt together, and
  `nvrhiVerifyHeaderVersion` cannot catch a mismatched binary.
- Two barrier sources coexist during migration: the plan, and nvrhi's automatic barriers in Tracked
  passes.
- Placing the graph in `donut_render` means isolation is enforced by an include rule, not by a link
  boundary.
- The `app::IAppLayer` rename touches donut and 42 sample files, with no alias.
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

## Alternatives considered

- **Restore the `framegraph` branches.** Rejected. They were discarded by request, they are not
  available, and they predate the slang-next RHI.
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
- **Separate `TextureRef` and `BufferRef` handles.** Rejected in review in favour of one
  `ResourceId`.
- **A `planeMask` member on `TextureSubresourceSet`.** Rejected in review. It would grow
  `BindingSetItem` from 40 to 48 bytes and move `FramebufferAttachment` members. A separate
  `SubresourceRegion` leaves those layouts alone.
- **Replace nvrhi with shader-slang/slang-rhi.** Rejected. The requirement is the ethereal slang-next
  RHI.

## References

- Design: [`../rdg-design.md`](../rdg-design.md)
- Legacy evaluation: [`../rdg-legacy-evaluation.md`](../rdg-legacy-evaluation.md), from
  `ethereal-rdg-experimental-deprecated.tgz` (donut `34ea046`, nvrhi `13b60ff`, samples `d2eee6f`)
- Reference survey: `D:/ps/Chrome-Download/rdg_frame_graph_reference_projects.md` (RPS, O3DE Atom,
  Filament, Unity SRP, azhirnov/FrameGraph, slang-rhi)
- ethereal-nvrhi `slang-next`:
  - `include/nvrhi/nvrhi.h`
  - `include/nvrhi/interop.h`
  - `include/nvrhi/graphics-interop.h`
  - `src/common/state-tracking.cpp`
- Superseded: `ethereal-donut/doc/RdgDesign.md`;
  [`../plans/2026-10-04-framegraph.md`](../plans/2026-10-04-framegraph.md)
- Plan: to be written on acceptance, together with the nvrhi ADR for the RHI changes.
