# Render graph (RDG) for donut: design

- Status: Draft
- Date: 2026-10-21
- Decision record: [ADR 0003](adr/0003-render-graph-for-donut.md)
- Supersedes: `ethereal-donut/doc/RdgDesign.md` (2026-10-12) and
  [`plans/2026-10-04-framegraph.md`](plans/2026-10-04-framegraph.md). Nothing from the unmerged
  `framegraph` branches is reused; those branches are no longer in the local repositories.

This document is the design of a new render graph for donut. It specifies the interfaces, the
compiler's algorithms, the RHI extensions and the backend lowering closely enough to review code
against. Scheduling heuristics beyond async-compute placement and read grouping are left for later.

## 1. Requirements

| # | Requirement | What it means here |
| --- | --- | --- |
| R1 | No DSL, no DSL parser or compiler | C++ is the only authoring surface. Graphs are built each frame through a builder interface. No RPSL, no graph files, no code generation. |
| R2 | Outstanding at resource state transitions and state overlapping | Per-subresource (plane, mip, slice) state tracking. Merging of compatible read states across whole read epochs. UAV ordering control, split barriers, aliasing barriers with first-use initialisation, discard inference, queue-capability-aware transition placement. A device-free verifier proves every plan correct. Section 6 is the core of the design. |
| R3 | The slang-next RHI; four backends: CUDA, D3D11, D3D12, Vulkan | Build on ethereal-nvrhi as it stands on `slang-next`: the IDevice/ICommandList model, `GraphicsAPI::CUDA`, `IShaderProgram` artifacts, interop. One compiler for all four. Per-backend behaviour comes from a capability profile and a lowering layer, never from `if (api == ...)` in the compiler. |
| R4 | Generic build, compile and execute | The graph is part of `donut_render`, as the `RenderGraph*` files in the `render/` folder. Graph code names no pass and includes nothing from the rest of `donut/render` or `donut/engine`. Every donut pass derives from one base, `IGpuPass`, and adds itself to a graph. The dependency runs from the passes to the graph, never back. |
| R5 | Performance oriented | Every mechanism is chosen and gated by its CPU and GPU cost. A cached plan costs almost nothing per frame, and steady state creates no GPU objects and makes no heap allocations. The plan emits the fewest, narrowest barriers that are correct. Each implementation step has measured exit budgets (section 10). |

Non-goals:
- a visual graph editor and scripting;
- automatic pass reordering beyond async-compute placement and read grouping;
- multi-device graphs: one graph spanning a CUDA device and a graphics device (14.5);
- native render passes with load/store ops. The RHI has none yet; the name `nvrhi::IRenderPass` is
  kept free for them (3.3, 6.9).

## 2. Facts the design is built on

### 2.1 The slang-next RHI

Verified against `ethereal-nvrhi` on `slang-next` (header version 30).

**Objects**

- Resources derive directly from `IRHIObject`: `ITexture`, `IBuffer`, `IStagingTexture`,
  `ISamplerFeedbackTexture`, `rt::IAccelStruct` and `rt::IOpacityMicromap`. There is no common
  resource base.
- `d3d12::ICommandList` derives from `nvrhi::ICommandList`.
- Descriptor debug names are `nvrhi::string` (an EASTL-style string with inline storage).
- Results are `FRESULT` codes, among them `FS_OK`, `FE_INVALID_ARGS`, `FE_WAIT_TIMEOUT` and
  `FE_UNSUPPORTED`.

**Subresource sets**

- `TextureSubresourceSet` is four 32-bit fields (mip base and count, slice base and count). It is
  asserted at 16 bytes.
- It is embedded in two hot layouts:
  - `BindingSetItem` (asserted at 40 bytes). It sits in a 16-byte union with `BufferRange`, and that
    union is compared and hashed through `rawData[2]`.
  - `FramebufferAttachment` (32 bytes, `isReadOnly` at offset 25).
- Adding a member would therefore change hot binding layouts. The design leaves the type unchanged
  and adds a separate `SubresourceRegion` for barriers (8.2).

**State tracking**

- `nvrhi::ResourceStates` is a flag enum.
- `CommandListResourceStateTracker` works per mip × slice. It never tracks planes, and it tracks
  buffers only as a whole. Its state lives inside one command list and is cleared at submit.
- Texture read states are never merged. ShaderResource after DepthRead emits a full transition.
- The only barrier API is the tracker: `setTextureState`/`setBufferState` plus `commitBarriers`.
  There are no split barriers, aliasing barriers, discards, layout-only transitions or
  queue-ownership transfers.

**Per backend**

- **D3D12** has legacy and enhanced barriers, chosen per device. On the enhanced path a combined
  ShaderResource|DepthRead asserts.
- **Vulkan** always uses sync2.
  - `Common` maps to `UNDEFINED` with an empty first synchronisation scope. It is an implicit
    discard, and it also waits for nothing, which leaves a write-after-read hazard.
  - `commitBarriers` ends the dynamic-rendering pass.
  - Queue families are always `IGNORED`, and sharing is `EXCLUSIVE`.
- **D3D11 and CUDA** implement every state call as a no-op. CUDA orders work by stream submission.
  D3D11 maps the UAV-barrier toggles to NVAPI UAV overlap.
- **Binding states.** On D3D12 a binding requires the shader-resource state that matches its
  visibility (pixel or non-pixel). On Vulkan nvrhi binds sampled depth as
  `ShaderResource|DepthRead`.

**Queues and synchronisation**

- Queues are `CommandQueue{Graphics, Compute, Copy}`. A command list is created for one queue
  (`CommandListParameters::queueType`). There is no queue object.
- `executeCommandLists` returns an instance value. `queueWaitForCommandList(waitQueue, execQueue,
  instance)` is the only cross-queue primitive:
  - D3D12 uses a fence per queue.
  - Vulkan uses a timeline semaphore per queue (also reachable through `vulkan::IDevice::queueWaitForSemaphore`).
  - CUDA uses one non-blocking stream per queue and waits with `cuStreamWaitEvent`.
  - D3D11 has one queue, so the call is a no-op.
- `IEventQuery` is a CPU-side completion query.
- The interop headers add `IExternalFence`, plus queue-level `waitFence`/`signalFence` on
  `IGraphicsInteropDevice`.

**Memory**

- `IHeap` and `bind*Memory` work on D3D12 and Vulkan only (`Feature::VirtualResources`). A resource
  binds exactly once.
- Vulkan heaps ignore `memoryTypeBits`. D3D11 and CUDA return unsupported.
- Vulkan `bindImageMemory` and `bindBufferMemory` ignore the bind result and always report success
  (`vulkan-texture.cpp:412`, `vulkan-buffer.cpp:689`).
- nvrhi cannot report which heap, offset and size a virtual resource is bound to.

**Render targets**

- Framebuffers have no load/store ops; Vulkan hard-codes LOAD/STORE. nvrhi has no render-pass
  object.

**CUDA, reflection and interop**

- CUDA has no raster pipelines or framebuffers and no depth clears. It rejects normalised-format
  UAVs.
- `IShaderProgram` reflection distinguishes SRV from UAV slots.
- Interop acquire/release already drives the tracker and Vulkan external queue transitions.

**Earlier work.** The deprecated `framegraph` branches (archived 2026-10-14, evaluated in
[`rdg-legacy-evaluation.md`](rdg-legacy-evaluation.md)) had already added the following to nvrhi.
None of it is on slang-next:
- aliasing barriers through a derived `ICommandList1`;
- heap-binding queries (`ITexture1/IBuffer1::queryHeapBinding`);
- `CONCURRENT` sharing across Vulkan queue families;
- header versions 28 → 31.

Section 8 keeps the aliasing and heap-binding ideas, but not the derived interfaces.

### 2.2 donut

**There is no common pass base.** The shipped passes derive from three different places:

| Base | Passes |
| --- | --- |
| `nvrhi::ObjectImpl<nvrhi::IObject>` | BloomPass, DeferredLightingPass, DLSS, SkyPass, SsaoPass, TemporalAntiAliasingPass, ToneMappingPass |
| `IGeometryPass` (itself an `ObjectImpl<IObject>`) | DepthPass, ForwardShadingPass, GBufferFillPass, MaterialIDPass |
| nothing | EnvironmentMapPass, JointsRenderPass, LightProbeProcessingPass, ManipulatorPass, MipMapGenPass, PixelReadbackPass |

**`app::IRenderPass` is not a GPU pass.** It is the application's frame participant:
- `DeviceManager` keeps a front-to-back list of them (`AddRenderPassToFront`,
  `AddRenderPassToBack`, `RemoveRenderPass`).
- On each one it calls `Render(framebuffer)`, `Animate`, the resize callbacks and the keyboard,
  mouse and joystick handlers.
- `ApplicationBase` and `ImGuiRenderPass` derive from it, and 42 files in ethereal-samples use it.

**Barriers.** Passes rely on nvrhi automatic barriers and on textures created with
`keepInitialState=true`. Only DLSS records barriers itself.

**Targets.**
- Passes take targets through a concrete `engine::FramebufferFactory`, through
  `RenderView`/`RenderCompositeView`, or as raw `ITexture*`.
- `FramebufferFactory` caches framebuffers by subresource set only, so the cache goes stale when the
  textures are reallocated.
- These passes bind their targets or formats at construction:
  - BloomPass
  - ToneMappingPass
  - SkyPass
  - EnvironmentMapPass
  - TemporalAntiAliasingPass
- GBufferFillPass, DepthPass and ForwardShadingPass cache pipeline state objects without the
  framebuffer format in the key, so samples recreate them on resize.

**Resources hidden inside passes.**

| Pass | What it keeps internally |
| --- | --- |
| SsaoPass | deinterleaved quarter-resolution arrays |
| BloomPass | per-view chain |
| TemporalAntiAliasingPass | feedback ping-pong, swapped in `AdvanceFrame` |
| ToneMappingPass | histogram and exposure buffers |
| LightProbeProcessingPass | intermediate cube |

**Best fit.** DeferredLightingPass, whose inputs are a per-call `Inputs` struct.

**Swap chain.** Swap-chain textures are `keepInitialState` with initial state Present. Declaring
their state to a graph once cost a device loss; the import contract in 5.2 makes that impossible.

**Build.** `donut_render` collects `include/donut/render/*.h` and `src/render/*.cpp` with a
non-recursive `file(GLOB)` in `donut-render.cmake`. It links `donut_core` and `donut_engine`.

**Vulkan queue families.** `DeviceManager_VK::findQueueFamilies` never resets its family indices
between physical devices (`DeviceManager_VK.cpp:585`, initialised once at
`DeviceManager_VK.h:232-235`). On a machine with more than one GPU, compute lists can come from a
transfer-only family. This caused a device loss on the legacy branches, and the fix was never
merged.

**Thread safety.** `BindingCache` creates missed binding sets while it holds its exclusive lock.
`CommonRenderPasses::BlitTexture` writes its pipeline cache without any lock
(`CommonRenderPasses.cpp:260`).

### 2.3 What the references teach

| Mechanism | Taken from | Used in | Pitfall avoided |
| --- | --- | --- | --- |
| Transition decided per access against a per-subresource state map; a reader set accumulates until the next write | RPS `AccessDAGBuilder`, `NeedTransition` | 6.2, 6.3 | azhirnov replaces the reader record on each read, so a later write waits only for the last reader. Here every reader since the last write is a dependency of the next write. |
| Interval map over a linearised subresource index | O3DE `RHI::ImageProperty`, azhirnov `VLocalImage` | 6.2 | RPS and azhirnov never re-coalesce. Here equal neighbours are merged after every pass. |
| Discard-before/after inferred from lifetime | RPS lifetime phase, Filament `RenderPassNode::resolve`, Unity `DetermineLoadStoreActions` | 6.6 | Persistent and imported resources never get inferred discards. |
| UAV→UAV ordered by default; relaxed only when both sides opt in | RPS `RELAXED_ORDER` | 6.5 | The RPS D3D12 legacy builder ignores the flag; here it is honoured on every backend. |
| Byte-range overlap between deactivating and activating aliases | O3DE `AliasingBarrierTracker` | 6.7 | RPS has no aliasing barrier. |
| Lifetimes widened across async queues before aliasing | O3DE `ExtendTransientAttachmentAsyncQueueLifetimes` | 7.4 | |
| Transitions moved to a queue that can perform them | O3DE DX12 epilogue placement | 6.8 | |
| Prologue/epilogue barrier slots; split begin/end across passes | Unreal RDG, O3DE | 6.4 | RPS (`BEFORE/AFTER` not implemented) and O3DE have no split barriers. |
| Barrier combining only over exact or adjacent ranges | (lesson) | 6.10 | O3DE Vulkan `Barrier::Combine` takes a bounding box and can over-cover. |
| Versioned handles; a write creates a version | Filament, Unity | 5.1 | Filament versions the whole parent on a subresource write. Here hazards are per subresource. |
| Reference-count culling from side-effect passes | Filament, Unity | 7.1 | |
| A reason code on every barrier and every non-merge | Unity `PassBreakReason` | 11.3 | |
| One barrier record type for transitions, UAV and aliasing | D3D12 `D3D12_RESOURCE_BARRIER` | 8.2 | |
| Immediate-mode tracker as the fallback outside the graph | slang-rhi `StateTracking` | 9.1 | |

## 3. Architecture

```
 samples / app ── build a graph each frame (app::RenderGraphLayer, or their own code)
        │
        ▼
 donut_render  (include/donut/render, src/render)
 ├─ RenderGraph*  (generic)
 │    IRenderGraphBuilder ─► IRenderGraph (data) ─► IRenderGraphCompiler ─► ICompiledRenderGraph (data)
 │                                                                                │
 │                                                    IRenderGraphExecutor ◄──────┘
 │    IResourceRegistry (data, persists across frames)      BackendProfile + lowering
 │    IGpuPass, IPassBuilder, IPassContext
 │        ▲ derive from IGpuPass, call AddToGraph
 └─ passes: GBufferFillPass, DeferredLightingPass, ForwardShadingPass, DepthPass, SsaoPass,
            BloomPass, TemporalAntiAliasingPass, ToneMappingPass, SkyPass, ...
        │
        ▼
 ethereal-nvrhi (slang-next) + IResource, SubresourceRegion, ICommandList::barriers, IFence, IDevice::submit (section 8)
   D3D12  |  Vulkan  |  D3D11  |  CUDA
```

### 3.1 Placement

The graph sits in the `render/` folder of `donut_render`, beside the passes. There is no new library,
no subfolder and no adapter layer: the passes themselves become graph passes (section 13).

| File | Contents |
| --- | --- |
| `include/donut/render/RenderGraph.h` | public interfaces (section 12), including `IGpuPass` |
| `include/donut/render/RenderGraphLambdaPass.h` | header-only lambda helper (12.1) |
| `src/render/RenderGraphBuilder.cpp` | builder, frame arena, structural hash |
| `src/render/RenderGraphCompiler.cpp` | phases 1-5 and 7 of section 7 |
| `src/render/RenderGraphTransitions.cpp` | phase 6: the walk of section 6, lattices |
| `src/render/RenderGraphExecutor.cpp` | executor and lowering (9.1) |
| `src/render/RenderGraphRegistry.cpp` | registry, plan cache, pools, fences, retirement |
| `src/render/RenderGraphProfile.cpp` | backend profiles (9.2) |
| `src/render/RenderGraphVerifier.cpp` | device-free verifier (11.1) |
| `src/render/RenderGraphInternal.h` | private concrete classes |

The non-recursive `file(GLOB)` in `donut-render.cmake` picks these up with no build change.

### 3.2 Rules

1. **Graph code stays generic.** The `RenderGraph*` files may include only `nvrhi/`, `donut/core/`,
   other `RenderGraph*` headers and the C++ standard library. A header-hygiene test in CTest fails
   when one of them includes any other `donut/render/` or `donut/engine/` header.
2. **The dependency runs one way.** Passes include `RenderGraph.h` and derive from `IGpuPass`. Graph
   code reaches a pass only through `IGpuPass`.
3. **`RenderGraph.h` follows the nvrhi ABI rules.**
   - COM interfaces with `NVRHI_IID`.
   - `noexcept` and `FRESULT`.
   - Raw pointers in parameters; `AutoPtr` only as a return or out-parameter.
   - No STL in interfaces.
   - No class, struct or union is passed or returned by value through a virtual function (nvrhi
     `doc/com-interface-abi.md`, rule R1). Structs go by `const&`; ids are enums (5.1).
   - No two virtual functions share a name (rule R3).
   - Once released, an interface is never changed. Additions go into a derived `IFoo1 : IFoo` with its
     own IID.
   - `abi_lint --api-all` and the header-hygiene test cover `RenderGraph.h`.

   Pass headers follow ordinary donut conventions.
4. **Data and operations are separate objects** (section 4).

### 3.3 Names

The design names two types and renames one existing type. All three names are decided (14.7).

**The pass base: `donut::render::IGpuPass`.** Every donut pass derives from it (13.1).
- It covers raster, compute, copy and ray-tracing passes on every backend, CUDA included, where
  "render" or "graphics" would mislead.
- It does not collide with `nvrhi::IRenderPass`, which is kept for the RHI's future render-pass
  object.
- Alternatives considered:
  - `render::IPass`: too generic outside its namespace.
  - `IGraphicsPass`: confusable with the graphics queue and with raster passes.
  - `IRenderGraphPass`: it would tie every pass to the graph, although passes also run outside one.

**The app layer: `donut::app::IRenderPass` becomes `donut::app::IAppLayer`.** The object is a
frame participant that receives input, animation and a back-buffer render call, stacked front to
back. That is what "layer" means in application frameworks.

| Today | New |
| --- | --- |
| `app::IRenderPass` | `app::IAppLayer` |
| `DeviceManager::AddRenderPassToFront` | `DeviceManager::AddLayerToFront` |
| `DeviceManager::AddRenderPassToBack` | `DeviceManager::AddLayerToBack` |
| `DeviceManager::RemoveRenderPass` | `DeviceManager::RemoveLayer` |
| `DeviceManager::m_vRenderPasses` | `DeviceManager::m_vLayers` |
| `app::ImGuiRenderPass` | `app::ImGuiLayer` |

- Alternatives considered: `IFrameLayer`, `IViewLayer`, `IAppComponent`.
- No alias is kept. The rename lands in one commit across donut and the 42 sample files, so donut
  has only one "render pass" concept left, the GPU one.

## 4. Object model: data and operations

| Object | Kind | Lifetime | Responsibility |
| --- | --- | --- | --- |
| `IRenderGraphBuilder` | operation | reused every frame | Records resources and passes into a frame arena; `Finish` freezes them into an `IRenderGraph`. |
| `IRenderGraph` | data | one frame | Immutable description: resources, passes, accesses, imports, pass objects and their per-use data. Carries its structural hash. |
| `IRenderGraphCompiler` | operation | long | `Compile(graph, profile, options) → ICompiledRenderGraph`. Pure: no device calls. Runs headless in unit tests. |
| `ICompiledRenderGraph` | data | cached across frames | Holds, among other things: <br>• schedule and segments<br>• lifetimes and memory plan<br>• prebuilt `ResourceBarrier` arrays<br>• fence operations<br>• diagnostics |
| `IRenderGraphExecutor` | operation | long | Instantiates plan memory through the registry, records command lists (optionally in parallel) and submits them. |
| `IResourceRegistry` | data | long, one per view or pipeline | Holds, among other things: <br>• persistent resources and their cross-frame states<br>• the plan cache<br>• transient heaps and pools<br>• framebuffer and binding caches<br>• per-queue fences<br>• retirement |
| `IGpuPass` | operation, pass-specific | long, owned by its creator | The base of every donut pass. `Setup` declares the accesses of one use, `Prepare` creates pipelines and uploads serially, and `Execute` records the use (12, 13.1). One pass object can be added several times per frame, each use with its own arena data. |

**Why compile is separate from execute:** it enables the device-free verifier (11.1) and plan
caching (7.7).

**Why the registry is separate from the graph:** a graph is rebuilt every frame, while history,
heaps and caches survive.

**Hot paths are concrete classes.** COM interfaces are used at module boundaries only. Inside
`src/render/RenderGraph*.cpp` the compiler and executor are plain C++ over concrete classes, with no
virtual calls in their inner loops (10.1).

## 5. Resource model

### 5.1 Resource ids and versions

`ResourceId` names a texture or a buffer in one graph. It is a 64-bit enum,
`enum class ResourceId : uint64_t`, holding a 32-bit resource index in the low half and a 32-bit
version in the high half.
- It is an enum rather than a struct, so it may cross virtual calls by value under nvrhi's ABI rule
  R1 (3.2).
- The inline helpers `MakeResourceId`, `GetResourceIndex` and `GetResourceVersion` pack and unpack it.
- `InvalidResourceId` (all bits set) is the invalid value.

- **One id type for every kind.** The kind lives in the resource record, not in the id. A
  texture-only access (a render target, a subresource range other than all) on a buffer is a
  validation error, and `IPassContext::GetTexture` returns `nullptr` for a buffer.
- **Writes create versions.** Every write declaration returns a new version.
- **Stale ids are rejected.** Using any version other than the current one is a validation error
  naming both passes.
- **No cycles.** Because every write creates a version, declaration order is always a valid
  topological order, so a graph cannot contain a cycle.

Hazards are computed per subresource, not per version (6.2).

### 5.2 Resource kinds

| Kind | Created by | Memory | Entry state | Exit state | Aliasable |
| --- | --- | --- | --- | --- | --- |
| Transient | `CreateTexture/Buffer` | Registry heap or pool | Undefined (discard) | None | Yes, single queue only (7.4) |
| Imported, tracked | `ImportTexture/Buffer(resource, entry, exit)` | Caller | Declared `entry` | Declared `exit`, reached at last use | No |
| Imported, host-kept | `ImportHostKeptTexture(tex)` for `keepInitialState` resources such as the swap chain | Caller | `desc.initialState` | `desc.initialState` | No |
| Persistent | `GetPersistentTexture/Buffer(name, desc)`, `GetHistoryPair` | Registry, dedicated | Exit state of the previous frame, recorded in the registry | Left in its last-use state and recorded; no restore transition | No |
| Extracted | `Extract(transient)` | Registry pool; the lifetime is extended to the end of the graph | as transient | Declared exit | No. It returns to the pool when the caller releases it and the frame retires |

- **Host-kept imports.** nvrhi restores a `keepInitialState` texture at `close()`, so the graph must
  never declare any other state for it. The compiler rejects tracked imports of such textures.
  - Barriers on a host-kept resource always go through the tracker (`setTextureState` plus
    `commitBarriers`), never through `barriers()`. That way nvrhi's restore at `close()` sees every
    state change.
- **Persistent resources** end each frame in whatever state their last access left them. A TAA
  history therefore costs one transition per frame, not three.
  - End states are recorded per subresource and keyed by registry id and physical resource, never by
    pointer. The legacy keyed them by pointer and needed a keep-alive against address reuse.
  - The hand-off into the next frame follows 6.12.
- **History pairs.** `GetHistoryPair` returns `{current, previous}`, backed by two physical textures.
  - **Rotation.** The two textures swap roles every frame. The plan stores both pointers, and the
    executor picks the current one by frame parity: O(number of pairs) per frame, with no recompile.
  - **Usage.** Both textures are created with the union of the usage flags declared on either role,
    so swapping never needs a different object.
  - **New allocations.** `IsNewAllocation(id)` is true only in the first frame after the pair was
    (re)allocated, which happens when it is first created or when its description changes. It
    replaces TAA's `feedbackIsValid` and the exposure-buffer reset logic.
  - **States** are recorded per physical texture, so the rotation never confuses them.

### 5.3 Subresources and planes

An access names an `nvrhi::SubresourceRegion{baseMip, mipCount, baseSlice, sliceCount, planes}`,
where `planes` is a mask of {Color, Depth, Stencil}. The type is new in nvrhi (8.2), and the graph
and `TransitionBarrier` share it. `TextureSubresourceSet` is unchanged. For buffers the region is
ignored.

The graph tracks planes even though the nvrhi tracker does not. Lowering depends on the backend:
- D3D12: plane slice 0 for Color and Depth, 1 for Stencil.
- Vulkan: aspect masks `COLOR`, `DEPTH`, `STENCIL`.
- D3D11 and CUDA: planes are ignored.

This makes it legal, for example, to write stencil while sampling depth.

## 6. State transitions and overlap handling

The core of the design has three layers:

1. **An abstract access vocabulary** that passes declare.
2. **A backend state lattice** that decides which accesses can share one state.
3. **A per-subresource walk** that produces transitions with reasons, placement and flags.

### 6.1 Access vocabulary

```
Access (bit flags)
  reads : VertexBuffer IndexBuffer IndirectArgs ConstantBuffer ShaderRead StorageRead
          ColorTargetRead(blend) DepthRead StencilRead CopySource ResolveSource
          ShadingRateRead AccelStructRead AccelStructBuildInput Present HostRead
  writes: StorageWrite ColorTarget DepthWrite StencilWrite CopyDest ResolveDest
          AccelStructWrite
AccessFlags
  Clear          the pass initialises the range with a clear as its first operation
  FullWrite      the pass writes every element of the range (makes a discard-before legal)
  RelaxedOrder   consecutive relaxed StorageWrite accesses need no UAV barrier between them
  Preserve       never infer a discard for this access
ShaderStages     Vertex | Hull | Domain | Geometry | Pixel | Compute | RayTracing | Mesh | Amplification
```

When stages are omitted, they come from the pass type. Narrower stages give narrower sync scopes on
Vulkan and on D3D12 enhanced barriers.

`StorageRead` (UAV read-only) counts as a read for hazards. On D3D12, however, it cannot share a
state with ShaderRead, which is what 6.3 resolves.

### 6.2 Per-subresource state map

For each resource the compiler keeps an interval map over a linear index:

```
plane * (mips * slices) + mip * slices + slice
```

With this order a whole mip across all slices is one interval, which is the common case for mip
chains, bloom and Hi-Z. Each interval holds:

```
SubresourceRangeState
  lastWriter     pass index (or entry)                       -- RAW and WAW source
  readers        pass bitset since the last write            -- all are WAR sources
  readUnion      Access | ShaderStages of the current read epoch
  lowered        backend state currently held (from the lattice)
  queue          queue that last touched it
  pendingSplit   an open split-begin, if any
```

After each pass, adjacent intervals whose `SubresourceRangeState` is equal are coalesced.

**Overlapping ranges within one pass.** The declared ranges of one resource may overlap only in
these combinations:
- DepthRead with ShaderRead;
- StorageRead with StorageWrite;
- ColorTarget with ColorTargetRead.

Any other overlap is a compile error naming the pass and the range. Disjoint ranges in one pass are
always legal, for example reading mip N-1 while writing mip N.

### 6.3 Read epochs and the state lattice

A read epoch is the maximal run of scheduled passes that only read a given subresource between two
writes. Before choosing a state, the compiler looks ahead over the whole epoch:

1. **Collect** the accesses of every reader in the epoch.
2. **Combine** them through the backend lattice. `Combine(a, b)` returns either a single state that
   serves both, with a cost, or "incompatible".
3. **One state for all readers:** if a single state serves every reader, emit one transition before
   the first reader and none between readers.
4. **Otherwise:** partition the readers, in schedule order, into the fewest compatible groups, with
   one transition between consecutive groups. Each such transition must wait for every reader of the
   earlier group.
   - With `ScheduleFlags::GroupReads`, readers inside the epoch may also be reordered to bring
     compatible ones together.

| Readers in one epoch | D3D12 legacy | D3D12 enhanced | Vulkan |
| --- | --- | --- | --- |
| depth test (read-only) + compute sampling + pixel sampling | `DEPTH_READ \| PIXEL_SHADER_RESOURCE \| NON_PIXEL_SHADER_RESOURCE` | layout `DEPTH_STENCIL_READ`, access `DEPTH_STENCIL_READ \| SHADER_RESOURCE` | `DEPTH_STENCIL_READ_ONLY_OPTIMAL` |
| sampling + copy source | `*_SHADER_RESOURCE \| COPY_SOURCE` | layout `GENERIC_READ` | `GENERAL` (cost) or two groups, by `LatticePolicy` |
| sampling + StorageRead | incompatible: two groups | layout `UNORDERED_ACCESS`, access `SHADER_RESOURCE \| UNORDERED_ACCESS` | `GENERAL` |
| vertex + index + indirect buffer | OR of the three | OR of accesses | OR of accesses |

The first row is the case nvrhi handles worst today. A frame that renders depth, tests against it
and samples it costs four transitions per frame, and the combination asserts on the enhanced path.
Here it costs one.

**Enhanced-path rule.** The D3D12 enhanced lowering must always put the state's real access in
`AccessBefore`, never `NO_ACCESS` together with a defined layout. That defect was found on
2026-10-16 (debug-layer message #1331, device removed).

### 6.4 Placement and split barriers

Every transition has two placement points, and both are pass boundaries (each pass has a prologue
slot and an epilogue slot):
- **Begin point:** right after the last access it waits for.
- **End point:** right before the first access that needs the new state.

**Joined barrier.** The transition is a single barrier in the consumer's prologue when either:
- the begin and end points are adjacent, or
- the profile has no split support.

**Split barrier.** The transition is split when at least `SplitMinGap` passes (default 1) lie
between the begin and end points, on the same queue and in the same command-list segment. The begin
half goes in the producer's epilogue and the end half in the consumer's prologue.
- Typical cases:
  - GBuffer targets written in pass 2 and first read in pass 5.
  - Shadow maps rendered early and sampled late.
- Lowering per backend:

  | Backend | Split lowering |
  | --- | --- |
  | D3D12 legacy | `BEGIN_ONLY` / `END_ONLY` |
  | D3D12 enhanced | `SYNC_SPLIT` |
  | Vulkan | `vkCmdSetEvent2` / `vkCmdWaitEvents2`, with an event pool per command list, used only for layout transitions and large resources (profile policy, because events cost) |
  | D3D11 and CUDA | splits are dropped |
- A split never crosses a command-list boundary.

### 6.5 UAV ordering

Two consecutive accesses to the same subresource need a UAV barrier when they are:
- StorageWrite then StorageWrite, or
- StorageWrite then StorageRead.

No barrier is emitted if both accesses carry `RelaxedOrder`. Lowering:

| Backend | UAV barrier lowering |
| --- | --- |
| D3D12 | `ResourceBarrier::Uav` |
| Vulkan | a memory barrier from shader write to shader read/write |
| D3D11 | relaxed runs are wrapped in NVAPI UAV overlap |
| CUDA | no-op (same stream) |

Writes to disjoint subresources need no barrier.

### 6.6 Discard and initialisation

The compiler infers two flags per subresource:
- **discard-before:** the first access of a transient, or any access with no live data before it.
- **discard-after:** the last access of a transient.

It never infers them for imported or persistent resources, or for accesses marked `Preserve`.

A discard-before access must be a `FullWrite` or `Clear` write. Reading a transient before it is
written is a compile error.

| Backend | discard-before lowers to |
| --- | --- |
| D3D12 legacy | transition into the target state, then `DiscardResource` on the range (required for an aliased render target or depth buffer) |
| D3D12 enhanced | `LAYOUT_UNDEFINED` → target layout with `D3D12_TEXTURE_BARRIER_FLAG_DISCARD` |
| Vulkan | `oldLayout = UNDEFINED` |
| D3D11 / CUDA | nothing |

These are all expressed as a transition with `BarrierFlags::Discard` (8.2).

**D3D12 rules.**
- `DiscardResource` requires the range to be in `RENDER_TARGET` (colour), `DEPTH_WRITE` (depth
  and stencil) or `UNORDERED_ACCESS`. The lowering transitions the range there first.
- A placed resource created with `ALLOW_RENDER_TARGET` or `ALLOW_DEPTH_STENCIL` must be initialised
  before *any* use, UAV or SRV use included. Initialisation means a discard, a clear or a full copy.
  So the creation flags decide whether to initialise, not the first access. The legacy skipped this
  for resources whose first use was a UAV, which left UAV+RT textures uninitialised.

### 6.7 Aliasing

For each placed transient, the compiler finds earlier placements in the same heap that overlap it in
bytes and whose lifetimes have ended. At the new resource's first use it emits:

1. `ResourceBarrier::Aliasing(before, after)`, where `before` is `nullptr` when several resources are
   overlapped;
2. the discard-before initialisation from 6.6.

Lowering:
- **D3D12:** an aliasing barrier.
- **Vulkan:** a memory dependency from the old resources' last stages to the new resource's first
  stage, combined with `oldLayout = UNDEFINED`.

Because nvrhi binds memory once, each alias is its own virtual nvrhi resource, bound when the plan is
instantiated and kept while the plan's hash is unchanged.

**Rules.**
- **The first scope is never empty.** It covers every stage and access that any outgoing resource
  used. A `Common` or `UNDEFINED` transition on its own waits for nothing.
  - D3D12 legacy: the aliasing barrier is a full barrier.
  - D3D12 enhanced: each outgoing resource gets a barrier from its last sync and access to
    `NO_ACCESS`. The incoming texture then goes from `LAYOUT_UNDEFINED` with `DISCARD`. Step 1
    checks this form against the enhanced-barriers specification and the debug layer.
  - Vulkan: a memory barrier from the union of the outgoing stages and accesses.
- **Tracker reset.** In Tracked and Restore passes (9.1), the tracker forgets the outgoing
  resource's state and permanent flag. It starts the incoming resource from its post-alias state.
- **No `keepInitialState` on aliased resources.** The compiler never places such a resource.
- **Across frames.** The first occupant of a range also aliases against the previous frame's last
  occupant (6.12).
- **Validation.** The nvrhi validation layer checks that the two resources really overlap in one
  heap, using `IResource::queryHeapBinding` (8.1).

### 6.8 Queues

**No queue object.** Async compute uses what the RHI already has: an `ICommandList` created with
`queueType = CommandQueue::Compute` carries the compute queue's work and is submitted to that queue.
On CUDA each `CommandQueue` is a `CUstream`, so a compute command list is replayed onto the compute
stream.

**Declaring async passes.** Async-compute passes are declared, never inferred. A pass with
`PassFlags::AsyncCompute` runs on the compute queue when the profile has one. Otherwise it is demoted
to graphics, with a diagnostic.

**Cross-queue synchronisation** uses the timeline `IFence` of 8.3, one fence per queue, owned by the
registry:
- the producer segment's submit signals `(fence[q], ++value[q])`;
- the consumer segment's submit waits for that value;
- a consumer that depends on several producer segments of one queue waits only for the highest value,
  so transitive reduction falls out of the timeline;
- waits and signals ride on `IDevice::submit` (8.3), so they cost no extra submissions.

**Queue legality.** A state or stage is legal on a queue only if that queue can hold it and
synchronise on it. The profile holds this table:

| Queue | Illegal states (D3D12) | Illegal stages (Vulkan, from the queue family's capabilities) |
| --- | --- | --- |
| Compute | RenderTarget, DepthWrite, DepthRead, PixelShaderResource, IndexBuffer, VertexBuffer, StreamOut, ResolveSource, ResolveDest, ShadingRateSource | every graphics stage: vertex input, the vertex, tessellation, geometry, mesh and task shaders, the fragment shader, early and late fragment tests, colour attachment output |
| Copy | every state except Common, CopySource and CopyDest | every stage except transfer |

**Transitions are placed on a queue that can perform them.**
- Legality is checked on the queue that executes each half of a barrier, for states and for stages.
  On Vulkan a release or acquire half names only the stages of its own queue.
- A transition that the consumer's queue cannot perform moves to the graphics-queue epilogue of
  the producer, or to the prologue of the next graphics-queue consumer.
- The lattice is queried per queue. An epoch with readers on both queues gets a state that both
  queues can hold. When no such state exists, the epoch is split into groups (6.3), as in 6.11.
- `LatticePolicy` weighs the extra barriers of a split against the overlap that async compute
  gains. When the barriers cost more, it demotes the pass to the graphics queue, with a
  diagnostic.

**Vulkan ownership.** A resource crossing queue families is released in the producer's epilogue and
acquired in the consumer's prologue, using transitions with `QueueRelease` and `QueueAcquire`
(8.2). The layout change is folded into the pair. Graph resources stay `EXCLUSIVE`. When the two
queues share a family, no transfer is emitted.

**CUDA.** Cross-stream waits go through the same `IFence`. There are no transitions.

### 6.9 Render targets

nvrhi has no load/store ops yet. The plan still records, per raster pass and attachment:
- **load:** `Clear`, `DontCare` (from discard-before) or `Load`;
- **store:** `DontCare` (from discard-after) or `Store`.

**Clears are accesses.** A `Clear` access gets its own slot between the prologue and the body:
1. the prologue moves the range into the clear state;
2. the executor records `clearTextureFloat`, `clearDepthStencilTexture` or `clearTextureUInt`;
3. a post-clear batch moves the range into the pass's state.

The profile supplies the clear state:

| Backend | Clear state |
| --- | --- |
| D3D12 | RenderTarget, DepthWrite or UnorderedAccess, depending on the view the clear uses. Usually this equals the pass's state, so step 3 is empty |
| Vulkan | `TRANSFER_DST_OPTIMAL`, because `vkCmdClear*Image` requires it |
| D3D11 and CUDA | none |

CUDA has no depth clears, so a depth `Clear` on CUDA is a compile error (7.1).

When nvrhi gains a render-pass object (the name `nvrhi::IRenderPass` is kept free for it, 3.3),
clears move into the render pass's load op and the clear slot disappears. Pass code does not change.

Merging consecutive raster passes is out of scope for now. The plan records why each adjacent pair
could not merge.

### 6.10 Barrier batching

All barriers with the same end point form one batch per (queue, slot). A batch is a contiguous
`ResourceBarrier` array in the plan, emitted with one `barriers()` call.

- **Range merging.** Regions are merged only when they are exactly equal or adjacent, with equal
  plane masks, never into a bounding box. A region that covers the whole resource becomes the
  default (whole) region.
- **Order within a batch.** Aliasing barriers first, then transitions (discards included), then UAV
  barriers.
- **Vulkan.** Batches sit only at pass boundaries, so the rule that a barrier ends dynamic rendering
  never splits a pass.

### 6.11 Worked example: deferred frame

| # | Pass | Queue | Accesses |
| --- | --- | --- | --- |
| 1 | DepthPrepass | graphics | Depth W |
| 2 | GBuffer | graphics | Depth R (test), GB0-3 W, MV W |
| 3 | SSAO | compute (async) | Depth R (sample), Normals R, AO W |
| 4 | Shadow | graphics | ShadowMap W |
| 5 | DeferredLighting | graphics | Depth, GB, AO, ShadowMap R; HDR W |
| 6 | Forward transparent | graphics | Depth R (test), HDR W (blend) |
| 7 | TAA | graphics | HDR R, MV R, History.prev R, History.cur W |
| 8 | ToneMap | graphics | History.cur R, Backbuffer W |

**Depth.** After the write in pass 1, depth has a read epoch spanning passes 2, 3, 5 and 6.
- **Without async compute** (SSAO on the graphics queue), the lattice finds one state for all four
  readers:
  - D3D12: `DEPTH_READ | PIXEL_SHADER_RESOURCE | NON_PIXEL_SHADER_RESOURCE`;
  - Vulkan: `DEPTH_STENCIL_READ_ONLY_OPTIMAL`.

  That is one barrier per frame, against four in today's hand-written sample.
- **With async SSAO on D3D12**, no single state is legal on both queues, because the compute queue
  cannot hold `DEPTH_READ` (6.8). The epoch splits into three groups. Every transition runs on the
  graphics queue:
  1. pass 1 epilogue: `DEPTH_WRITE → DEPTH_READ`, for pass 2;
  2. pass 2 epilogue, before the signal that pass 3 waits on: `DEPTH_READ →
     NON_PIXEL_SHADER_RESOURCE`, for passes 3 and 5;
  3. pass 6 prologue: `NON_PIXEL_SHADER_RESOURCE → DEPTH_READ`. Pass 5 already waits for SSAO's
     signal, because it reads AO, so this transition cannot overtake the compute read.
- **With async SSAO on Vulkan**, layouts are not queue-restricted, so one layout barrier remains:
  `DEPTH_ATTACHMENT → DEPTH_STENCIL_READ_ONLY`.
  - If the compute queue is in another family, two ownership pairs follow: graphics → compute
    around pass 3, and compute → graphics before pass 5.
  - Each half names only its own queue's stages.
- `LatticePolicy` decides whether async SSAO still pays on D3D12 after the two extra barriers (6.8).

**GB0-3.** Split: begun in pass 2's epilogue, ended in pass 5's prologue.

**AO.** It is used on both queues, so it is neither aliased nor reused within the frame (7.4).

**History.** A persistent pair, with no restore transition.

**Backbuffer.** A host-kept import.

### 6.12 Frame boundary

A plan is compiled on the assumption that the previous frame ran the same plan. The compiler treats
the last accesses of frame N as predecessors of the first accesses of frame N+1, for three hazards:

1. **Aliasing across frames.** For each heap range, the first occupant in frame N+1 gets an
   aliasing barrier (6.7) against the last occupant in frame N, when they are different resources.
   When they are the same transient, its discard-before initialisation is enough.
2. **Write-after-read across queues and frames.** A resource or memory range might be last used on
   queue A in frame N and first used on queue B in frame N+1. Then the first segment on B that
   touches it waits for A's last signal of frame N. The wait rides on `submit` (8.3), and fence
   values reduce it to one wait per other queue. Without this wait, the legacy got "in-flight on
   another queue" from the D3D12 debug layer.
3. **State hand-off at the wrap.** A persistent resource ends frame N in its last-use state on
   queue A. Suppose frame N+1's first access is on queue B.
   - The hand-off transition is placed where both the old and the new state are legal (6.8),
     normally at the end of frame N on queue A.
   - With different Vulkan families, it includes a release on A and an acquire on B.
   - If no queue can perform it, the compile fails, naming the resource and both passes.
   - Without this check the legacy got 10 validation errors per 120 frames, from a fragment-stage
     `srcStageMask` on the compute queue.

**When the plan changes between frames** (a cache miss, or a switch to another cached plan), the
registry keeps the previous plan's last occupants, queues and states. It patches the new plan's
first prologue batches and waits for that one frame.
- Plans that share a memory plan (7.7) share heaps, so their donors are known in advance.
- Plans with different heaps alias nothing across the switch.

The verifier (11.1) replays two consecutive frames, and a switch between two plans, to check all
of this.

## 7. Compiler pipeline

Every phase is device-free and data-oriented (10.1). The phases run in this order:

1. **Validate.** Rejects:
   - stale versions and invalid ids;
   - texture-only accesses on buffers;
   - conflicting overlaps within a pass;
   - transient reads before any write;
   - tracked imports of `keepInitialState` textures;
   - pass types the profile lacks (Raster on CUDA);
   - flags that conflict with an access (StorageWrite needs `isUAV`; CUDA rejects normalised-format
     UAVs);
   - a state or stage that is illegal on its pass's queue (6.8), and depth clears on CUDA (6.9);
   - `keepInitialState` on a resource that may be aliased (6.7);
   - two passes of one exclusion group enabled together, and disabled-output policies whose
     substitute or passthrough input does not match the output (13.5).
2. **Cull.** Reference counts run from:
   - `NeverCull` and `SideEffect` passes;
   - writes to imported, persistent or extracted resources;
   - Present.

   Disabled passes (13.5) are removed first, and their outputs follow their policies.
3. **Schedule.**
   - Program order is the default.
   - Async passes are assigned to the compute queue.
   - `GroupReads` is optional.
   - RPS-style heuristics are left as future flags.
4. **Lifetimes.** Each resource gets [first use, last use].
   - Resources used on more than one queue are never aliased and never reused within the frame, so
     their lifetimes need no widening. They may still be pooled across frames.
   - Resources used only by passes of one exclusion group (13.5) may share memory with each other.
5. **Memory plan.** Tiers:
   - **Placed** (D3D12; Vulkan once `createHeap` honours `memoryTypeBits`):
     - heaps are kept per queue and per heap class;
     - resources are sorted by size descending and placed first-fit in a (byte range × lifetime)
       plane;
     - cross-queue resources are not aliased.
   - **Pooled** (D3D11, CUDA, and Vulkan until then): whole-resource reuse keyed by description, with
     frame-age eviction.
   - **Dedicated:** the `ForceDedicated` debug switch (11.4).
   - **Choice.**
     - Placed is opt-in per registry (`CompileOptions::placedResources`).
     - It is probed at startup (heap tier, and whether `memoryTypeBits` is honoured), and falls back
       to Pooled with a warning.
     - Every plan computes a placement estimate, on every backend, so the saving can be reported
       before Placed is enabled.
   - **Pool key.**
     - In the key: the description fields that change the created object (dimension, size, format,
       mips, slices, sample count, usage flags, clear value, queue mask).
     - Not in the key: `debugName`, `initialState`, `keepInitialState`.
   - **Determinism.** Ties break by declaration index. The same graph therefore gets the same
     physical resources every frame, and binding caches keep hitting.
   - **Per-resource flags.**
     - `ResourceFlags::NoAlias` keeps a resource out of placement.
     - `ResourceFlags::DebugCapture` keeps it dedicated, so a capture tool sees one stable object.
   - **Heap retirement.** The heaps and placed resources of an evicted plan are retired through the
     fence values of the last frame that used them. Barrier arrays hold raw pointers, so the
     registry, not the command lists, holds the references until then.
   - **Statistics** exclude imports and history pairs. The legacy once counted imports and reported a
     false 1.11× saving.
6. **Transitions.** The walk of section 6. The output is `ResourceBarrier` batches attached to pass
   slots, each with a parallel array of reasons (11.3).
7. **Segments and caching.**
   - Segments split at queue changes and cross-queue waits, and at `RecordGranularity` when
     parallel recording is on.
   - The structural hash covers passes, accesses, descriptions and import entry/exit states, but not
     the imported objects or the passes' per-use data. It is accumulated incrementally while the
     graph is recorded.
   - On a plan-cache hit, phases 1-7 are skipped. Only the import slots are patched: O(number of
     imports).
   - **The pass-enable mask is not in the structural hash** (13.5). A plan is compiled for the superset
     of its passes.
     - Its memory plan serves every mask.
     - Its barrier schedule is cached per mask, as a partial compile of phases 2, 6 and 7.
     - So toggling a pass never reallocates.
   - **The cache is bounded** (`CompileOptions::maxCachedPlans`, default 8, least recently used).
     Plans with the same memory-plan hash share heaps.

## 8. RHI changes (ethereal-nvrhi, `slang-next` → `rdg`)

These changes extend existing interfaces in place and add new types; no existing struct changes.
The header version stays at 30 and there is no separate barrier interface. Section 8.4 lists what
that costs.

### 8.1 `IResource`: a common base for resources

```cpp
enum class ResourceType : uint8_t { Buffer, Texture, StagingTexture, SamplerFeedbackTexture,
                                    AccelStruct, OpacityMicromap };

struct HeapBinding { IHeap* heap = nullptr; uint64_t offset = 0; uint64_t size = 0; };

NVRHI_IID(IResource, "<new uuid>")
struct IResource : IRHIObject
{
    NVRHI_DECLARE_UUID_TRAITS(IResource)
    [[nodiscard]] virtual ResourceType getResourceType() const noexcept = 0;
    // Virtual (placed) resources: the heap and byte range they are bound to.
    // FE_NOT_FOUND for committed resources, and before the resource is bound.
    virtual FRESULT queryHeapBinding(HeapBinding& binding) const noexcept = 0;
};

struct IBuffer : IResource { ... };                 // was : IRHIObject
struct ITexture : IResource { ... };
struct IStagingTexture : IResource { ... };
struct ISamplerFeedbackTexture : IResource { ... };
namespace rt { struct IAccelStruct : IResource { ... }; struct IOpacityMicromap : IResource { ... }; }
```

The model is D3D12's `ID3D12Resource`: barriers name an `IResource*`. A backend dispatches on
`getResourceType()`, one virtual call, instead of a `QueryInterface` per barrier. Every resource
class adds `NVRHI_IMPLEMENTS_INTERFACE(IResource)` to its explicit QI table (nvrhi ADR 0007).
Existing calls that take `ITexture*` or `IBuffer*` are unchanged.

**Heap bindings.** `queryHeapBinding` is the legacy branches' `ITexture1/IBuffer1::queryHeapBinding`,
moved to the base. It lets the validation layer check that an aliasing barrier's resources overlap in
one heap (8.2), and lets tests assert placements.

**Binding results.** Vulkan `bindImageMemory` and `bindBufferMemory` check the `VkResult` and
return `false` on failure (2.1).

### 8.2 `ResourceBarrier` and `ICommandList::barriers`

```cpp
enum class PlaneMask : uint8_t { Color = 1, Depth = 2, Stencil = 4, All = 7 };

// The region of a texture that a barrier (or a render-graph access) names. ~0u counts mean
// "to the end". Ignored for buffers. Separate from TextureSubresourceSet, which views keep using.
struct SubresourceRegion {
    uint32_t  baseMip = 0, mipCount = ~0u, baseSlice = 0, sliceCount = ~0u;
    PlaneMask planes = PlaneMask::All;
};

enum class BarrierType : uint8_t { Transition, Uav, Aliasing };

enum class BarrierFlags : uint8_t {
    None = 0,
    SplitBegin   = 1 << 0,   // begin half; tracker is updated at the matching SplitEnd
    SplitEnd     = 1 << 1,
    Discard      = 1 << 2,   // contents before are undefined (UNDEFINED / DISCARD / DiscardResource)
    QueueRelease = 1 << 3,   // ownership release to otherQueue (Vulkan family transfer)
    QueueAcquire = 1 << 4,   // ownership acquire from otherQueue
};

struct TransitionBarrier {
    IResource*            resource;
    SubresourceRegion     region;         // ignored for buffers
    ResourceStates        before;         // combined read states are legal
    ResourceStates        after;
    ShaderType            stagesBefore;   // narrows the sync scope; None = derive from state
    ShaderType            stagesAfter;
    CommandQueue          otherQueue;     // QueueRelease / QueueAcquire only
};
struct UavBarrier      { IResource* resource; };                  // nullptr = all UAV accesses
struct AliasingBarrier { IResource* before; IResource* after; };  // before may be nullptr

struct ResourceBarrier {
    BarrierType  type = BarrierType::Uav;
    BarrierFlags flags = BarrierFlags::None;
    union {
        TransitionBarrier transition;
        UavBarrier        uav;
        AliasingBarrier   aliasing;
    };

    // SubresourceRegion has default member initialisers, so the union needs a constructor.
    ResourceBarrier() noexcept : uav{ nullptr } { }

    // Helpers in the CD3DX12_RESOURCE_BARRIER style
    static ResourceBarrier Transition(IResource* resource, ResourceStates before, ResourceStates after,
                                      const SubresourceRegion& region = {},
                                      BarrierFlags flags = BarrierFlags::None) noexcept;
    static ResourceBarrier Uav(IResource* resource) noexcept;
    static ResourceBarrier Aliasing(IResource* before, IResource* after) noexcept;
};

struct ICommandList : IRHIObject {
    ...
    // Records exactly these barriers, in order. Pending tracker barriers are committed first.
    // For resources tracked in this command list, the tracker is set to each `after`
    // (at SplitEnd for split pairs); untracked resources are not added to the tracker.
    virtual FRESULT barriers(const ResourceBarrier* barriers, uint32_t count) noexcept = 0;
};
```

The helper definitions and the layout assertions live in a new source file,
`src/common/resource-barrier.cpp`, not in the header. The assertions cover
`std::is_trivially_copyable_v<ResourceBarrier>` and the sizes and member offsets. Plans copy barrier
arrays with `memcpy`, and the user-provided default constructor does not affect trivial copyability.

**Validation** (the validation layer): it rejects a barrier when:
- `before` disagrees with the tracked state;
- a split pair is unmatched within the command list;
- a `QueueRelease` has no matching `QueueAcquire` within the submission graph;
- a barrier names a `keepInitialState` resource, whose barriers go through the tracker (5.2);
- an aliasing barrier's `before` and `after` do not overlap in bytes within one heap
  (`queryHeapBinding`, 8.1);
- a transition with a plane mask other than `All` names a resource that the command list tracks,
  because the tracker works per mip × slice and cannot represent planes. Native graph passes never
  track resources, so they are unaffected.

**Per backend:**

| Backend | Behaviour |
| --- | --- |
| D3D12 legacy | one `ResourceBarrier` call per batch, with `BEGIN_ONLY` and `END_ONLY` splits, per-plane subresource indices, `DiscardResource` after a discard transition, and aliasing barriers |
| D3D12 enhanced | one `Barrier` call with texture, buffer and global groups. Combined read layouts are mapped (this fixes the ShaderResource\|DepthRead assert), and `AccessBefore` always carries the real access |
| Vulkan | one `vkCmdPipelineBarrier2`, using events for splits and aspect masks for planes. Real queue-family indices are used for release/acquire, and like `commitBarriers` it ends dynamic rendering |
| D3D11 | validation, then a no-op. UAV barriers inside relaxed runs map to NVAPI overlap |
| CUDA | validation, then a no-op |

**Feature queries.** New `Feature` values `SplitBarriers`, `AliasingBarriers` and
`QueueOwnershipTransfer` let the profile tell which flags have native effect. On backends where a
flag has none, the call still succeeds.

### 8.3 Cross-queue synchronisation: `IFence` and `IDevice::submit`

**The primitive is a timeline fence, not an event.**

- **Timeline values compose.** A monotonically increasing value composes under transitive reduction:
  wait for the maximum value.
- **One fence serves two jobs.** The same fence that orders queues also retires frames, which
  replaces `IEventQuery` polling in the registry.
- **It maps to every backend.** D3D12, Vulkan 1.2 and D3D11.4 all have timeline fences.
- **Binary events do not fit.**
  - D3D12 has no GPU event object.
  - A `VkEvent` cannot synchronise across queues.
  - Resettable objects need reuse bookkeeping and invite reset races.
- **No name clash.** The name `IFence` avoids confusion with `IEventQuery` and with the `VkEvent`s
  that split barriers use internally.

```cpp
static constexpr uint64_t c_InfiniteTimeout = ~0ull;

struct FenceDesc {
    uint64_t initialValue = 0;
    bool     shared = false;            // exportable through the interop device
    string   debugName;
};

NVRHI_IID(IFence, "<new uuid>")
struct IFence : IRHIObject {
    NVRHI_DECLARE_UUID_TRAITS(IFence)
    [[nodiscard]] virtual const FenceDesc& getDesc() const noexcept = 0;
    // The highest value the fence has reached. Never blocks.
    [[nodiscard]] virtual uint64_t getCompletedValue() noexcept = 0;
    // CPU wait: blocks the calling thread until getCompletedValue() >= value (8.3.1).
    virtual FRESULT wait(uint64_t value, uint64_t timeoutNs = c_InfiniteTimeout) noexcept = 0;
    // CPU signal: sets the fence to value from the host.
    virtual FRESULT signal(uint64_t value) noexcept = 0;
};

struct FenceValue { IFence* fence; uint64_t value; };

struct SubmitDesc {
    ICommandList* const* commandLists = nullptr; uint32_t numCommandLists = 0;
    CommandQueue         queue = CommandQueue::Graphics;
    const FenceValue*    waits = nullptr;   uint32_t numWaits = 0;     // GPU waits before the lists start
    const FenceValue*    signals = nullptr; uint32_t numSignals = 0;   // GPU signals after the lists complete
};

struct IDevice : IRHIObject {
    ...
    virtual FRESULT  createFence(const FenceDesc& desc, IFence** fence) noexcept = 0;
    virtual uint64_t submit(const SubmitDesc& desc) noexcept = 0;   // returns the instance, as executeCommandLists
    virtual FRESULT  queueWaitFence(CommandQueue queue, IFence* fence, uint64_t value) noexcept = 0;
    virtual FRESULT  queueSignalFence(CommandQueue queue, IFence* fence, uint64_t value) noexcept = 0;
    // CPU wait on several fences: all of them (waitAll) or any one of them.
    virtual FRESULT  waitFences(const FenceValue* fences, uint32_t count, bool waitAll,
                                uint64_t timeoutNs = c_InfiniteTimeout) noexcept = 0;
};
```

`submit` is the hot path: one native submission carries its waits and signals. The standalone
`queueWaitFence` and `queueSignalFence` are GPU-side operations for interop and tools. They are
ordered with submissions to the same queue, as the interop device's existing calls are.
`executeCommandLists` and `queueWaitForCommandList` remain and are implemented on the same machinery.

| Backend | `IFence` | `submit` waits and signals |
| --- | --- | --- |
| D3D12 | `ID3D12Fence` | `queue->Wait` → `ExecuteCommandLists` → `queue->Signal` |
| Vulkan | timeline `VkSemaphore` | `VkSubmitInfo2` wait and signal infos, in one `vkQueueSubmit2`. A standalone signal is an empty submit |
| D3D11 | `ID3D11Fence` (`ID3D11Device5::CreateFence`); `FE_UNSUPPORTED` before D3D11.4 | `ID3D11DeviceContext4::Wait`/`Signal`. There is one queue, so waits are trivially satisfied |
| CUDA | host-side ring of (value, pooled `CUevent`) per fence. A shared fence is a CUDA external semaphore with true timeline values | signal: `cuEventRecord` on the queue's stream, then append. Wait: `cuStreamWaitEvent` on the earliest recorded event whose value ≥ the target. A GPU wait must be enqueued after its signal (host submission order); otherwise `FE_INVALID_ARGS`. The graph always submits producers first |

On D3D11 before 11.4, `createFence` returns `FE_UNSUPPORTED`. There the registry retires frames with
one `IEventQuery` per frame. D3D11 has one queue, so no cross-queue wait is needed (9.1).

#### 8.3.1 CPU wait and signal semantics

`IFence::wait(value, timeoutNs)` waits for "at least", never "exactly": it returns once
`getCompletedValue() >= value`.

| Call | Behaviour | Returns |
| --- | --- | --- |
| any call where the value is already reached | returns at once, without a kernel call | `FS_OK` |
| `wait(v, 0)` | polls and never blocks | `FS_OK` or `FE_WAIT_TIMEOUT` |
| `wait(v, n)`, n finite | blocks for at most n nanoseconds | `FS_OK` or `FE_WAIT_TIMEOUT` |
| `wait(v)` or `wait(v, c_InfiniteTimeout)` | blocks until the value is reached, with no time limit | `FS_OK`; never `FE_WAIT_TIMEOUT` |
| device lost during any wait | the wait ends instead of blocking forever | `FE_GENERIC_ERROR`, and the device reports the loss through its message callback |

Rules:
- **Unreachable values.** An infinite wait for a value that nothing will ever signal blocks forever,
  as it does on every native API. To catch this, the validation layer reports a wait for a value
  above every signal that has been submitted or set from the host, before it blocks.
- **Threads.** `wait`, `getCompletedValue` and `waitFences` may be called from any thread,
  concurrently.
- **CPU signals** must increase the value. `signal(v)` with `v` not above the current value returns
  `FE_INVALID_ARGS`.
- **`waitFences`** follows the same table. With `waitAll = false` it returns when any one fence
  reaches its value.

Usage:

```cpp
// Frame retirement: block until the GPU has finished frame N-2 on the graphics queue.
const uint64_t target = frameFenceValues[(frameIndex - 2) % c_FramesInFlight];
if (graphicsFence->getCompletedValue() < target)
    NVRHI_CHECK(graphicsFence->wait(target));               // infinite timeout

// Non-blocking check, for example before reusing a pooled resource.
const bool done = graphicsFence->wait(target, 0) == nvrhi::FS_OK;

// Both queues, at most 100 ms.
const nvrhi::FenceValue values[] = { { graphicsFence, gfxTarget }, { computeFence, computeTarget } };
const nvrhi::FRESULT result = device->waitFences(values, 2, /*waitAll*/ true, 100'000'000);
```

CPU wait per backend:

| Backend | Infinite wait | Finite wait | `waitFences` |
| --- | --- | --- | --- |
| D3D12 | `SetEventOnCompletion` + `WaitForSingleObject(INFINITE)` | the same with a millisecond timeout, rounded up | `ID3D12Device1::SetEventOnMultipleFenceCompletion` (all or any) |
| Vulkan | `vkWaitSemaphores(UINT64_MAX)` | `vkWaitSemaphores(timeoutNs)` | `vkWaitSemaphores`, with `VK_SEMAPHORE_WAIT_ANY_BIT` for any |
| D3D11 | `ID3D11Fence::SetEventOnCompletion` + `WaitForSingleObject` | the same with a timeout | one event per fence + `WaitForMultipleObjects` |
| CUDA | wait (on a condition variable) until a signal ≥ value is recorded, then `cuEventSynchronize` | `cuEventQuery` with back-off until the deadline | per fence, in turn (all), or polling (any) |

**CPU signal per backend.** D3D12 uses `ID3D12Fence::Signal`, Vulkan `vkSignalSemaphore` and D3D11
`ID3D11Fence::Signal`. On CUDA the ring records a host-completed entry. A GPU wait that only a later
CPU signal can satisfy is rejected with `FE_INVALID_ARGS`, under the same ordering rule as GPU
signals.

CUDA stream memory operations (`cuStreamWriteValue64` and `cuStreamWaitValue64` with
`CU_STREAM_WAIT_VALUE_GEQ`) would give true timeline semantics and lift that ordering rule. Whether
the target Windows drivers support them is checked in step 1. Until then, the event ring is the
design.

**Interop.** `IExternalFence` stays the interop handle type. A fence created with `shared = true`
is the intended source for an exported fence. Unifying `IGraphicsInteropDevice::createFence` with
`IDevice::createFence` is a follow-up.

### 8.4 ABI consequences

The header version stays at 30, so `nvrhiVerifyHeaderVersion` cannot detect a mismatched binary.
These changes alter existing virtual tables:

- `barriers` is appended to `nvrhi::ICommandList`, which also shifts the derived
  `d3d12::ICommandList`.
- `createFence`, `submit`, the fence queue calls and `waitFences` are appended to `IDevice`, which
  shifts the derived `d3d12::IDevice` and `vulkan::IDevice`.
- `IResource` (`getResourceType`, `queryHeapBinding`) is inserted under each resource interface.

No existing struct layout changes: `SubresourceRegion` and the barrier, fence and submit types are
new, and `TextureSubresourceSet` is untouched.

The rule for the `rdg` branches is therefore that nvrhi, donut, the samples and every installed
consumer package are rebuilt together. The installed-consumer tests from slang-next are rerun at
step 1, and the ABI layout assertions are updated in the same commit.

## 9. Backend lowering

### 9.1 Executor

**Prepare.** Before any segment is recorded, the executor calls `Prepare` for every pass use. It
does so serially, in schedule order (12, 13.1).
- Pipelines are created there, so recording, possibly on worker threads, creates no objects.
- Static uploads are recorded there, on one graphics command list submitted before the frame's first
  segment.
- The legacy's first compile spent 3.7–6.2 ms creating pipelines.

The executor then handles each segment in order:

1. **Acquire a command list.** It is taken from the registry's pool for the segment's queue: one list
   per segment slot, reused across frames, and never created in steady state.
2. **Start tracking only where needed.** `beginTracking*State` is called only for resources that
   Tracked-mode passes in the segment touch. Native passes never consult the tracker, so a
   graph-native frame makes no tracker calls at all.
3. **Run each pass:**
   1. Call `barriers(plan.prologue)`, a pointer into plan memory.
   2. Call the pass's `Execute(context, data)`.
   3. Call `barriers(plan.epilogue)`.
4. **Pass modes:**
   - **Native.** `setEnableAutomaticBarriers(false)` and `setEnableUavBarriersFor*` false for the
     body. The plan is the only barrier source, which is what makes `RelaxedOrder` work.
   - **Tracked** (`PassFlags::Tracked`, for passes whose `Execute` reuses code that relies on
     automatic barriers):
     - Automatic barriers stay on. The prologue batch has already moved the tracker, so a correctly
       declared body triggers nothing.
     - In validation builds the executor compares tracker snapshots before and after the body, and
       reports any change as an undeclared access, with the pass name.
     - Declarations must use exact states, including nvrhi's visibility-exact shader-resource states
       (2.1). Otherwise the cross-check fires on every wrapped pass.
   - **Restore** (`PassFlags::Restore`). This is a Tracked pass whose body changes states
     internally, for example a UAV write followed by an SRV read in SsaoPass, MipMapGenPass and
     ToneMappingPass, or an SDK body such as VXGI.
     - After the body, the executor uses the tracker to return each declared range to its declared
       state, and commits. The next plan barrier's `before` is then right in every build.
     - Restoring costs state calls, so it is chosen per pass. Removing it from passes that did not
       need it cut the legacy's state calls per frame from 37 to 27.
5. **Close and submit** with `IDevice::submit`, attaching the plan's fence waits and signals.
   - The registry records the end states of persistent resources, per subresource and per
     physical resource (5.2).
   - It also records the per-queue fence values for retirement. Heaps, pooled resources and command
     lists are reused only after `getCompletedValue()` reaches the frame's values. When a pool is
     exhausted, the registry blocks with `waitFences` on the oldest frame in flight.
   - On D3D11 before 11.4 it uses one `IEventQuery` per frame instead (8.3).
6. **Fallback.** On a device without `barriers` (a stock nvrhi build), batches lower through
   `setTextureState`/`commitBarriers`.
   - Split barriers become joined, aliasing is disabled (Pooled tier) and incompatible reads fall back
     to groups.
   - Regions convert to `TextureSubresourceSet`; plane masks are widened to all planes.
   - Cross-queue waits use `queueWaitForCommandList`.

### 9.2 Backend profiles

`BackendProfile` is computed once per device. The compiler sees only the profile.

| | D3D12 | Vulkan | D3D11 | CUDA |
| --- | --- | --- | --- | --- |
| Barrier model | legacy states or enhanced layout/access/sync | layout/access/stage (sync2) | implicit | implicit, stream ordered |
| Lattice | per model (6.3) | Vulkan table | trivial | trivial |
| Planes | plane slices | aspect masks | ignored | ignored |
| Split barriers | yes | events, policy-limited | no | no |
| Memory tier | Placed | Pooled, then Placed after the `memoryTypeBits` fix | Pooled | Pooled (CUDA virtual memory later) |
| Queues | graphics, compute, copy | graphics, compute, copy (families, ownership transfer) | graphics only; async demoted | one stream per `CommandQueue` |
| Cross-queue sync | `IFence` (`ID3D12Fence`) | `IFence` (timeline semaphore) | none needed | `IFence` (event ring) |
| Pass types | all | all | Raster, Compute, Copy | Compute, Copy, RayTracing (OptiX); Raster is a compile error |
| Plan verified | yes | yes | yes, simulated | yes, simulated |

## 10. Performance design (R5)

### 10.1 CPU

**Recording**
- **Frame arena.** All per-frame graph data lives in a builder-owned arena, reset each frame:
  passes, accesses, resource records, each pass use's data and the lambda-pass objects of 12.1.
- **Allocation-free steady state.** There is no `std::function` and no per-access heap allocation.
- **Long-lived passes.** donut pass objects are created once and added every frame. Only their
  per-use data is allocated, from the arena.

**Cache hits**
- The structural hash is accumulated while declarations are recorded, so the plan lookup at `Finish`
  is a single hash-table probe.
- A hit runs no compile phase. The executor patches import slots (O(number of imports)) and replays
  the prebuilt barrier arrays.
- No `ResourceBarrier` is built per frame. Pointers to transient and persistent resources are fixed
  in the plan. Only two things are patched: imported pointers, and history pairs, which select their
  textures by frame parity (O(number of pairs), 5.2).

**Compiling on a miss**
- **Data layout.** Structure-of-arrays with dense indices.
- **Reader sets** are bitsets: `uint64_t` up to 64 passes, a dynamic bitset beyond that.
- **Interval maps** keep small inline storage, and inner loops use no hash maps.
- **Complexity.** O(P·A·log S), where P is passes, A is accesses per pass and S is intervals per
  resource. Coalescing keeps S near 1 for uniformly used resources.

**Executing**
- **Few calls per pass.** No virtual calls per barrier: one `barriers()` call per non-empty slot,
  plus one `Execute` call.
- **Tracker.** Its cost is paid only by Tracked passes (9.1).
- **No object churn in steady state:**
  - Command lists are pooled.
  - Framebuffers and binding sets are cached by allocation generation, so a plan hit creates none.
  - Placed and pooled resources are instantiated once per plan.
- **Parallel recording.** Segments are recorded on worker threads through a host-supplied
  task-scheduler callback, with no threading-library dependency. Submission stays in plan order.
  - **Rules**, from the legacy measurements. On Vulkan, 64 passes recorded in 91 µs on one list
    against 50 µs on four threads.
    - Record in parallel only from 16 passes per segment. Below that, one list is faster.
    - Use at most as many ranges as worker threads. Each range costs about 0.7 µs, on top of about
      1.4 µs per pass.
    - Call `runGarbageCollection` once per frame. Otherwise every range opens a new Vulkan command
      pool, at about 25 µs.
    - D3D11 records serially.
  - **Prerequisites in donut** (2.2):
    - `BindingCache` creates missed binding sets outside its lock, inserts them under it, and drops
      duplicates.
    - `CommonRenderPasses::BlitTexture` guards its pipeline cache.
    - Volatile constant buffers are written only in `Execute`, on the command list that uses them
      (13.1).

**Diagnostics**
- Reason arrays, the JSON dump and the verifier are off the hot path. They are computed on a compile
  miss, or on demand.

### 10.2 GPU

- **Fewest barriers.** Read epochs merge (6.3), persistent resources skip restore transitions, and
  UAV barriers are dropped for relaxed runs and disjoint ranges.
- **Narrowest scopes.** Stages come from declarations, so compute-only readers do not stall graphics
  stages. Plane masks keep a stencil write from transitioning the depth plane.
- **Overlap.** Split barriers hide transition latency. Async compute overlaps graphics, synchronised
  by one fence wait per dependency, already reduced.
- **Bandwidth and footprint.** Aliasing shrinks transient memory. Discards avoid preserving or
  decompressing contents nobody reads, and recorded load/store intent prepares for native render
  passes.
- **Lattice cost model.** `LatticePolicy` holds per-backend costs: for example Vulkan `GENERAL`
  against a second transition. These costs decide between a merged state and split groups, and they
  can be tuned per vendor once measured.

### 10.3 Budgets (exit gates)

| Metric | Budget | Measured where |
| --- | --- | --- |
| Compile, cache miss, 64 passes / 256 resources | ≤ 1 ms | `rdg_bench` (device-free) |
| Compile, cache miss, 1024 passes | ≤ 16 ms | `rdg_bench` |
| Frame cost on a cache hit (record + `Finish` + lookup + patch), 64 passes | ≤ 0.05 ms | `rdg_bench` |
| Executor overhead per frame, excluding pass bodies | ≤ 0.2 ms | sample with an empty-body variant |
| Heap allocations per frame, steady state | 0 | allocation hook in `rdg_bench` and the sample |
| `create*` calls per frame, steady state | 0 | nvrhi validation-layer counters |
| Barriers per frame | ≤ original sample, each with a reason | plan counters and native capture |
| GPU frame time | ≤ original sample | timer queries |
| CPU frame time | ≤ original sample | sample frame timer |
| Peak transient memory | ≤ 60 % of the sum of poolable transient sizes, excluding imports and history, on a graph with reusable transients (bloom chain, SSAO, tone-mapping histogram). On the 6.11 frame, where every transient is live at DeferredLighting, it is reported but not gated | plan statistics |
| Parallel recording, 64 passes, 4 threads | ≤ 60 % of single-list recording time | `rdg_bench` |
| First frame after a plan miss, including `Prepare` and pipeline creation | reported, not gated | sample frame timer |

### 10.4 Measurement protocol

- **Builds.** Release builds, NVIDIA adapter selected explicitly.
- **Runs.** One GPU process at a time, with before/after runs alternated against thermal drift.
  Report the median of at least 300 frames after 100 warm-up frames.
- **Validation runs** are separate from timing runs. Each one first confirms that the validation
  layer is loaded, by provoking a known message. A Debug run without layers reports "clean" for
  nothing, which happened on the legacy's Linux runs.
- **Determinism.** Graph samples and their originals take `-fixedstep`, `-frames N` and
  `-screenshot`. `tools/ab_compare.py` compares them pixel by pixel.
- **Results.** Numbers go into the plan's execution record with the commit hashes.

## 11. Correctness and diagnostics

### 11.1 Device-free plan verifier

`VerifyPlan(compiled, graph)` replays the plan against a simulated per-subresource state machine,
using the profile's rules. It asserts that:

- every access sees a compatible state;
- every hazard (RAW, WAR, WAW, UAV) has a barrier or a fence wait between its two accesses;
- no split is left open at the end of a segment;
- aliases never overlap in both lifetime and bytes;
- every discard-before is a full write or a clear;
- every release has its acquire;
- every exit state matches its declaration;
- every state and stage is legal on the queue that executes it (6.8);
- two consecutive frames, and a switch between two cached plans, are free of hazards across the
  boundary (6.12).

It runs in unit tests over a corpus of graphs for all four profiles. In debug builds it can also run
on every compile miss.

### 11.2 GPU validation

- **Tracker cross-check:** Tracked mode, 9.1.
- **Reflection cross-check:** in debug builds a pass may register its `IShaderProgram`. Its reflected
  SRV and UAV slots must match the declared accesses.
- **Native validation:**
  - D3D12 debug layer, including GPU-based validation.
  - Vulkan validation, including synchronisation validation.
  - CUDA Compute Sanitizer.

### 11.3 Diagnostics

**Barrier reasons.** Every barrier carries one of these reasons:

| Reason | Meaning |
| --- | --- |
| `RAW` | read after write |
| `WAR` | write after read |
| `WAW` | write after write |
| `UavOrder` | UAV-to-UAV ordering |
| `ReadGroupChange` | incompatible readers in one epoch |
| `Alias` | first use after an aliased resource |
| `QueueTransfer` | cross-queue ownership release/acquire |
| `Discard` | discard-before initialisation |
| `ExitState` | transition to an import's exit state |
| `Persistent` | a persistent resource's cross-frame state |

Every adjacent raster pair that does not merge also records a reason.

**Outputs of `ICompiledRenderGraph`:**
- a JSON dump of passes, lifetimes, heap offsets, batches with reasons, and fence waits;
- a Graphviz export;
- the counters of 10.3;
- per-pass GPU timers (`ExecuteDesc::timers`) and run statistics (frame, compile, record and submit
  times; barrier, state-call and allocation counts).

GPU markers use the pass names.

**Visualizer.** `app::RenderGraphVisualizer`, an `app::IAppLayer`, draws the data above with ImGui:
lifetimes, heap placement, barriers with their reasons, and pass toggles that drive
`SetPassEnabled` (13.5).

### 11.4 Debug switches

`CompileOptions::debugFlags` can be changed at run time. A change costs one plan-cache miss.

| Switch | Effect | Use |
| --- | --- | --- |
| `ForceDedicated` | every transient gets its own memory | bit-exact reference for aliasing bugs |
| `NoAliasing` | Placed tier without overlap | isolates aliasing from placement |
| `BarrierAfterEveryPass` | a full barrier after every pass | isolates missing barriers |
| `FillTransients` | discard-before also fills with a pattern | exposes reads of undefined contents |
| `SerializeQueues` | async passes run on the graphics queue | isolates cross-queue bugs |
| `StrictValidation` | runs the verifier on every frame, not only on a miss | |
| `SkipAliasingBarriers` | tests only: drops aliasing barriers | negative test, which must fail, to prove the aliasing test detects the fault |

## 12. Public interfaces

`include/donut/render/RenderGraph.h`, abridged. IIDs are placeholders.

```cpp
namespace donut::render
{
    // A texture or buffer in one graph: index in the low 32 bits, version in the high 32 (5.1).
    // An enum, so it may cross virtual calls by value (rule R1).
    enum class ResourceId : uint64_t {};
    constexpr ResourceId InvalidResourceId = ResourceId(~0ull);
    constexpr ResourceId MakeResourceId(uint32_t index, uint32_t version) noexcept;
    constexpr uint32_t GetResourceIndex(ResourceId id) noexcept;
    constexpr uint32_t GetResourceVersion(ResourceId id) noexcept;

    enum class PassId : uint32_t {};

    enum class Access : uint32_t { /* 6.1 */ };
    enum class AccessFlags : uint32_t { None = 0, Clear = 1, FullWrite = 2, RelaxedOrder = 4, Preserve = 8 };
    enum class PassType : uint8_t { Raster, Compute, Copy, RayTracing };
    enum class PassFlags : uint32_t { None = 0, AsyncCompute = 1, NeverCull = 2, SideEffect = 4, Tracked = 8,
                                      Restore = 16 /* implies Tracked */ };
    enum class ResourceFlags : uint32_t { None = 0, NoAlias = 1, DebugCapture = 2 };
    enum class DisabledOutput : uint8_t { Cull, Substitute, Passthrough };   // 13.5

    struct ClearValue { float color[4]; float depth; uint8_t stencil; };
    struct PassDesc   { const char* name; PassType type; PassFlags flags; uint32_t exclusionGroup = 0; };  // 0 = none

    NVRHI_IID(IPassBuilder, "...")
    struct IPassBuilder : nvrhi::IObject
    {
        NVRHI_DECLARE_UUID_TRAITS(IPassBuilder)
        // Reads do not create versions. The region is ignored for buffers; {} is the whole resource.
        virtual void Read(ResourceId resource, Access access, nvrhi::ShaderType stages,
                          const nvrhi::SubresourceRegion& region) noexcept = 0;
        // Returns the new version.
        virtual ResourceId Write(ResourceId resource, Access access, nvrhi::ShaderType stages,
                                 const nvrhi::SubresourceRegion& region, AccessFlags flags) noexcept = 0;
        virtual ResourceId SetColorTarget(uint32_t slot, ResourceId texture,
                                          const nvrhi::SubresourceRegion& region,
                                          AccessFlags flags, _In_opt_ const ClearValue* clear) noexcept = 0;
        virtual ResourceId SetDepthTarget(ResourceId texture, bool readOnly, AccessFlags flags,
                                          _In_opt_ const ClearValue* clear) noexcept = 0;
        // What consumers of `written` see when this pass is disabled (13.5).
        virtual void SetDisabledOutput(ResourceId written, DisabledOutput policy,
                                       ResourceId substituteOrInput) noexcept = 0;
    };

    // Serial, before recording: pipelines and static uploads (13.1).
    NVRHI_IID(IPrepareContext, "...")
    struct IPrepareContext : nvrhi::IObject
    {
        NVRHI_DECLARE_UUID_TRAITS(IPrepareContext)
        virtual nvrhi::IDevice* GetDevice() noexcept = 0;
        virtual nvrhi::ICommandList* GetUploadCommandList() noexcept = 0;   // submitted before the frame
        virtual const nvrhi::FramebufferInfoEx& GetFramebufferInfo() noexcept = 0;   // raster passes
        virtual const nvrhi::TextureDesc* GetTextureDesc(ResourceId id) noexcept = 0;   // nullptr for a buffer
        virtual const nvrhi::BufferDesc* GetBufferDesc(ResourceId id) noexcept = 0;     // nullptr for a texture
    };

    NVRHI_IID(IPassContext, "...")
    struct IPassContext : nvrhi::IObject
    {
        NVRHI_DECLARE_UUID_TRAITS(IPassContext)
        virtual nvrhi::ICommandList* GetCommandList() noexcept = 0;
        virtual nvrhi::IResource* GetResource(ResourceId id) noexcept = 0;
        virtual nvrhi::ITexture* GetTexture(ResourceId id) noexcept = 0;    // nullptr for a buffer
        virtual nvrhi::IBuffer* GetBuffer(ResourceId id) noexcept = 0;      // nullptr for a texture
        virtual nvrhi::IFramebuffer* GetFramebuffer() noexcept = 0;         // cached per allocation generation
        virtual bool IsNewAllocation(ResourceId id) noexcept = 0;
        virtual uint64_t GetFrameIndex() noexcept = 0;
    };

    // The base of every donut pass (13.1).
    NVRHI_IID(IGpuPass, "...")
    struct IGpuPass : nvrhi::IObject
    {
        NVRHI_DECLARE_UUID_TRAITS(IGpuPass)
        // Declares the accesses of one use; `data` is that use's frame-arena record.
        // Called inside AddPass. FE_UNSUPPORTED: this pass cannot run in a graph yet.
        virtual nvrhi::FRESULT Setup(IPassBuilder* builder, void* data) noexcept = 0;
        // Serial, before any recording. Creates pipelines and records static uploads.
        // Must not write volatile constant buffers.
        virtual nvrhi::FRESULT Prepare(IPrepareContext* context, void* data) noexcept = 0;
        // Records that use. May run on a worker thread.
        virtual void Execute(IPassContext* context, const void* data) noexcept = 0;
        // The registry released the resources this pass's caches may reference (resize, plan
        // eviction). Drop framebuffers and binding sets that point at them.
        virtual void OnResourcesReleased() noexcept = 0;
    };

    NVRHI_IID(IRenderGraphBuilder, "...")
    struct IRenderGraphBuilder : nvrhi::IObject
    {
        NVRHI_DECLARE_UUID_TRAITS(IRenderGraphBuilder)
        virtual void Reset() noexcept = 0;                            // start a frame; resets the arena
        virtual ResourceId CreateTexture(const nvrhi::TextureDesc& desc, ResourceFlags flags) noexcept = 0;
        virtual ResourceId CreateBuffer(const nvrhi::BufferDesc& desc, ResourceFlags flags) noexcept = 0;
        virtual ResourceId ImportTexture(nvrhi::ITexture* texture, nvrhi::ResourceStates entry,
                                         nvrhi::ResourceStates exit) noexcept = 0;
        virtual ResourceId ImportHostKeptTexture(nvrhi::ITexture* texture) noexcept = 0;
        virtual ResourceId ImportBuffer(nvrhi::IBuffer* buffer, nvrhi::ResourceStates entry,
                                        nvrhi::ResourceStates exit) noexcept = 0;
        virtual ResourceId GetPersistentTexture(const char* name, const nvrhi::TextureDesc& desc) noexcept = 0;
        virtual ResourceId GetPersistentBuffer(const char* name, const nvrhi::BufferDesc& desc) noexcept = 0;
        virtual void GetHistoryPair(const char* name, const nvrhi::TextureDesc& desc,
                                    ResourceId* current, ResourceId* previous) noexcept = 0;
        virtual void Extract(ResourceId texture, nvrhi::ResourceStates exit, nvrhi::ITexture** outTexture) noexcept = 0;
        // Holds a reference to `pass` until Reset; `data` must come from AllocateFrameData.
        virtual nvrhi::FRESULT AddPass(const PassDesc& desc, IGpuPass* pass, void* data,
                                       _Out_opt_ PassId* outPass) noexcept = 0;
        // Not part of the structural hash (7.7, 13.5).
        virtual void SetPassEnabled(PassId pass, bool enabled) noexcept = 0;
        virtual void* AllocateFrameData(size_t size, size_t alignment) noexcept = 0;   // frame arena
        virtual void PushMarker(const char* name) noexcept = 0;
        virtual void PopMarker() noexcept = 0;
        virtual nvrhi::FRESULT Finish(IRenderGraph** outGraph) noexcept = 0;
    };

    NVRHI_IID(IRenderGraph, "...")
    struct IRenderGraph : nvrhi::IObject
    {
        NVRHI_DECLARE_UUID_TRAITS(IRenderGraph)
        virtual uint64_t GetStructuralHash() noexcept = 0;
        virtual uint64_t GetEnableMaskHash() noexcept = 0;
        virtual uint32_t GetPassCount() noexcept = 0;
        virtual uint32_t GetResourceCount() noexcept = 0;
    };

    NVRHI_IID(IRenderGraphCompiler, "...")
    struct IRenderGraphCompiler : nvrhi::IObject
    {
        NVRHI_DECLARE_UUID_TRAITS(IRenderGraphCompiler)
        virtual nvrhi::FRESULT Compile(IRenderGraph* graph, const BackendProfile& profile,
                                       const CompileOptions& options, IResourceRegistry* planCache,
                                       ICompiledRenderGraph** outPlan) noexcept = 0;
    };

    NVRHI_IID(IRenderGraphExecutor, "...")
    struct IRenderGraphExecutor : nvrhi::IObject
    {
        NVRHI_DECLARE_UUID_TRAITS(IRenderGraphExecutor)
        virtual nvrhi::FRESULT Execute(ICompiledRenderGraph* plan, IRenderGraph* graph,
                                       const ExecuteDesc& desc) noexcept = 0;
    };

    nvrhi::FRESULT CreateResourceRegistry(nvrhi::IDevice* device, IResourceRegistry** out) noexcept;
    nvrhi::FRESULT CreateRenderGraphBuilder(nvrhi::IDevice* device, IResourceRegistry* registry,
                                            IRenderGraphBuilder** out) noexcept;
    nvrhi::FRESULT CreateRenderGraphCompiler(IRenderGraphCompiler** out) noexcept;
    nvrhi::FRESULT CreateRenderGraphExecutor(nvrhi::IDevice* device, IRenderGraphExecutor** out) noexcept;
    nvrhi::FRESULT ComputeBackendProfile(nvrhi::IDevice* device, BackendProfile* out) noexcept;
}
```

As in nvrhi's interface style (`com-interface-abi.md` 3.2), the virtual functions take no default
arguments. Callers pass `{}` for a whole resource and `ResourceFlags::None` explicitly.

The rest of the header follows the same style:
- `BackendProfile`, `CompileOptions` and `ExecuteDesc` are plain structs. `CompileOptions` holds
  `placedResources`, `maxCachedPlans` and `debugFlags` (7.5, 7.7, 11.4). `ExecuteDesc` holds the
  task-scheduler callback and the timer switch.
- `ICompiledRenderGraph` provides queries and the dump.
- `IResourceRegistry` holds persistent resources, the plan cache, the pools and caches, the fences and
  retirement.

The builder is reused across frames: `Reset` starts a frame instead of creating a new builder object,
which keeps the frame path free of allocations.

### 12.1 Lambda helper (header-only, outside the ABI surface)

```cpp
// include/donut/render/RenderGraphLambdaPass.h
template <typename Data, typename SetupFn, typename ExecFn>
const Data& AddLambdaPass(IRenderGraphBuilder* graph, const PassDesc& desc, SetupFn&& setup, ExecFn&& exec);
```

The helper places an `IGpuPass` object and its `Data` in the frame arena (`AllocateFrameData`), and
the builder destroys them at `Reset`. The object is an `ObjectImpl<IGpuPass>` whose virtual table
lives in the caller's module. Its reference count protects only against misuse: the builder owns the
object for the frame. Its `Prepare` and `OnResourcesReleased` do nothing unless the caller passes a
prepare function. Samples use the helper for one-off passes; donut's own passes are long-lived
classes (section 13).

## 13. donut's passes in the graph

### 13.1 One base: `IGpuPass`

Every donut pass derives from `IGpuPass`, through the existing `ObjectImpl` pattern:

```cpp
class BloomPass : public nvrhi::ObjectImpl<IGpuPass> { ... };     // was ObjectImpl<nvrhi::IObject>

class IGeometryPass : public nvrhi::ObjectImpl<IGpuPass>          // was ObjectImpl<nvrhi::IObject>
{
public:
    NVRHI_BEGIN_INTERFACE_TABLE_INLINE(IGeometryPass)
    NVRHI_IMPLEMENTS_INTERFACE(IGpuPass)
    NVRHI_IMPLEMENTS_INTERFACE(nvrhi::IObject)
    NVRHI_END_INTERFACE_TABLE()
    ...
};
```

This covers all the passes in 2.2:
- The seven `ObjectImpl<IObject>` passes and `IGeometryPass` change their base.
- The four geometry passes inherit it through `IGeometryPass`.
- The six passes with no base become reference counted. Their owners in donut and the samples
  switch to `nvrhi::RefCountPtr`.

The graph knows nothing else about a pass.

**Lifecycle.**

| Call | When | What it does |
| --- | --- | --- |
| `Setup` | inside `AddPass`, every frame | declares the accesses, and the disabled-output policies (13.5) |
| `Prepare` | serially, after compile and before recording | creates pipelines (from `GetFramebufferInfo` and the descriptions) and records static uploads |
| `Execute` | while recording, possibly on a worker thread | records commands. Volatile constant buffers are written here only, on the list that uses them. The legacy enforced this rule with an upload guard, and the validation build keeps it |
| `OnResourcesReleased` | after a resize or a plan eviction | drops cached framebuffers and binding sets, so that they do not pin pooled memory |

### 13.2 Adding a pass to a graph

Each pass gets a typed entry point, `AddToGraph`. It allocates the use's data in the frame arena,
calls `AddPass` with itself, and returns the output ids. `Setup` reads the data to declare the
accesses; `Execute` reads it, resolves the ids through `IPassContext`, and records the work through
the same code that the immediate entry point uses.

```cpp
// DeferredLightingPass.h
struct DeferredLightingGraphInputs  { ResourceId depth, gbuffer[4], ambientOcclusion, shadowMap; const ICompositeView* view; ... };
struct DeferredLightingGraphOutputs { ResourceId output; };

DeferredLightingGraphOutputs AddToGraph(IRenderGraphBuilder* graph, const DeferredLightingGraphInputs& inputs);

// DeferredLightingPass.cpp
DeferredLightingGraphOutputs DeferredLightingPass::AddToGraph(IRenderGraphBuilder* graph,
                                                              const DeferredLightingGraphInputs& inputs)
{
    auto* data = new (graph->AllocateFrameData(sizeof(UseData), alignof(UseData))) UseData{ inputs };
    graph->AddPass({ "DeferredLighting", PassType::Compute, PassFlags::None }, this, data, nullptr);
    return { data->output };   // written by Setup
}

nvrhi::FRESULT DeferredLightingPass::Setup(IPassBuilder* builder, void* data) noexcept
{
    auto& use = *static_cast<UseData*>(data);
    builder->Read(use.inputs.depth, Access::ShaderRead, nvrhi::ShaderType::Compute, {});
    ...
    use.output = builder->Write(use.output, Access::StorageWrite, nvrhi::ShaderType::Compute,
                                {}, AccessFlags::FullWrite);
    return nvrhi::FS_OK;
}
```

Rules:
- **Several uses per frame.** One pass object can be added several times, for example DepthPass once
  per shadow cascade. Each use has its own arena data.
- **Views.** Overloads that take an `ICompositeView` add one use per child view, for stereo or cube
  faces. Per-view temporaries have disjoint lifetimes, so the memory plan gives them the same memory
  (7.5). No extra API is needed; a test checks the folding.
- **Immediate entry points stay.** The existing calls, such as `DeferredLightingPass::Render(
  commandList, inputs, view)`, keep working, so samples that do not use the graph are unaffected.
  Graph and immediate paths share the recording code.
- **Passes that cannot run in a graph yet** return `FE_UNSUPPORTED` from `Setup`. `AddPass` then
  fails with a diagnostic naming the pass, and the caller imports the results instead.

### 13.3 Mapping of the shipped passes

| Pass | Graph entry | Mode | Pass changes |
| --- | --- | --- | --- |
| DeferredLightingPass | one compute pass; `Inputs` from ids | Native | none beyond the base |
| GBufferFillPass / DepthPass / ForwardShadingPass / MaterialIDPass | raster via `RenderCompositeView`; framebuffer from `IPassContext` | Tracked, then Native | PSO cache key gains `FramebufferInfo` |
| CascadedShadowMap / PlanarShadowMap (not passes) | shadow texture persistent; DepthPass used once per slice | Tracked | none |
| SsaoPass | one pass; internal arrays stay internal at first | Restore | later: per-call textures, so they become graph transients |
| BloomPass | graph-native chain (downsample/blur per mip) | Native | shaders reused; class chain bypassed |
| TemporalAntiAliasingPass | motion vectors + resolve; `GetHistoryPair`; `feedbackIsValid = !IsNewAllocation(prev)` | Native | per-call textures; `AdvanceFrame` no longer swaps |
| ToneMappingPass | histogram transient, exposure persistent | Native | per-call framebuffer and buffers |
| SkyPass / EnvironmentMapPass | one pass each | Native | per-call framebuffer or texture |
| MipMapGenPass | one pass; the body writes and then reads mips | Restore | per-call texture |
| SDK bodies (VXGI in the samples) | one pass | Restore | none |
| LightProbeProcessingPass / PixelReadbackPass / ManipulatorPass / JointsRenderPass / DLSS | `Setup` returns `FE_UNSUPPORTED`; results imported | | base only |

**Changes to the existing passes are additive:**
- the base class;
- `AddToGraph`, `Setup` and `Execute`;
- overloads that take formats or targets per call.

The existing API keeps working.

### 13.4 App integration

`app::RenderGraphLayer` (an `app::IAppLayer`, 3.3) owns the registry and the builder. Each frame it:
1. imports the back buffer as host-kept;
2. calls a virtual `BuildGraph`;
3. compiles and executes.

A resize changes resource descriptions, which changes the hash, which forces a recompile. No pass is
recreated.

### 13.5 Conditional passes and exclusion groups

**Toggling.** `AddPass` returns a `PassId`. `SetPassEnabled(id, enabled)`, called before `Finish`,
turns a pass off without changing the structural hash (7.7). The plan's memory therefore stays, and
a toggle costs at most one partial compile per new mask.

**Disabled outputs.** A disabled pass's outputs follow the policy its `Setup` declared with
`SetDisabledOutput`:

| Policy | Effect | Example |
| --- | --- | --- |
| `Cull` (default) | consumers that need the output are disabled too | debug overlays |
| `Substitute` | consumers read a substitute resource instead | SSAO off: a 1×1 white AO texture |
| `Passthrough` | the output becomes an input of the same description | bloom off: HDR passes through |

The compiler checks that each substitute or passthrough input matches the output's description and
reads.

**Exclusion groups.** Passes with the same `PassDesc::exclusionGroup` are never enabled together, and
validation rejects a mask that enables two of them. Resources used only by different members of a
group may share memory (7.4).

## 14. Decisions

These are the decisions made in review.

### 14.1 Branches (decided)

Fresh `rdg` branches, based on `slang-next`, carry the feature development:
- the aggregate, plus `ethereal-nvrhi`, `ethereal-donut` and `ethereal-samples`;
- each started from the commit that the aggregate's `slang-next` head records for it.

The aggregate worktree is `.worktrees/rdg`. The slang-next worktree now lives at
`.worktrees/ethereal-slang-next`. Its nvrhi and samples checkouts are detached at newer commits than
the local `slang-next` branches, so step 0 starts each submodule branch from the gitlink, not from
the branch name.

### 14.2 RHI extension shape (decided)

- **`ICommandList` is extended in place.** It gains `barriers(const ResourceBarrier*, uint32_t)`;
  there is no `IBarrierCommandList`.
- **`ResourceBarrier` is a single type.** It is a D3D12-style union of transition, UAV and aliasing
  barriers, distinguished by `type`. Transitions carry a `SubresourceRegion`.
- **New `IResource` base** under `IBuffer`, `ITexture`, `IStagingTexture`,
  `ISamplerFeedbackTexture`, `IAccelStruct` and `IOpacityMicromap`.
- **New `SubresourceRegion`** (mips, slices, plane mask), shared by barriers and graph accesses.
  `TextureSubresourceSet` is not changed.
- **No header-version bump.** See 8.4 for what that requires.
- **Layout assertions** for `ResourceBarrier` live in the source file, not the header.

### 14.3 Async compute and cross-queue synchronisation (decided)

- **Async compute** runs on `ICommandList`s created for `CommandQueue::Compute` (a `CUstream` on
  CUDA).
- **Cross-queue synchronisation** uses a new timeline `IFence`, with waits and signals attached to
  `IDevice::submit` (8.3). CPU waits follow 8.3.1, where an infinite timeout blocks until the value
  is reached.
- **Vulkan ownership** across families is explicit release/acquire, through transition flags.

### 14.4 Old records (decided)

- `ethereal-donut/doc/RdgDesign.md` becomes "Superseded by aggregate ADR 0003". This happens in
  step 0, because donut is not checked out in the worktree yet.
- The 2026-10-04 framegraph plan is "Abandoned". That is already done in this worktree.
- Both are kept as history.

### 14.5 Multi-device graphs (decided: later)

Each graph runs on one device. Interop resources are imported, with acquire and release placed at
first and last use.

### 14.6 Placement, pass base and resource ids (decided)

- The graph sits in the `render/` folder of `donut_render` as the `RenderGraph*` files. There is no
  subfolder and no adapter layer: the passes derive from one base and add themselves (section 13).
- Graph resources are named by one `ResourceId` type (index plus version), and accesses name an
  `nvrhi::SubresourceRegion`.
- Graph per-subresource state is `SubresourceRangeState`.

### 14.7 Names (decided)

- **Pass base:** `donut::render::IGpuPass` (3.3). Every donut rendering pass derives from it.
- **App layer:** `app::IRenderPass` becomes `app::IAppLayer`, and the `DeviceManager` members follow
  it:
  - `AddLayerToFront`, `AddLayerToBack` and `RemoveLayer`;
  - `m_vLayers`;
  - `ImGuiRenderPass` becomes `ImGuiLayer`.

  No alias is kept, and the name `nvrhi::IRenderPass` is reserved for the RHI.

### 14.8 Lessons from the legacy framegraph (decided)

[`rdg-legacy-evaluation.md`](rdg-legacy-evaluation.md) compared this design with the deprecated
`framegraph` branches. These changes were adopted from it:

1. the frame boundary: aliasing, cross-queue waits and state hand-off (6.12);
2. a full queue-legality table for states and stages, and the corrected async example (6.8, 6.11);
3. clears as accesses with their own slot (6.9);
4. the Restore pass mode (9.1);
5. an R1-compliant header with enum ids, abi_lint coverage and derived-interface evolution (3.2, 5.1,
   12);
6. `IResource::queryHeapBinding`, checked Vulkan memory binding, and the donut queue-family fix
   (2.2, 8.1, step 0);
7. the D3D12 discard and alias rules (6.6, 6.7);
8. the pass lifecycle: `Prepare` and `OnResourcesReleased` (12, 13.1);
9. history pairs specified, persistent buffers, and poolable extracted resources (5.2);
10. conditional passes, exclusion groups and a bounded plan cache (7.7, 13.5);
11. debug switches, a visualizer, timers and deterministic A/B tooling (10.4, 11.3, 11.4);
12. a corrected memory budget, the parallel-recording rules, and more samples (10.1, 10.3, 15).

## 15. Implementation steps and exit criteria

| Step | Content | Exit criterion |
| --- | --- | --- |
| 0 | `rdg` branches per 14.1; mark the old donut record superseded; nvrhi ADR for section 8; donut `findQueueFamilies` reset fix (2.2) | All four repositories build at their starting points; slang-next test matrix unchanged; Vulkan device selection correct on a two-GPU machine |
| 1 | nvrhi: `IResource` with `queryHeapBinding`; `SubresourceRegion`; `ResourceBarrier` + `barriers` on D3D12 (legacy, enhanced), Vulkan, D3D11, CUDA; checked Vulkan `bind*Memory`; `IFence`, `submit` and `waitFences` on all four; check of CUDA stream memory operations | nvrhi tests per backend: combined depth-read layouts, plane-masked transitions, split pairs, aliasing (including byte-overlap validation and the enhanced alias form of 6.7), discard, release/acquire, fence ordering across queues (including CUDA streams), and the CPU wait table of 8.3.1 (poll, finite, infinite). Clean under debug layers, GBV, sync validation and Compute Sanitizer. Installed-consumer tests pass after the full rebuild (8.4) |
| 2 | donut and samples: the `app::IAppLayer` rename (3.3), in one commit per repository | All samples build on every backend they built on before; the slang-next sample runs are unchanged |
| 3 | `RenderGraph*` core: builder with frame arena, graph, compiler phases 1-7 with queue legality, frame boundary (6.12) and enable masks (13.5), profiles for all four APIs, verifier, JSON dump, `rdg_bench`, header-hygiene test and abi_lint | Verifier passes a device-free corpus (≥ 40 graphs × 4 profiles), including two-frame and plan-switch replays; golden barrier lists for the 6.11 frame, with and without async SSAO; compile and cache-hit budgets of 10.3 met |
| 4 | Executor (Native, Tracked, Restore), `Prepare` phase, registry (persistent and history pairs, plan cache with bound, pooled tier, fences, `IEventQuery` fallback, retirement), command-list pool, debug switches (11.4) | Headless compute graph on D3D11, D3D12, Vulkan and CUDA with clean validation; zero allocations and zero `create*` calls per steady-state frame; `SkipAliasingBarriers` makes the aliasing test fail |
| 5 | `IGpuPass` on every donut pass; `AddToGraph` for DeferredLighting, GBuffer, Forward, Depth/Shadow, Sky, Blit, ToneMapping, TAA, SSAO, Bloom, MipMapGen; `deferred_shading_rdg` and `variable_shading_rdg`; deterministic options and `ab_compare.py`; visualizer and timers | Images match the originals pixel for pixel on D3D12, Vulkan and D3D11; 120 Debug frames with zero validation messages, with the layer confirmed loaded; barrier, CPU and GPU budgets of 10.3 met; immediate entry points unchanged for the other samples |
| 6 | Placed tier on D3D12 (opt-in, probe, estimate), async SSAO, split barriers, `async_compute_rdg` | Memory budget of 10.3 met on the bloom/SSAO graph; GPU-time budget met; sync validation clean, including across the frame boundary; each feature measured on and off |
| 7 | Parallel segment recording, with the donut prerequisites of 10.1 | Executor and parallel-recording budgets met; `BindingCache` and `BlitTexture` concurrency tests pass |
