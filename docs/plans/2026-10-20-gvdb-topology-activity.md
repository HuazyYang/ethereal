# GPU topology activity orchestration

The public topology-edit API now has an additive activity factory. It records
actual Slang marker, leaf-delink, internal-delink, child-list initialization and
top-down linking on private fixed pools. Internal flags derive from active
descendants. Inactive nodes are reconnected before validated fetch, preserving
the owner's graph invariant and enabling later reactivation. Pool allocation,
GPU key-driven growth and compaction remain separate work.

The standalone link kernels now use integer geometry, including tests at signed
coordinates beyond float's exact integer range. Public publication keeps its
existing narrower coordinate domain; owned tests exercise large signed positions
within that contract.

Tests independently compute internal activity by walking original CPU parent
chains. Empty and leaf-root graphs, 257-leaf tail dispatches, ten-level signed
hierarchies, all-inactive/reactivated/sparse markers, nonboolean marker values,
marker subranges, repeated recording, exact allocation budgets, stale revisions,
pool counts, node geometry and every restored child slot are checked. Existing
fetch tests continue checking retained node/channel bytes and transactional
publication failure.

Initial NVIDIA D3D12 testing exposed incomplete level updates when repeatedly
rewriting one constant-buffer range. Distinct immutable ranges for every dispatch
resolve that failure on NVIDIA and AMD. This is a bounded constant-buffer layout,
not a claim to have identified a driver root cause. Vulkan native validation also
caught a storage-view alignment issue for marker subranges; shader indexing now
applies the offset while binding the whole structured buffer.

Samples implementation `3864daf`: focused topology/compute checks pass **9/9**;
final native graphics **6/6**, CUDA memory **zero errors**, graphics-only owner/
point checks **11/11**, and rebuilt installed static/shared consumers **2/2 each**.
The installed consumers use offline artifacts with compiler/CUDA-toolkit package
discovery disabled. Full aggregate matrices are recorded separately.
Artifacts are under `build/acceptance/topology-edit`. The unchanged public edit
interfaces keep their vtables and IIDs; the activity factory has a new IID and
exported entry point. No retained reference is retired by this slice.
