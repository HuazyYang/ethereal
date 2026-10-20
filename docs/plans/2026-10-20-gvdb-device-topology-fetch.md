# Private GPU topology edits and validated fetch

Status: implemented and focused Windows acceptance passed, 2026-10-20.

The public topology owner previously accepted only host-authored revisions.
`GVDBNvrhiTopologyEditApi` now provides a fixed-pool device-authoring transaction:
prepare private node/child buffers, record the initial copy, record Slang edits,
record readback, explicitly complete on the caller's queue, validate actual GPU
bytes and prepare an ordinary generation publication ticket. Published snapshot
buffers are never writable edit targets.

The current finished host revision and publication must agree before editing.
An authenticated baseline captures owner, host, channel configuration and
publication revisions. Any intervening change rejects begin/fetch/finish;
the ordinary publication ticket also rechecks its base. This provides explicit
authority without blocking independent host work: conflicting device edits fail
instead of silently overwriting the host. No implicit submission/wait occurs.

Counts, root and level metadata come from the authenticated publication, never
untrusted GPU counters. The CPU importer validates reciprocal links, ownership,
root connectivity and geometry, recomputes bounds, discards atlas placement and
normalizes pool layouts. Publication advances the identity epoch and remaps
compatible channel interiors by signed origin. Exact flag bytes remain intact.
Readback payload, private-copy/staging allocation and publication each have
explicit limits; CPU clones/import use the owner's per-pool limit.

This is an additive factory with new interface IDs and installed headers. Existing
interfaces/vtables stay unchanged. Installed static/shared consumers run actual
GPU editing from offline marker artifacts with compiler/toolkit discovery disabled.

The new public-only fixture dispatches the retained portable `applyLeafMarkers`
program, validates actual GPU flags, publication bounds/epoch and channel
preservation, then exercises exact nonboolean flags, all-inactive/reactivated
graphs, empty graphs, retained lifetime, malformed orphans, budgets and stale
host/configuration/publication rejection. The same fixture runs through both
installed library forms.

Pool growth and disconnected delinked pools remain outside this transaction's
contract. A delink builder must reconnect inactive nodes or compact to a valid
graph before publication; this API deliberately rejects orphan records. GPU key
integration and incremental link/delink orchestration therefore remain open,
as do broader performance and required Linux/real-peer platform acceptance.

Validation: five new API/ABI tests pass; the affected owner/point set passes
14/14 and adoption/accumulation passes 8/8. Graphics-only affected tests pass
11/11. All six native D3D11/D3D12/Vulkan adapter runs pass, CUDA memcheck reports
zero errors, and installed static/shared consumers pass 2/2 each. The final
fixture also verifies the original GPU node bytes remain unchanged. Logs and
standalone package builds are under `build/acceptance/topology-edit`.
The prior 433/326 complete matrices predate this additive API.
