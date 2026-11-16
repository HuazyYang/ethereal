# Entity component system (ECS) for donut: design

- Status: Draft
- Date: 2026-11-12
- Scope: a data-oriented runtime layer under `donut::engine::SceneGraph`, the bridge that assembles the
  object-oriented scene into structure-of-arrays (SoA) data, and the contracts through which rendering and
  simulation services consume that data
- Baseline: donut `ethereal-dev` at `4f4b31c`, nvrhi `ethereal-dev` (header version 28), aggregate `main` at
  `264ac18`. Render integration targets the render graph of `docs/rdg-design.md` on the `rdg` branches
  (accepted 2026-11-05, not merged to `main`).
- Decision record: none yet. An ADR is written when the open decisions in section 13 are settled.

This document is a starting point for a detailed design. It fixes the architecture, the data model, the
bridge from the scene graph, the scheduling model and the service contracts, and lists the decisions that
still need review (section 13), each with options and a recommendation. Interfaces in section 9 are
sketches: names and shapes are meant to be argued over, not implemented as written.

## 1. Requirements

| # | Requirement | What it means here |
| --- | --- | --- |
| R1 | The scene graph stays the authoring surface | `SceneGraph`, `SceneGraphNode`, `SceneGraphLeaf`, `Material`, `MeshInfo`, the JSON and glTF importers and the COM object model stay. Samples that use the public `SceneGraph`/`Scene` API keep building and keep producing the same images through the migration. |
| R2 | An SoA runtime dataset | Entities live in archetype tables split into fixed-size chunks; each component is a contiguous column. Iteration is linear, SIMD-friendly and parallel by chunk. Columns can be uploaded to the GPU in place. |
| R3 | A data bridge from OOP to SoA, and back | Scene-graph objects are baked into entities and components, at load time in bulk and afterwards incrementally from a change journal. Results produced at runtime (world transforms, bounds, simulated poses) are visible through the scene-graph API. |
| R4 | Inputs for services | Rendering receives an immutable per-frame snapshot plus persistent GPU buffers with stable slots, and builds on the render graph. Simulation domains (ethereal-phys, the MotrixSim C SDK, SPH, GVDB) receive batched, index-addressed views, lifetime events and a fixed-step clock, and write their results back. |
| R5 | Parallel and deterministic | Systems declare what they read and write; the scheduler runs non-conflicting systems in parallel. Structural changes are deferred and played back in a defined order. The same inputs give a bit-identical world on 1 or N threads. Differential simulation testing depends on this. |
| R6 | Production quality | Scale targets in section 10. No heap allocation in steady state. Uploads and simulation exchange touch only what changed. Reflection-driven inspector, statistics and snapshot/restore. |
| R7 | The COM ABI rules where modules meet | Interfaces implemented by other modules (simulation DLLs) follow `ethereal-nvrhi/doc/com-interface-abi.md`. The per-entity hot path is header-only code over plain memory, with no virtual call per entity. |
| R8 | Incremental migration | Every step builds, runs the samples and is compared A/B against the current `Scene` path (section 12). |

Non-goals:
- a gameplay scripting layer, networking and replication (the design must not prevent them);
- an editor; USD;
- replacing the internal storage of simulation engines. They keep their own SoA state; the ECS addresses
  it by index (section 8);
- an ECS that lives on the GPU. Columns are mirrored to the GPU; the world itself is CPU memory.

## 2. Facts the design is built on

### 2.1 donut's scene today

Verified against `ethereal-donut` at `4f4b31c`.

| Area | What the code does | Consequence for this design |
| --- | --- | --- |
| Node storage (`include/donut/engine/SceneGraph.h`) | Each `SceneGraphNode` is a reference-counted heap object with an owning first-child/next-sibling chain. It stores local, global and previous transforms in double precision, float copies of the global and previous global transforms, TRS components and a world bounding box: about 580 bytes of transform and bounds state per node, before links, name, object header and the leaf object. | The graph is a good authoring structure and a poor iteration structure. Runtime-only entities (instances, debris, particles) must not need a node. |
| Refresh (`src/engine/SceneGraph.cpp`, `SceneGraph::Refresh`) | One single-threaded pre-order walk through pointers. Dirty flags select subtrees. Every visited node copies its transforms into the previous slots; bounds are unioned up the tree; content flags are recomputed. | Transform propagation and bounds become parallel systems over columns (6.3, 4.7). |
| Index assignment (`SceneGraph::Refresh`, structure-change branch) | On any structural change every instance index, geometry-instance index, geometry index, mesh index and material ID is renumbered. Meshes and materials are numbered in the iteration order of an `unordered_map` keyed by `AutoPtr`, whose hash is the object address (`nvrhi/core/autoptr.h`). | GPU-visible indices are neither stable nor deterministic between runs. Stable slots (4.8, 7.2) fix both. |
| Leaf registration (`SceneGraph::RegisterLeaf`, `UnregisterLeaf`) | A `query_cast` chain per leaf; flat vectors of `AutoPtr`; removal is `std::find` plus `erase`. **Defect:** `UnregisterLeaf` returns from the `MeshInstance` branch before it reaches the `SkinnedMeshInstance` branch, so a detached skinned instance stays in `m_SkinnedMeshInstances` (and keeps being skinned). | Registration becomes observers on components (6.6). The defect should be fixed on its own, independently of this work. |
| GPU buffers (`src/engine/Scene.cpp`, `Scene::RefreshBuffers`) | If any transform changed, every instance's `InstanceData` is rebuilt and the whole instance buffer is written. Every material is visited every frame to poll its `dirty` flag. Skinning writes joint matrices and dispatches per instance. | Uploads follow change versions at chunk granularity (7.2). |
| Draw strategies (`src/render/DrawStrategy.cpp`) | `InstancedOpaqueDrawStrategy` and `TransparentDrawStrategy` walk the graph per view and `query_cast` each leaf. `DrawItem` holds raw pointers to `MeshInstance`, `MeshInfo`, `MeshGeometry`, `Material`, `BufferGroup`. | Visibility and draw-packet generation become queries (7.3); the strategies become adapters. |
| GPU layout (`include/donut/shaders/bindless.h`) | `InstanceData` is 112 bytes: flags, first geometry-instance index, first geometry index, geometry count, `float3x4` transform and previous transform. | Kept unchanged at first, so shaders do not change during the migration. |
| Extensions | Samples add leaves with private content-flag bits and walk the graph to find them (`SPHFluidInstance`, `SceneContentFlags(0x200)`, `collectFluidInstances` in `ethereal-samples/src/gvdb_samples/sph_fluid_pool`; `GVDBScene.h`). ethereal-phys subclasses `SceneGraph` (`PhysSceneGraph`, four leaf types) and drives the engine through `PhysSceneService::SyncToPhysics` / `Step` / `SyncFromPhysics`. | Every extension re-implements registration and synchronisation. Bakers and simulation domains (5.3, 8) give them one mechanism. |
| Threading (`include/donut/engine/ThreadPool.h`) | A `std::function` queue with `WaitForTasks`; no dependencies, no work stealing. The RDG work adds a worker pool for parallel recording. | A job system with dependency counters is needed (decision D10). |
| API footprint | In `ethereal-samples`: `GetMeshInstances` in 7 files, `GetLights` 7, `Refresh(` 9, `SceneGraphWalker` 3, `GetInstanceBuffer`/`GetGeometryBuffer` 4 each. | The compatibility surface of 5.6 is small enough to keep exactly. |

### 2.2 Constraints from the rest of the tree

- **ABI** (`ethereal-nvrhi/doc/com-interface-abi.md`). Across a module boundary: no class, struct or union by
  value in a virtual signature (R1), so ids are `enum class` integers, as the render graph's `ResourceId` is;
  `noexcept` everywhere and `FRESULT` errors; no `std::` types in public headers; callbacks are interfaces or C
  function pointers; no overloaded virtual names; out parameters last. `SceneGraphLeaf` and its subclasses are
  implementation classes, so anything that takes them is module-private (ethereal-phys already keeps its
  scene integration in a static library for this reason).
- **Function design**: raw `T*` parameters, never `nvrhi::AutoPtr<T>` parameters; returning `AutoPtr` is fine.
- **Data and operations are separate objects** for new subsystems: the world holds data; systems, the
  scheduler, bakers and services operate on it.
- **Render graph** (`rdg` branches): every pass is an `IGpuPass` with `Setup(ISetupContext*, void*)`,
  `Prepare(IPrepareContext*, void*)` and `Execute(IPassContext*, const void*)`; per-frame data lives in the
  graph's arena (`NewFrameData<T>`, trivially destructible) and in the typed `FrameData` blackboard; persistent
  buffers enter a frame through `ImportBuffer`.
- **Simulation engines own their state.** ethereal-phys keeps particles and shapes in nvrhi buffers and runs on
  the graphics queue for now. The MotrixSim work defines a versioned C ABI with opaque handles, keeps the
  original engine as an oracle and validates replacements by replay; it needs deterministic inputs. SPH and
  GVDB keep their data on the GPU.

### 2.3 What the references teach

| Reference | Mechanism | Taken | Not taken |
| --- | --- | --- | --- |
| Unity Entities 1.x [1][2][3] | Archetypes; 16 KiB chunks with SoA columns; per-chunk, per-component change versions; enableable components; shared and chunk components; `EntityCommandBuffer` with sort keys for parallel writers; baking of authoring GameObjects into entities with `TransformUsageFlags`; Entities Graphics uploading changed chunks into a persistent buffer for `BatchRendererGroup`. | Chunks and change versions; enableable bits; command-buffer sort keys for determinism; baking as the bridge, with bakers declaring dependencies; transform-usage hints; changed-chunk uploads. | Baking as an offline asset step only: here the same bakers also run live and incrementally. Shared components as the default batching key (fragmentation, 4.4). Managed components. |
| Bevy 0.14-0.16 [4][5] | Table storage plus sparse-set storage chosen per component; change ticks per row; `Commands`; schedules, system sets, ambiguity detection; component hooks and observers (0.14); required components (0.15); `ChildOf`/`Children` relationships (0.16); a separate render world filled by an extract schedule, then prepare/queue/render phases, optionally pipelined with the next frame's simulation. | Two storage kinds; ambiguity detection; hooks/observers for engine-object lifetime; required components (a baked mesh instance always gets bounds); extraction into an immutable snapshot and optional pipelining. | A second full `World` for rendering: a frame-arena snapshot plus a persistent GPU scene is cheaper here (D8). Per-row ticks everywhere (D9). |
| flecs v4 [6][7] | Archetype tables; relationships as `(relation, target)` pairs; `ChildOf` hierarchies with breadth-first "cascade" iteration; `IsA` prefab inheritance; pipelines of phases; cached queries matched per table; observers; runtime reflection (meta) and a web explorer. | Phases; cached queries; runtime reflection for the inspector and serialisation; prefab instancing. | `ChildOf` as part of the table type: children of different parents land in different tables, which fragments storage when parents have few children (D5). General relationships stay out of the first version. |
| EnTT [8][9] | Sparse sets per component; owning groups that pack co-iterated components; construction/update/destruction signals. | Sparse sets for volatile tags and rare components. | Sparse sets as primary storage: multi-component iteration is linear only inside groups. |
| Unreal Engine Mass [10] | Fragments, tags, shared and chunk fragments; processors in execution groups; translators that copy between actor components and fragments in both directions; representation LOD switching between actors and instanced meshes. | Translators per OOP type in both directions (bakers and write-back, 5.3, 5.4); entities that have no OOP object at all (5.5). | |
| NVIDIA Omniverse Fabric / USDRT [11] | A hierarchical OOP scene (USD) mirrored into buckets of prims with the same attribute set, stored as columns, mirrored to CUDA memory with per-device validity, with change tracking; renderer and physics read the columns; world transforms computed in the runtime layer. | The closest analogue to this design: the authoring hierarchy stays, the runtime is columnar, services read columns, GPU mirrors carry a validity version. | |
| Pixar Hydra [12] | Scene delegates and a render index; a change tracker with per-prim dirty bits; sync pulls only dirty data; scene indices in Hydra 2.0. | Consumer-pulled sync of dirty data; the change journal (5.2). | |
| Filament [13], Bitsquid/Stingray [14] | Integer entities with generations; one component manager per subsystem with SoA instance data (`TransformManager`, `RenderableManager`); swap-remove packed arrays. | Generational ids; services keep their own SoA where they must (GPU scene, simulation). | One store per manager as the general model: joins across managers need an indirection per entity. |
| UE5 GPU Scene, Unity BRG [3][15] | A persistent GPU primitive/instance buffer with stable slots and scatter uploads of dirty entries. | Stable GPU slots and scatter upload (7.2). | |
| PhysX 5 direct GPU API, MuJoCo `mjData` [16][17] | Simulation state exposed as flat, index-addressed arrays and batched get/set. | Simulation exchange through batched column views, not per-object calls (8.2). | |
| Overwatch (GDC 2017) [18] | Systems plus singleton components; deferred side effects. | World resources (4.9); deferral. | |

## 3. Architecture

### 3.1 Layers

```
 Authoring (OOP, COM)   SceneGraph / SceneGraphNode / SceneGraphLeaf, Material, MeshInfo, importers
        |  change journal (push)                        ^  write-back / pull-through
        v                                               |
 Bridge                 SceneBridge: ILeafBaker per leaf class id, asset bridge      (donut_engine)
        |  command buffers, sorted playback
        v
 Runtime data (SoA)     IWorld: entities, archetypes, chunks, columns, versions,     (donut_ecs)
                        sparse sets, world resources, asset tables
        |  queries, column views
        v
 Operations             IScheduler + ISystem in phases, observers, IJobSystem        (donut_ecs, donut_core)
        |
        +--> Render service   extract -> frame snapshot (RDG arena) -> GpuScene -> IGpuPass  (donut_render)
        +--> Simulation       ISimulationDomain: lifetime events, gather, step, scatter      (ethereal-phys,
                                                                                              MotrixSim SDK,
                                                                                              samples)
```

### 3.2 Placement

- `donut_ecs` (new static library): entity store, component registry, archetype storage, queries, command
  buffers, observers, scheduler, reflection, snapshot. Depends on nvrhi core (`foundation.h`, containers) and
  `donut_core` only. It names no scene, render or simulation type, as the render graph names no pass.
- `donut_engine`: the scene bridge, donut's built-in components and bakers, the transform, hierarchy and bounds
  systems, asset tables.
- `donut_render`: extraction, `GpuScene`, visibility, draw packets, adapters for `IDrawStrategy`, the upload and
  skinning passes.
- Simulation adapters live with their engines: an `ethereal_phys_ecs` static library next to
  `ethereal_phys_scene`; a MotrixSim domain in the motphys work; SPH and GVDB in the samples.

 > REV: donut_ecs goes to donut_engine, no sub-folder, just plan list in engine directory;

Namespace `donut::ecs`; files `Ecs*.h` / `Ecs*.cpp` in an `ecs/` folder (`include/donut/ecs`, `src/ecs`).

### 3.3 Rules

1. **One writer per component per phase.** Authored data is owned by the scene graph and reaches the world only
   through the bridge. Derived data (world transforms, bounds, visibility, GPU slots) is owned by the world.
   Simulated data is owned by its domain and written only in its scatter step.
2. **Structural changes are deferred.** Systems record them in command buffers; playback happens at sync points
   in a defined order. Only exclusive systems change structure immediately.
3. **No virtual call per entity.** Virtual calls happen per system, per chunk batch or per event batch.
   Per-entity code is inline header code over plain memory.
4. **Stable ids.** An `Entity` is valid until destroyed; a GPU slot, an asset id and a simulation body index are
   stable for the lifetime of what they name.
5. **Determinism.** Iteration order is chunk order; chunk order depends only on the order of structural
   changes, and those are played back sorted by (phase, system order, sort key). No order may depend on an
   address, a hash of an address or thread timing.
6. **Data and operations are separate.** `IWorld` is data with primitive accessors. Everything that transforms
   data is a system, an observer, a baker or a service.

## 4. Data model

### 4.1 Entities

`enum class Entity : uint64_t`: index in the low 32 bits, generation in the high 32 bits; 0 is null and index 0 is
never handed out. The entity table holds, per index, the generation and the location (archetype, chunk, row).
Destroying an entity bumps the generation and returns the index to a FIFO free list, so a stale `Entity` fails
`IsAlive` and is not reused soon. 64 bits are chosen over Filament-style 32-bit ids so that generations never
wrap in long simulations and so that serialised references survive (D3).

### 4.2 Component types

A component type is registered once per world from a `ComponentTypeDesc`: a GUID (cross-module identity, the
same `nvrhi::GUID` the IIDs use), a name, size, alignment, flags, lifecycle hooks as C function pointers (null
means trivial), and reflected fields. The world returns a dense `enum class ComponentId : uint32_t`; ids are
per world and in registration order, so they are deterministic when registration is.

A header-only macro gives C++ types their descriptor:

```cpp
struct LocalTransform { dm::double3 translation; dm::dquat rotation; dm::double3 scaling; };
DONUT_ECS_COMPONENT(LocalTransform, "<guid>", DONUT_ECS_FIELDS(translation, rotation, scaling));
```

Flags:

| Flag | Meaning |
| --- | --- |
| `Tag` | Zero-size; presence only. |
| `Sparse` | Stored in a sparse set; adding or removing it does not move the entity between archetypes. For volatile markers (selection, pending upload, debug). |
| `Shared` | One value per chunk; the value partitions chunks. For low-cardinality partitions only (4.4). |
| `Chunk` | One value per chunk, not a partition key (chunk bounds). |
| `Enableable` | A per-row enabled bit; toggling is not a structural change. |
| `Buffer` | A dynamic buffer: inline capacity in the chunk, overflow on the heap. |
| `Relocatable` | Can be moved with `memcpy`. Required for `GpuMirrored` and for simulation-visible components. |
| `GpuMirrored` | The render service mirrors the column (7.2). |
| `NoSerialize` | Skipped by snapshots (transient caches). |

Components should be plain data. A component may hold a COM reference (for example the `ISPHParticles*` of an
SPH fluid) if it registers construct/destruct/relocate hooks; such components cannot be `GpuMirrored` and
are never handed to simulation domains as raw columns (D14).

### 4.3 Storage

- **Archetypes.** An archetype is a sorted set of `ComponentId`s plus the values of its `Shared` components. It
  is found by hash and connected to neighbours by cached add/remove edges, so moving an entity between
  archetypes is a lookup, not a search.
- **Chunks.** Fixed-size blocks (16 KiB by default, D6) from a page allocator built on nvrhi's default
  allocator. Layout inside a chunk: the `Entity` column, then each component column aligned to 64 bytes, then
  the enabled bitmasks, then the per-column change versions. Capacity per chunk is computed per archetype.
- **Removal** swaps the last row in, keeping chunks dense. Because removals are played back in sorted order, the
  resulting row order is deterministic.
- **Sparse sets** hold `Sparse` components: a dense array of values, a dense array of entities, and a paged
  sparse index. Queries can filter on them; iteration over them is a second, slower path.
- **Dynamic buffers** (`Buffer`) hold variable-length data: children lists, skin joints, material ranges.

### 4.4 Shared and chunk components

A shared component splits chunks by value. That makes per-chunk decisions free (a chunk is entirely in one
simulation domain or one scene layer) but fragments storage when the cardinality is high: ten thousand unique
meshes as a shared key give ten thousand mostly empty chunks. Recommendation: use shared components only for
low-cardinality partitions (simulation domain, scene layer, hierarchy depth bucket, static/dynamic), and batch
draws by sorting keys at extraction (7.3) instead of by mesh/material chunks (D11).

Chunk components hold per-chunk aggregates; the first one is `ChunkWorldBounds`, the union of the world bounds
of a chunk's rows, used for chunk-level culling.

### 4.5 Change detection

The world keeps a version counter that advances each time a system runs. Each chunk stores, per column, the
version of the last write. Writing through a query that declared `Write` access stamps the column; reading never
does. A query can filter on `Changed<T>` (column version newer than the system's last run) and `Added<T>`
(chunk-level structural version), at chunk granularity, so a static scene costs one comparison per chunk.

Chunk granularity over-reports: one moved entity marks its whole chunk. The GPU upload and simulation exchange
therefore treat a changed chunk as a set of candidate rows and copy all of them; at 16 KiB this is a few KiB per
changed chunk. Per-row ticks are an option for components flagged `RowTracked` if measurement shows chunk
granularity is too coarse (D9).

### 4.6 Hierarchy

Components: `Parent { Entity }`, `Children` (a dynamic buffer of `Entity`, maintained by an observer on
`Parent`), and a shared `HierarchyDepth` (0 for roots and for entities without a parent, capped at 63; deeper
entities take a slow path). Entities without a hierarchy, which is the bulk of instanced and simulated content,
are depth 0 and never touch the hierarchy code.

Transform propagation runs depth level by depth level: each level is a parallel loop over the chunks of that
depth, reading the parent's `WorldTransform`, which the previous level finished. Alternatives are per-root
recursion in parallel over roots (Unity) and flecs-style pairs (D5).

### 4.7 Transforms, bounds and precision

| Component | Layout | Notes |
| --- | --- | --- |
| `LocalTransform` | `double3` translation, `dquat` rotation, `double3` scaling (80 B) | Authored; written by the bridge, animation or scripts. Matches `SceneGraphNode` TRS. |
| `WorldTransform` | `dm::daffine3` (96 B) | Written by transform propagation, or by a simulation domain for entities it drives. |
| `TransformDriver` | `uint8_t`: `Authored`, `Animation`, `Simulation`, `Script` | Who may write `WorldTransform`; drives write-back and conflict handling (5.4). |
| `Static` | tag | Never moves after baking: skipped by propagation, uploaded once. |
| `LocalBounds` | `box3` (24 B) | From the mesh or the leaf's `GetLocalBoundingBox`. |
| `WorldBounds` | `box3` (24 B) | Computed by the bounds system. |
| `ChunkWorldBounds` | chunk component | Union of `WorldBounds` in the chunk. |

World transforms stay in double precision, as in `SceneGraphNode` today and as physics engines use; rendering
receives float transforms relative to a render origin, computed at extraction (7.1). The previous-frame
transforms for motion vectors are kept by the GPU scene (7.2), not as a component. The subgraph bounds that
`SceneGraphNode::GetGlobalBoundingBox` returns are computed on demand for bridged nodes (5.6). A float-only
variant for very large instance counts is D4.

### 4.8 Assets

Meshes, geometries, materials and textures are not entities. They live in typed asset tables in
`donut_engine`, each a dense SoA table with generational handles (`enum class MeshId : uint32_t`, `MaterialId`,
`GeometryId`, `TextureId`) and reference counts held by the components that use them. Slots are stable for the
lifetime of the asset, so geometry and material indices on the GPU no longer change when the structure
changes, and they no longer depend on object addresses. The authoring objects (`MeshInfo`, `Material`) stay; the
asset bridge bakes them into rows: a material row is the `MaterialConstants` GPU layout itself, a geometry row
is `GeometryData`. A material change pushes a journal entry for that material (5.2); nothing polls.

### 4.9 World resources

Singletons keyed by GUID: `FrameTime`, `FixedStepState`, `RenderOrigin`, `ActiveViews`, the asset tables, the
`GpuScene`. Systems declare resource access the same way as component access.

### 4.10 Prefabs and instancing

`Instantiate(prefab, count, out)` copies a prefab entity's columns into `count` new rows of the same archetype in
one operation. The bridge uses it when a baked subtree is cloned (`SceneGraph::Attach` of an attached node makes
a deep copy today), and runtime systems use it for crowds, scatter and debris.

## 5. The data bridge: assembling OOP scene data into SoA

### 5.1 Mapping

Every `SceneGraphNode` maps to exactly one entity; donut allows one leaf per node, so the leaf's data becomes
components of the same entity. The node stores its `Entity`; the entity carries `SceneNodeLink`, a non-owning
`SceneGraphNode*` used by write-back and by the inspector. Nodes without a leaf still map to entities because
they carry transforms. Transform-only chains under `Static` subtrees can later be folded into their children
(Unity's transform usage); this is off at first.

| OOP object | Entity after baking |
| --- | --- |
| node `Car`, no leaf | `SceneNodeLink`, `LocalTransform`, `WorldTransform`, `Children`, depth 0 |
| node `Body` with `MeshInstance(mesh M)` | `SceneNodeLink`, `Parent(Car)`, `LocalTransform`, `WorldTransform`, `LocalBounds`, `WorldBounds`, `MeshRef(M)`, `RenderFlags` (from M's material domains), depth 1; the GPU-scene observer adds `GpuInstanceSlot` |
| node with `SkinnedMeshInstance` | as above, plus `SkinnedMesh { prototype MeshId, output MeshId }` and a `SkinJoints` buffer of (joint `Entity`, inverse bind matrix) |
| node with `PointLight` | `PointLight` (plain data: color, intensity, radius, range), `LightShadow` if a shadow map is assigned |
| node with `PerspectiveCamera` | `PerspectiveCamera` (plain data) |
| node with ethereal-phys `PhysShapeLeaf` | `PhysShapeRef { domain, shape index }`, `TransformDriver = Authored` (the shape follows the node) |
| node with `SPHFluidInstance` | `SphFluidRef` (holds `ISPHParticles*`), `SphRenderAttributes`; bounds from the domain's readback |
| `Material` | a row in the material table |

### 5.2 Change journal

Mutations of the scene graph append records to a journal owned by the graph: node created/destroyed,
attached/detached, local transform set, leaf set, name set, content invalidated, leaf property set, material
changed. Each thread appends to its own buffer; a per-node "pending" mask coalesces repeated transform writes
within a frame. The `SceneSync` phase drains the journal in a deterministic order (by node creation sequence,
then record sequence) and turns it into bake, re-bake, unbake, reparent and set-transform work.

During the migration the existing `DirtyFlags` stay and keep `SceneGraph::Refresh` correct; they are removed in
the last step (12).

### 5.3 Bakers

A baker turns one leaf class into components. Bakers are registered per leaf class id (the
`NVRHI_CLASS_CLSID` of the leaf), separately from the leaf classes: modules can bake donut's leaves differently,
and `SceneGraphLeaf` needs no new virtual function (D12).

- `Bake(leaf, context)` adds components through the context; `Unbake` removes what it added; a re-bake is an
  unbake plus a bake unless the baker implements an in-place update.
- The context resolves related objects: `ResolveAsset(MeshInfo*)` returns a `MeshId`, `ResolveNode(node)`
  returns an `Entity` (skin joints), `DependOn(object)` re-bakes the leaf when that object changes (a material
  edited, a mesh rebuilt).
- Bakers only read the OOP side and write into a per-thread command buffer, so bulk baking after a load runs in
  parallel, grouped by leaf class.
- donut ships bakers for `MeshInstance`, `SkinnedMeshInstance`, `SkinnedMeshReference`, both cameras, the three
  lights and `SceneGraphAnimation`. ethereal-phys, SPH, GVDB and the MotrixSim viewer register theirs. This
  replaces the `PhysSceneGraph` subclass, private `SceneContentFlags` bits and graph walks such as
  `collectFluidInstances`.

Because bakers take `SceneGraphLeaf*`, the bridge API is module-private C++ (section 2.2). Engines in DLLs
implement `ISimulationDomain` (8.1), which is on the ABI surface; their bakers live in the static scene
libraries that link into the application.

### 5.4 Write-back

What the world computes must be visible through the scene-graph API:

- **Mirror mode (migration steps E3-E6).** The `SceneWriteBack` phase copies `WorldTransform` (and the float
  copy) into the nodes whose entities changed, using change versions. Cost is proportional to what moved.
- **Pull-through (final step E7).** `SceneGraphNode` stops storing world and previous transforms; its getters
  read the entity's columns. The node keeps only authored state.

Conflicts: when the authoring side sets the transform of an entity whose `TransformDriver` is `Simulation`,
the bridge does not overwrite the simulated pose; it records a teleport command for the owning domain, which
applies it at its next step. Animation-driven entities are handled the same way by the animation system.

### 5.5 Runtime-only entities

Entities created by systems or services directly in the world have no node: instanced scatter, particles that
spawn meshes, debris, crowd agents. They render and simulate like baked entities but are invisible to
`SceneGraphWalker` and `GetMeshInstances`. This is where scale comes from: about 250 bytes of columns for a
dynamic mesh instance (8 entity + 8 link + 80 local + 96 world + 24 + 24 bounds + 4 mesh + 4 flags + 4 slot +
padding), against about 580 bytes of transform and bounds state alone in a node, before its leaf object.

### 5.6 Scene-graph API compatibility

| Current API | After the bridge |
| --- | --- |
| `SceneGraph::Refresh(frameIndex)` | Runs the phases `SceneSync` to `SceneWriteBack` (6.3) when a bridge is attached; unchanged otherwise. |
| `Scene::RefreshBuffers` | Delegates to `GpuScene` (7.2). |
| `GetMeshInstances`, `GetSkinnedMeshInstances`, `GetLights`, `GetCameras`, `GetAnimations` | Still vectors of leaves, maintained by observers instead of `RegisterLeaf`. |
| `MeshInstance::GetInstanceIndex`, `GetGeometryInstanceIndex` | The stable `GpuInstanceSlot` and geometry-instance slot. |
| `SceneGraphNode::GetLocalToWorldTransform*`, `GetPrev*`, `GetGlobalBoundingBox` | Written back (mirror mode), then read through (pull-through); subgraph bounds computed on demand. |
| `Scene::GetInstanceBuffer`, `GetGeometryBuffer`, `GetMaterialBuffer` | The `GpuScene` buffers, same layouts. |
| `SceneGraph::OnMeshAdded` and the other callbacks | Raised from asset-table observers. |

## 6. Operations: queries, systems, scheduling

### 6.1 Queries

A query is created from terms: component, operator (`All`, `Any`, `None`, `Changed`, `Added`, `Enabled`,
`Disabled`) and access (`Read`, `Write`). It is cached: the set of matching archetypes updates incrementally
when archetypes are created. Iteration hands out `ChunkView`s (entity column, one pointer per data term, row
count, enabled masks, chunk index). A header-only typed layer sits on top:

```cpp
ecs::Query<ecs::Read<LocalTransform>, ecs::Write<WorldTransform>, ecs::None<Parent>> roots(world);
roots.ForEachChunk(ctx, [](const ecs::ChunkView& chunk, const LocalTransform* local, WorldTransform* world)
{
    for (uint32_t i = 0; i < chunk.count; ++i)
        world[i].value = ComposeAffine(local[i]);
});
roots.ParallelForChunks(ctx, /*chunksPerTask*/ 4, ...);
```

In Debug builds a query checks that the running system declared the access it uses.

### 6.2 Systems

A system is an `ISystem` (or a lambda wrapped by a header-only helper, as with the render graph's lambda pass)
with a descriptor: name, phase, component and resource access, `runBefore`/`runAfter` constraints, an
exclusive flag (runs alone, may change structure immediately) and a main-thread flag. `Update` receives a
context with the world, the system's command buffer, the job system, the version at its last run, and the frame
time.

### 6.3 Phases

| # | Phase | Work | Sync point after |
| --- | --- | --- | --- |
| 1 | `BeginFrame` | time, input, view list | |
| 2 | `SceneSync` | drain the journal, bake, asset rows, play back | yes |
| 3 | `PreSimulation` | animation sampling, scripts, simulation input gathering | |
| 4 | `FixedSimulation` | zero or more fixed steps per domain (8.4) | per step if a domain changes structure |
| 5 | `PostSimulation` | scatter results, interpolation | yes |
| 6 | `TransformPropagation` | local to world, by depth level | |
| 7 | `Bounds` | world bounds, chunk bounds | |
| 8 | `SceneWriteBack` | mirror mode only | |
| 9 | `RenderExtract` | per view: visibility, draw packets, light and camera arrays into the frame snapshot | yes |
| 10 | `EndFrame` | deferred destruction, version advance, statistics | |

Applications add systems to these phases; new phases are allowed between them by name.

### 6.4 Scheduler

For each phase the scheduler builds a dependency graph from the declared accesses (a write conflicts with any
other access to the same component or resource) and the explicit constraints. Two conflicting systems without
an ordering constraint are an *ambiguity*: Debug builds report it, and a determinism test fails on it. The graph
is cached until a system is added, removed or enabled.

Execution uses a job system (`IJobSystem` in `donut_core`, D10): fixed worker threads, work stealing,
dependency counters, `ParallelFor` with a deterministic split. The render graph's parallel recording becomes a
client of the same pool.

### 6.5 Command buffers

Each system gets a command buffer per worker thread. Every command carries a sort key: (phase, system order,
chunk index, row) for commands issued while iterating, or a key the caller supplies. At a sync point the buffers
are merged by key and played back; consecutive moves of entities between the same two archetypes are batched
into one column copy. `CreateEntities` returns placeholder entities that resolve at playback, as Unity's and
Bevy's deferred spawns do.

### 6.6 Observers

`OnAdd`, `OnRemove` and `OnSet` per component, delivered at playback, single-threaded, in playback order and in
batches per archetype. Observers may not change structure directly; they receive a command buffer whose
commands are played back before the sync point ends. Observers replace `RegisterLeaf`/`UnregisterLeaf`, allocate
and free GPU slots, and create and destroy bodies in simulation engines.

## 7. Render service

### 7.1 Flow

```
World --RenderExtract systems--> RenderSnapshot (RDG frame arena, immutable)
                                     |                        \
                                     v                         v
                              GpuScene upload pass       visibility + draw packets per view
                              (IGpuPass, copy/compute)   (CPU now; GPU culling later)
                                     |                         |
                                     +-----> geometry/lighting IGpuPasses (bindless instance/geometry/material)
```

The snapshot holds what the passes need for one frame as SoA arrays: per visible instance its GPU slot,
geometry range and sort key; per light its `LightConstants`; per view its constants; the render origin. It is
trivially destructible and allocated with `NewFrameData`, so it is released with the frame.

### 7.2 GPU scene

`GpuScene` owns the persistent instance, geometry and material buffers and a stable slot allocator per buffer
(free list; compaction only on request). An observer on `MeshRef` allocates an instance slot (`GpuInstanceSlot`)
and frees it on removal.

Each frame, the upload system walks the chunks whose `WorldTransform`, `MeshRef` or `RenderFlags` version is
newer than the last upload, writes `InstanceData` rows (layout unchanged, 2.1) into an upload ring, and the
upload pass scatters them into the instance buffer with a compute shader. Before it overwrites a slot's
transform, the scatter kernel copies the old transform into `prevTransform`; slots updated in the previous
frame are visited once more so that their previous transform settles to the current one. That is today's
`PrevTransform` dirty-flag logic, moved to the GPU and limited to what changed.

Geometry and material rows come from the asset tables (4.8) with stable slots, so `firstGeometryIndex` and
`materialIndex` never need a global rewrite.

### 7.3 Visibility and draw packets

Per view: a chunk-level frustum test against `ChunkWorldBounds`, then a row-level test against `WorldBounds`,
over SIMD-friendly columns, in parallel by chunk. Visible geometry instances become draw packets, an SoA of
(64-bit sort key, instance slot, geometry slot, material slot, pass flags), radix-sorted per pass. The key
packs pass, material domain, pipeline state, material, mesh and depth.

`InstancedOpaqueDrawStrategy` and `TransparentDrawStrategy` become adapters that produce `DrawItem`s from
packets, so existing passes keep working; passes migrate to packets one by one. GPU-driven culling and indirect
draws come later; the data they need is already in the GPU scene.

### 7.4 Render graph integration

- The `GpuScene` buffers are persistent and imported with `ImportBuffer` each frame.
- The upload is an `IGpuPass` that writes the instance buffer; geometry passes read it.
- Skinning becomes an `IGpuPass` over a query of `SkinnedMesh` entities whose joint entities changed: joint
  matrices come from the `WorldTransform` of the joints in `SkinJoints`, the dispatch is per instance as today.
- Light and camera arrays travel in the frame blackboard (`FrameData`).

### 7.5 Pipelining

The snapshot is immutable after `RenderExtract`, so the render graph can record frame N while the world runs
frame N+1, as in Bevy's pipelined rendering. The `GpuScene` upload ring is double-buffered for this. It is off by
default and is enabled only after the A/B steps pass.

### 7.6 Render objects in scene data

`Light::shadowMap` and `DirectionalLight::perObjectShadows` put render objects into scene data. With the ECS the
render service owns shadow maps keyed by light entity; the leaf fields become authoring hints that the baker
turns into `LightShadow { channel, cascade count, resolution }` (D13).

## 8. Simulation service

### 8.1 Domains

A simulation domain is an engine instance behind `ISimulationDomain` (sketch in 9). Its descriptor states the
fixed time step, substeps and step limit per frame, the components it reads (inputs) and writes (outputs) in the
same access terms as a system, where it runs (CPU, graphics queue, compute queue, CUDA) and whether it is
deterministic. The scheduler orders domains against systems from those accesses.

| Call | When | What it does |
| --- | --- | --- |
| `OnEntitiesAdded` / `OnEntitiesRemoved` | at playback, from observers on the domain's components, batched per archetype | create or destroy engine objects; return engine indices, stored in components such as `SimBodyRef { domain, index }` |
| `GatherInputs` | `PreSimulation` | read changed authored inputs (kinematic targets, forces, parameters, teleports) through column views |
| `Step` | `FixedSimulation`, once per fixed step | advance the engine; GPU domains record into the provided command list |
| `ScatterOutputs` | `PostSimulation` | write poses and velocities into the domain's output columns |
| `CaptureState` / `RestoreState` | on request | write or read the engine state together with the world snapshot (11.4) |

### 8.2 Column views and batched exchange

The exchange unit is a column view: base pointer, stride, row count, component id and version, per chunk. A
domain gets the views for its inputs and outputs and passes them to batched engine calls: a set-poses call of
the MotrixSim C ABI, PhysX's direct GPU API, or an upload into ethereal-phys buffers. The engine never sees an
entity; it sees index-addressed arrays, plus an index map that the domain maintains in its add/remove callbacks.
Because engine indices are assigned in playback order, the mapping is deterministic.

### 8.3 GPU-resident simulation

ethereal-phys, SPH and GVDB keep their data in GPU buffers. The world holds handles (`PhysDomainRef`,
`SphFluidRef`, `GvdbVolumeRef`), parameters and the transforms of emitters, colliders and force fields. The
domain's output buffers enter the render graph as imports, and renderers read them directly. Bounds come from the
domain's readback (ethereal-phys already keeps bounds readback slots) with a frame of delay, into `WorldBounds`.

### 8.4 Time

`FixedStepState` holds an accumulator per domain. Each frame, `FixedSimulation` runs `floor(accumulated / dt)`
steps, up to the domain's limit, and stores the remainder fraction. Entities driven by a domain get an
interpolated `WorldTransform` from the last two simulated poses (`SimPose`, `SimPosePrevious`), so rendering is
smooth at any frame rate.

### 8.5 Determinism and differential testing

With rule 3.3.5, a domain sees the same entity order, the same input values and the same engine index
assignment on every run and at every thread count. That is what the MotrixSim work needs to replay one scene
against the original engine and a replacement, and what ethereal-phys's parity tests against FleX need when
they run inside a scene. `CaptureState`/`RestoreState` together with the world snapshot let a test rewind to the
first divergent step.

### 8.6 Other services

Picking and ray queries (a BVH over `WorldBounds`, rebuilt per changed chunk), audio emitters (donut has an
`AudioEngine`) and streaming fit the same pattern: components in, a service that reads columns, results out.
They are not designed here.

## 9. Interface sketch

ABI surface in `include/donut/ecs/Ecs.h` (IIDs are generated when the header is written; `FRESULT`,
`nvrhi::GUID` and `nvrhi::IObject` come from nvrhi core):

```cpp
namespace donut::ecs
{
    enum class Entity      : uint64_t { Null = 0 };          // index (low 32) | generation (high 32)
    enum class ComponentId : uint32_t { Invalid = 0xffffffffu };
    enum class SystemId    : uint32_t { Invalid = 0xffffffffu };

    enum class Access : uint8_t { Read, Write };
    enum class TermOp : uint8_t { All, Any, None, Changed, Added, Enabled, Disabled };
    enum class Phase  : uint8_t { BeginFrame, SceneSync, PreSimulation, FixedSimulation, PostSimulation,
                                  TransformPropagation, Bounds, SceneWriteBack, RenderExtract, EndFrame, Count };

    typedef void (*PFN_ComponentConstruct)(void* dst, uint32_t count);
    typedef void (*PFN_ComponentDestruct)(void* dst, uint32_t count);
    typedef void (*PFN_ComponentRelocate)(void* dst, void* src, uint32_t count);   // move + destroy source
    typedef void (*PFN_ComponentCopy)(void* dst, const void* src, uint32_t count);

    struct FieldDesc { const char* name; uint32_t offset; FieldType type; uint32_t arrayCount; };

    struct ComponentTypeDesc
    {
        nvrhi::GUID uuid;
        const char* name;
        uint32_t size;
        uint32_t alignment;
        ComponentFlags flags;
        uint32_t bufferInlineCapacity;          // Buffer components only
        PFN_ComponentConstruct construct;       // null: zero-fill
        PFN_ComponentDestruct destruct;         // null: trivial
        PFN_ComponentRelocate relocate;         // null: memcpy
        PFN_ComponentCopy copy;                 // null: memcpy
        const FieldDesc* fields;
        uint32_t fieldCount;
    };

    struct QueryTerm { ComponentId component; TermOp op; Access access; };
    struct QueryDesc { const QueryTerm* terms; uint32_t termCount; const char* debugName; };

    // One chunk as a query sees it. Valid until the next sync point.
    struct ChunkView
    {
        const Entity* entities;
        void* const* columns;          // one per data term, in term order; null for tags and absent Any terms
        const uint64_t* enabledMasks;  // one mask array per Enableable term
        uint32_t count;
        uint32_t chunkIndex;           // stable within a frame; part of command sort keys
    };

    struct ColumnView { void* base; uint32_t stride; uint32_t count; ComponentId component; uint32_t version; };

    struct IQuery : nvrhi::IObject
    {
        virtual uint32_t GetChunkCount() noexcept = 0;
        virtual uint32_t GetChunks(uint32_t first, uint32_t sinceVersion, ChunkView* views, uint32_t capacity) noexcept = 0;
        virtual uint32_t CountEntities() noexcept = 0;
    };

    struct ICommandBuffer : nvrhi::IObject
    {
        virtual Entity CreateEntity(const ComponentId* components, uint32_t count, uint64_t sortKey) noexcept = 0;
        virtual void DestroyEntity(Entity entity, uint64_t sortKey) noexcept = 0;
        virtual void AddComponent(Entity entity, ComponentId component, const void* value, uint64_t sortKey) noexcept = 0;
        virtual void RemoveComponent(Entity entity, ComponentId component, uint64_t sortKey) noexcept = 0;
        virtual void SetComponent(Entity entity, ComponentId component, const void* value, uint64_t sortKey) noexcept = 0;
        virtual void Instantiate(Entity prefab, uint32_t count, uint64_t sortKey, Entity* outEntities) noexcept = 0;
    };

    struct IWorld : nvrhi::IObject
    {
        virtual nvrhi::FRESULT RegisterComponent(const ComponentTypeDesc& desc, ComponentId& outId) noexcept = 0;
        virtual ComponentId FindComponent(const nvrhi::GUID& uuid) noexcept = 0;

        // Immediate structural changes: outside system execution, or from an exclusive system.
        virtual nvrhi::FRESULT CreateEntities(const ComponentId* components, uint32_t componentCount,
                                              uint32_t entityCount, Entity* outEntities) noexcept = 0;
        virtual nvrhi::FRESULT DestroyEntities(const Entity* entities, uint32_t count) noexcept = 0;

        virtual bool IsAlive(Entity entity) noexcept = 0;
        virtual const void* GetComponent(Entity entity, ComponentId component) noexcept = 0;   // null if absent
        virtual void* GetComponentForWrite(Entity entity, ComponentId component) noexcept = 0; // stamps the column
        virtual nvrhi::FRESULT SetEnabled(Entity entity, ComponentId component, bool enabled) noexcept = 0;

        virtual nvrhi::FRESULT CreateQuery(const QueryDesc& desc, IQuery** ppQuery) noexcept = 0;
        virtual nvrhi::FRESULT CreateCommandBuffer(ICommandBuffer** ppBuffer) noexcept = 0;
        virtual nvrhi::FRESULT Playback(ICommandBuffer* const* buffers, uint32_t count) noexcept = 0;

        virtual void* GetResource(const nvrhi::GUID& type) noexcept = 0;
        virtual nvrhi::FRESULT AddObserver(const ObserverDesc& desc, IObserver* observer) noexcept = 0;
        virtual uint32_t GetVersion() noexcept = 0;
        virtual WorldStats& GetStats(WorldStats& retVal) noexcept = 0;
    };

    struct ISystemContext : nvrhi::IObject
    {
        virtual IWorld* GetWorld() noexcept = 0;
        virtual ICommandBuffer* GetCommandBuffer() noexcept = 0;    // this system, this worker thread
        virtual IJobSystem* GetJobSystem() noexcept = 0;
        virtual uint32_t GetLastRunVersion() noexcept = 0;
        virtual const FrameTime& GetFrameTime() noexcept = 0;
    };

    struct ISystem : nvrhi::IObject
    {
        virtual SystemDesc& GetDesc(SystemDesc& retVal) noexcept = 0;
        virtual nvrhi::FRESULT Update(ISystemContext* context) noexcept = 0;
    };

    struct IScheduler : nvrhi::IObject
    {
        virtual nvrhi::FRESULT AddSystem(ISystem* system, SystemId& outId) noexcept = 0;
        virtual nvrhi::FRESULT RemoveSystem(SystemId id) noexcept = 0;
        virtual nvrhi::FRESULT SetSystemEnabled(SystemId id, bool enabled) noexcept = 0;
        virtual nvrhi::FRESULT Build() noexcept = 0;                 // order, validate, report ambiguities
        virtual nvrhi::FRESULT RunPhase(Phase phase) noexcept = 0;
    };

    struct ISimulationContext : nvrhi::IObject
    {
        virtual IWorld* GetWorld() noexcept = 0;
        virtual uint32_t GetColumns(ComponentId component, ColumnView* views, uint32_t capacity) noexcept = 0;
        virtual nvrhi::ICommandList* GetCommandList() noexcept = 0;  // null for CPU domains
        virtual uint64_t GetStepIndex() noexcept = 0;
    };

    struct ISimulationDomain : nvrhi::IObject
    {
        virtual SimulationDomainDesc& GetDesc(SimulationDomainDesc& retVal) noexcept = 0;
        virtual nvrhi::FRESULT OnEntitiesAdded(const EntityBatch& batch, ISimulationContext* context) noexcept = 0;
        virtual nvrhi::FRESULT OnEntitiesRemoved(const EntityBatch& batch, ISimulationContext* context) noexcept = 0;
        virtual nvrhi::FRESULT GatherInputs(ISimulationContext* context) noexcept = 0;
        virtual nvrhi::FRESULT Step(double dt, ISimulationContext* context) noexcept = 0;
        virtual nvrhi::FRESULT ScatterOutputs(ISimulationContext* context) noexcept = 0;
        virtual nvrhi::FRESULT CaptureState(IStateWriter* writer) noexcept = 0;
        virtual nvrhi::FRESULT RestoreState(IStateReader* reader) noexcept = 0;
    };

    nvrhi::FRESULT CreateWorld(const WorldDesc& desc, IWorld** ppWorld) noexcept;
    nvrhi::FRESULT CreateScheduler(IWorld* world, IJobSystem* jobs, IScheduler** ppScheduler) noexcept;
}
```

Module-private C++ in `donut_engine` (it takes implementation classes):

```cpp
namespace donut::engine
{
    class IBakeContext
    {
    public:
        virtual ecs::Entity GetEntity() = 0;
        virtual void AddComponent(ecs::ComponentId component, const void* value) = 0;
        virtual void AppendToBuffer(ecs::ComponentId component, const void* elements, uint32_t count) = 0;
        virtual MeshId ResolveMesh(MeshInfo* mesh) = 0;
        virtual MaterialId ResolveMaterial(Material* material) = 0;
        virtual ecs::Entity ResolveNode(SceneGraphNode* node) = 0;
        virtual void DependOn(nvrhi::IObject* object) = 0;
    };

    class ILeafBaker : public nvrhi::ObjectImpl<nvrhi::IObject>
    {
    public:
        virtual void Bake(SceneGraphLeaf* leaf, IBakeContext* context) = 0;
        virtual void Unbake(SceneGraphLeaf* leaf, IBakeContext* context) = 0;
    };

    class SceneBridge : public nvrhi::ObjectImpl<nvrhi::IObject>
    {
    public:
        void RegisterBaker(const nvrhi::GUID& leafClassId, ILeafBaker* baker);
        void Attach(SceneGraph* graph);                  // bulk-bakes the current graph
        ecs::Entity GetEntity(const SceneGraphNode* node) const;
        SceneGraphNode* GetNode(ecs::Entity entity) const;  // does not AddRef
    };
}
```

## 10. Performance design

### 10.1 Targets

To be calibrated in step E0 on the reference machine; the numbers are the starting proposal.

| Case | Target |
| --- | --- |
| 100k dynamic depth-0 mesh instances: TRS to world, bounds, chunk bounds | < 0.5 ms on 8 workers |
| 1M static instances, nothing changed | < 0.05 ms for all of `SceneSync` to `SceneWriteBack` |
| Upload after 10k of 100k instances moved | proportional to the changed chunks; < 0.2 ms CPU |
| Visibility and packet generation, 100k instances, one view | < 1 ms on 8 workers |
| Structural changes: 10k entities moved between two archetypes | < 1 ms |
| Bulk bake of Sponza-sized glTF scenes | no slower than today's load |
| Steady state | zero heap allocations per frame |
| Memory per dynamic mesh instance | about 250 B of columns (5.5) |

### 10.2 Measurement

The same protocol as the render graph: alternating rounds, median of run medians, a baseline built from
`main`. Synthetic scenes from a generator (flat instances with a moving fraction; deep hierarchies; skinned
crowds), Sponza, the skinned glTF samples, ethereal-phys's flex scenes and, through the MotrixSim viewer, the
official MotrixSim examples.

### 10.3 Choices driven by cost

- Chunk iteration with no virtual call per entity; component pointers hoisted per chunk.
- Column alignment of 64 bytes; float columns used by culling are separate from the double transform columns.
- Change versions per chunk; no per-entity dirty walks.
- Batched archetype moves at playback; edge caches for archetype lookup.
- Observers in batches per archetype, not per entity.
- Double-precision transforms only where the authoring and physics semantics need them (D4).

## 11. Correctness and diagnostics

### 11.1 Tests without a device

Unit tests for storage, queries, command playback, observers and the scheduler. A golden corpus: each test scene
is baked and run for N frames, and a hash of the world (entities, archetypes, column contents) is compared with a
stored value, at 1, 2 and 8 workers. A journal-replay test applies a recorded sequence of scene-graph edits and
compares the world with a fresh bake of the final graph.

### 11.2 A/B against the current path

In mirror mode, the world transforms written back must equal those `SceneGraph::Refresh` computes bit for bit,
and the instance, geometry and material buffers must match after slot remapping; images must match the
references (the `ab_compare` tooling of the render-graph work).

### 11.3 Debug validation

Access checks in queries; ambiguity reports from the scheduler; stale-`Entity` checks; a check that no system
writes a column it declared as read; a check that `GpuMirrored` and simulation-visible components are
relocatable.

### 11.4 Inspector, statistics and snapshots

An ImGui inspector built on reflection: archetypes, chunk occupancy, per-system timings, change versions, entity
browser with component editing (edits go through command buffers). A binary world snapshot (chunk columns
copied for relocatable components, entity remapping on load) used by tests, by simulation replay and by
debugging captures.

## 12. Migration steps

| Step | Repository | Content | Exit criterion |
| --- | --- | --- | --- |
| E0 | donut, samples | Synthetic scene generator; baseline timings of `SceneGraph::Refresh` and `Scene::RefreshBuffers`; fix the `UnregisterLeaf` defect separately | Baseline recorded |
| E1 | donut | `donut_ecs` core: registry, entity table, archetypes, chunks, sparse sets, buffers, queries, command buffers, observers, reflection, snapshot | Device-free tests |
| E2 | donut | `IJobSystem`, scheduler, phases, ambiguity detection | Determinism tests at 1/2/8 workers |
| E3 | donut | Bridge in mirror mode: journal, bakers for donut leaves, transform/hierarchy/bounds systems, write-back; `SceneGraph::Refresh` delegates | Bit-identical transforms and bounds; samples unchanged |
| E4 | donut | Asset tables with stable slots; `GpuScene` with changed-chunk uploads; `Scene::RefreshBuffers` delegates | Buffers equal after remapping; images equal; upload cost proportional to change |
| E5 | donut (`rdg`), samples | Extraction, snapshot, visibility, draw packets, strategy adapters, upload and skinning as `IGpuPass` | Images equal; budgets of 10.1 |
| E6 | ethereal-phys, samples, motphys | Simulation domains: ethereal-phys adapter replacing `PhysSceneGraph`; SPH and GVDB bakers; MotrixSim domain over its C SDK | Parity tests pass inside scenes; MotrixSim replay deterministic |
| E7 | donut, samples | Runtime-only entities sample at scale; optional pipelining; remove `DirtyFlags` and per-node world transforms (pull-through) | Budgets of 10.1 at scale |

## 13. Open decisions

Each item gives the options and a recommendation. Review by inserting `> REV:` lines under an item.

**D1. Where the core lives.** (a) a new `donut_ecs` library; (b) a folder inside `donut_engine`. Recommendation:
(a); the core must not depend on scene types, and the separate target enforces it.

**D2. Storage model.** (a) archetype chunks only; (b) sparse sets only (EnTT); (c) archetype chunks as primary
storage plus sparse sets for flagged components (Bevy). Recommendation: (c).

**D3. Entity width.** (a) 64-bit, 32/32; (b) 32-bit with a short generation (Filament). Recommendation: (a).

**D4. Transform precision.** (a) double `WorldTransform` everywhere, float relative to a render origin at
extraction; (b) float transforms with integer origin cells per entity; (c) (a) by default plus an opt-in
float-only archetype for very large instance counts. Recommendation: (c); (a) alone matches today's semantics,
the float variant is added when a sample needs it.

**D5. Hierarchy.** (a) depth buckets as a shared component, propagated level by level; (b) per-root recursion,
parallel over roots (Unity); (c) relationship pairs that partition tables by parent (flecs).
Recommendation: (a); it stays linear and parallel for wide scenes and costs nothing for entities without a
parent.

**D6. Chunk size.** (a) 16 KiB everywhere; (b) 16 KiB by default and 64 KiB for archetypes whose rows exceed
128 bytes, so that a chunk holds at least about 128 rows; (c) 64 KiB everywhere. Recommendation: (b); the
dynamic mesh instance row of 5.5 gives only about 64 rows per 16 KiB chunk.

**D7. Assets.** (a) typed asset tables outside the entity store; (b) assets as entities. Recommendation: (a).

**D8. Render data.** (a) a frame-arena snapshot plus a persistent `GpuScene`; (b) a second world for rendering
(Bevy). Recommendation: (a).

**D9. Change detection granularity.** (a) per chunk and column; (b) per row everywhere; (c) (a) plus per-row
ticks for components flagged `RowTracked`. Recommendation: (a) now, (c) if measurement asks for it.

**D10. Job system.** (a) a new work-stealing `IJobSystem` in `donut_core` that the render graph's parallel
recording also uses; (b) extend `ThreadPool`; (c) a third-party scheduler (enkiTS, Taskflow).
Recommendation: (a), keeping the option to wrap (c) behind the interface.

**D11. Shared components for draw batching.** (a) no: sort draw packets at extraction; (b) yes: partition
chunks by mesh and material. Recommendation: (a).

**D12. Where bakers live.** (a) separate `ILeafBaker` objects registered per leaf class id; (b) a virtual `Bake`
on `SceneGraphLeaf`. Recommendation: (a): data and operations stay separate, other modules can bake donut's
leaves, and the leaf vtable does not change.

**D13. Render objects in leaves.** (a) the render service owns shadow maps keyed by entity, the leaf fields
become authoring hints; (b) keep `Light::shadowMap`. Recommendation: (a).

**D14. Non-trivial components.** (a) allowed with lifecycle hooks, but never `GpuMirrored` and never handed to
simulation domains as columns; (b) plain data only, COM references held in side tables keyed by entity.
Recommendation: (a).

**D15. Authority after the migration.** (a) pull-through: nodes keep only authored state and read derived state
from the world; (b) permanent mirror mode. Recommendation: (a) in step E7, after E3-E6 have run in mirror mode.

## 14. References

1. Unity Entities manual: <https://docs.unity3d.com/Packages/com.unity.entities@1.0/manual/index.html>
2. Unity Entities, baking: <https://docs.unity3d.com/Packages/com.unity.entities@1.0/manual/baking.html>
3. Unity Entities Graphics and `BatchRendererGroup`:
   <https://docs.unity3d.com/Packages/com.unity.entities.graphics@1.0/manual/index.html>,
   <https://docs.unity3d.com/Manual/batch-renderer-group.html>
4. Bevy ECS API: <https://docs.rs/bevy_ecs/latest/bevy_ecs/>
5. Bevy release notes 0.14, 0.15, 0.16 (observers and hooks; required components; relationships):
   <https://bevyengine.org/news/>
6. flecs: <https://github.com/SanderMertens/flecs>; relationships manual:
   <https://www.flecs.dev/flecs/md_docs_2Relationships.html>
7. S. Mertens, "Building an ECS" series: <https://ajmmertens.medium.com/>
8. EnTT: <https://github.com/skypjack/entt>
9. M. Caini, "ECS back and forth": <https://skypjack.github.io/2019-02-14-ecs-baf-part-1/>
10. Unreal Engine, Mass Entity overview: <https://dev.epicgames.com/documentation/en-us/unreal-engine/overview-of-mass-entity-in-unreal-engine>
11. NVIDIA Omniverse, USD, Fabric and USDRT: <https://docs.omniverse.nvidia.com/kit/docs/usdrt/latest/docs/usd_fabric_usdrt.html>
12. OpenUSD Hydra: <https://openusd.org/release/api/hd_page_front.html>
13. Filament (`utils/Entity.h`, `TransformManager`, `RenderableManager`): <https://github.com/google/filament>
14. N. Frykholm, "Building a Data-Oriented Entity System" (Bitsquid blog, 2014):
    <https://bitsquid.blogspot.com/2014/08/building-data-oriented-entity-system.html>
15. Unreal Engine 5 source, `FGPUScene` (`Renderer/Private/GPUScene.h`)
16. NVIDIA PhysX 5 SDK documentation, "Direct GPU API"
17. MuJoCo API types, `mjModel` and `mjData`: <https://mujoco.readthedocs.io/en/stable/APIreference/APItypes.html>
18. T. Ford, "Overwatch Gameplay Architecture and Netcode", GDC 2017:
    <https://www.gdcvault.com/play/1024001/-Overwatch-Gameplay-Architecture-and>
19. G. Fiedler, "Fix Your Timestep!": <https://gafferongames.com/post/fix_your_timestep/>
20. M. Acton, "Data-Oriented Design and C++", CppCon 2014
