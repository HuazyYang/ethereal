# Public ray-record queries and spray adoption

Implemented an additive device-only public query over authenticated immutable
snapshots and copied 64-byte legacy-layout `RayRecord` inputs. New interfaces and
factory leave all existing vtables intact. The Slang entry reuses the established
wavefront traversal and adds exact transport of caller metadata and miss normals.
Separate GPU hits/normals retain explicit miss/exhaustion status. Completion maps
caller-ordered readback; neither preparation nor recording submits or waits.

Spray now builds records from its CPU wand rays, records the public query, completes
one readback and passes the retained GPU hit buffer to deposition. Owner snapshots
remain the only topology/channel source. The SDK ships the header, factory,
documentation and offline sources without introducing compiler/SDK runtime needs.

## Acceptance (2026-10-20)

- Public ABI and four-backend query: **5/5**, 3.46 seconds.
- Spray analytic/asset/control/application/window: **19/19**, 21.57 seconds.
- Graphics-only query and spray: **19/19**, 27.90 seconds, CUDA discovery disabled.
- Native NVIDIA/AMD D3D11/D3D12/Vulkan: **6/6**.
- CUDA Compute Sanitizer: **zero errors**.
- Installed static/shared consumers: **2/2 each**, 0.39/0.41 seconds.
- Twenty 128x96, three-frame, five-mode spray captures: **all byte-identical** to
  the preserved `build/m5-spray-owned` captures.

Logs and image comparison JSON are under `build/m5-ray-query`. The reusable public
fixture covers signed roots, 259-ray tails, forward/reverse wavefronts, bias,
gradients, NaN/zero/missing rays, unnormalized large directions, empty topology,
zero allocations, traversal exhaustion, exact preparation budgets, old snapshots
after publication, source/operator/owner release, immutable record bytes and actual
GPU/CPU coherence. The driver checks QI and malformed artifact metadata. The same
fixture runs through the installed static/shared ABI.

The record contract matches defined legacy writes. Geometric DDA and explicit
iteration limits retain the existing portable repairs; no equivalence to undefined
or nonterminating CUDA boundary behavior is claimed. Timing/memory, Linux,
supported multi-GPU and full legacy visual gates remain open. Section/compositing
and individual rendering modes are next. Inventory: **49/14/17/20/0**.
