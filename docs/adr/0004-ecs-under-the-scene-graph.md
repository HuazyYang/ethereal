# 0004. A data-oriented world under donut's scene graph

- Status: Accepted (2026-11-21)
- Date: 2026-11-12; revised 2026-11-18; decisions settled 2026-11-21

## Context

donut's scene is an object graph, and it does not scale or stay deterministic:

- Every `SceneGraphNode` is a heap object with about 580 bytes of transform and bounds state.
  `SceneGraph::Refresh` walks it through pointers on one thread.
- Any structural change renumbers every instance, geometry, mesh and material index. Meshes and materials
  are numbered in the iteration order of an `unordered_map` keyed by object address, so GPU indices differ
  between runs.
- `Scene::RefreshBuffers` rewrites the whole instance buffer when any transform changed, and polls every
  material each frame.
- Extensions re-implement registration and synchronisation: ethereal-phys subclasses the graph
  (`PhysSceneGraph`), the GVDB samples do the same (`GVDBSceneGraph`), and the SPH sample walks the graph
  with a private content-flag bit.

The work ahead needs structure-of-arrays data: rendering at 100k to 1M instances, and simulation domains
(ethereal-phys, the MotrixSim C SDK, SPH, GVDB). The MotrixSim work replays scenes against the original
engine, which needs inputs that are identical on every run and thread count. The samples use the
scene-graph API and must keep building.

Revision 1 of the design kept the scene graph as a separate authoring store and synchronised it into an ECS
with a change journal, bakers and write-back. Review rejected two representations of the same scene.

## Decision

Build the ECS described in [`../ecs-design.md`](../ecs-design.md).

1. **One store.** The world holds all scene data. The scene graph is an API over it: `SceneGraphNode` and the
   leaves are handles that read and write the world's columns. There is no change journal, no baker and no
   write-back. An object that is in no graph keeps its state in an orphan record that it owns; attaching moves
   the values into rows and detaching moves them back (design 5.3).
2. **Placement.** The core is part of `donut_engine`, as flat `Ecs*` files in `include/donut/engine` and
   `src/engine`, in namespace `donut::engine`. The `Ecs*` files name no scene, render or simulation type.
   `IJobSystem` sits next to `ThreadPool.h`.
3. **Data model.**
   - 64-bit entities: a 32-bit index and a 32-bit generation.
   - Archetype chunks as primary storage, with sparse sets for flagged components. Chunks are 16 KiB, or
     64 KiB for rows over 128 bytes.
   - Change versions per chunk and column. Per-row ticks for flagged components are added only if
     measurement shows chunk granularity is too coarse.
   - The hierarchy is `Parent` plus intrusive `SceneLinks`, and propagation runs by depth buckets.
   - Transforms are in double precision, made float relative to a render origin at extraction.
   - Assets live in typed tables with stable slots.
   - Components may hold COM references through lifecycle hooks, but such components are never GPU-mirrored
     and never handed to simulation domains.
4. **Leaves.** Node state and the state of leaf types iterated at scale (`MeshInstance`, simulation leaves)
   live in columns. Low-count leaf parameters (lights, cameras, animations, skinning GPU objects) stay in the
   leaf object, which the entity references through `LeafObject`. A leaf class declares its columns with a
   virtual `GetTypeDesc()`. There is one world per `SceneGraph`.
5. **Operations.** Systems run in eight phases with declared access. The scheduler reports ambiguities.
   Structural changes inside phases go through command buffers with sort keys; outside phases, the
   scene-graph API changes structure immediately. Observers replace `RegisterLeaf`, which they still call.
6. **Services.** Rendering gets a frame-arena snapshot and a persistent `GpuScene` with stable slots, uploads
   of changed rows, and draw packets sorted at extraction. After step E5 the render service owns shadow maps.
   Simulation engines implement `ISimulationDomain` (on the ABI surface) and exchange batched column views on
   a fixed step.
7. **Compatibility.** The public scene-graph API listed in design 5.7 keeps its semantics. Getters of derived
   state return by value. `GetPrev*Transform*`, `GetDirtyFlags` and `DirtyFlags` are removed; only donut used
   them.
8. **Migration** in steps E0-E7 (design 12). Step E3 switches node storage. It is verified by the unchanged
   scene-graph tests and by bit-exact per-frame dumps of world transforms and bounds from a baseline build of
   `main`.

## Consequences

### Positive

- Each item of scene state has one home, so nothing needs synchronising and nothing can disagree.
- GPU indices are stable and deterministic. Uploads and simulation exchange cost what changed.
- Transform propagation, bounds and visibility run in parallel over columns.
- Runtime-only entities cost about 250 bytes of columns and need no node object.
- Extensions use one mechanism: leaf columns, observers, queries and simulation domains.
- Simulation domains see the same order and inputs on every run, as the MotrixSim replay needs.

### Negative

- A node getter is an entity-table lookup instead of a field read.
- Getters of derived state return by value. Code that kept a reference to a node's transform must copy it.
- Node and leaf accessors have two paths, the row and the orphan record.
- Lights and cameras stay objects until a sample needs them at scale. Moving one to columns changes its API.
- No separate build target enforces that the core stays free of scene types; review and an include check do.
- Change detection over-reports: one moved entity marks its whole chunk, so uploads copy a few KiB per changed
  chunk and column.

### Risks

- Step E3 replaces node storage with no mirror to fall back on. Old and new storage cannot run in one process,
  so A/B is between builds.
- Graph teardown must detach every object that is still referenced elsewhere before it destroys the world.
  This keeps today's rule that a referenced node outlives its parent.
- Pipelined rendering depends on the scene-graph API never writing while the render graph records. Recording
  reads only the snapshot.

## Alternatives considered

- **A bridge between a separate scene graph and an ECS** (revision 1): a change journal, bakers per leaf class,
  write-back of computed transforms, and a later switch to pull-through. Rejected in review: it keeps two
  representations in sync and adds a layer between the API and the data.
- **An ECS independent of the scene graph**, with the graph left as it is: rendering and simulation would
  still not see scene-graph content as columns, and the extensions' duplication would remain.
- **A separate `donut_ecs` library**: rejected for flat files in `donut_engine`, following the render graph's
  placement in `render/`.
- The rejected options of each individual decision (D2-D20) are listed in design section 13.

## References

- Design: [`../ecs-design.md`](../ecs-design.md), revision 3.
- Code facts: `ethereal-donut` `ethereal-dev` at `4f4b31c`: `include/donut/engine/SceneGraph.h`,
  `src/engine/SceneGraph.cpp`, `src/engine/Scene.cpp`, `src/render/DrawStrategy.cpp`,
  `tests/src/engine/test_scene_graph_nodes.cpp`.
- Render graph: `docs/rdg-design.md` and ADR 0003 on the aggregate `rdg` branch.
- MotrixSim C ABI and differential replacement: ADR 0003 on the aggregate `motphys` branch.
