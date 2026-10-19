# Fluid reconstruction with public owned snapshots

Status: implemented; focused Windows acceptance recorded, 2026-10-19.

Retain the existing Slang FLUIDS-v3 SPH simulation and its explicit GPU position
readback for host topology. Filter the legacy invalid-particle sentinel and copy
associated color bytes in ordinal order. Public point conversion creates canonical
PointSets; public host activation uses leaf32 and floor-based radius-two
asymmetric support (the generic legacy point topology mode truncates negatives). Publish a fresh level-set channel (void3), optional RGBA8 channel,
ordinary radius-one/four-voxel-subcell gather, then scalar apron refresh. Replace
the visible state only after all preparation/publication steps succeed.

Use public snapshots for mixed RT and owned compute level-set rendering. Use the
public host topology for overlays/statistics. Diagnostic readback remains explicit;
keep the old CPU topology builder only for independent reference tests. No legacy
GPU volume, gather adapter or publication shader is used in production.

Verify signed support, exact color association, scalar/color/apron behavior,
invalid-particle filtering, failed replacement preserving the old publication,
retained old snapshot lifetime, SPH controls and full-particle fixtures. Compare
compute/RT captures with preserved portable output, run native validation on both
graphics adapters and CUDA memory checking. Keep broad performance, legacy visual
and external platform/retirement gates open.

## Acceptance and findings

The generic legacy point-topology mode truncates signed coordinates. Fluid's
existing semantics use floor, so the sample computes exact leaf origins and
activates them through the public host interface. The retained CPU topology
builder now serves only independent reference tests. GPU source conversion,
gather/aprons and rendering use public owned storage. Both scalar and color
views are retained by a single publication; no duplicate GPU volume remains.

Initial acceptance passes 19/19 in 21.80 seconds. Expanded rollback, sentinel
association and retained-snapshot tests pass all seven compute/RT analytic cases
in 7.33 seconds. The late rejection fixture uploads valid individual coordinates
whose combined extent exceeds the configured hierarchy, proving that partial
private reconstruction does not replace the visible state. Removing color in a
subsequent frame leaves retained previous scalar/color buffers unchanged.

Native validation passes all six graphics compute combinations and all four RT
combinations on NVIDIA/AMD. CUDA memcheck reports zero errors. Graphics-only fluid
and interactive acceptance passes 24/24 in 22.65 seconds, and a tests-disabled,
CUDA-discovery-disabled production run passes on explicit AMD D3D11.

Captured full-preset RT is identical to preserved portable output on all three
RT APIs. Compact compute changes three or four pixels by one byte; compact RT
changes one byte per API, and full D3D11 changes one byte. Logs, captures and
`image-comparison.json` are under `build/m5-fluid-owned`.

Earlier full matrices 339/339 and 256/256 precede the interactive/fluid consumer
changes; the focused tests above cover these migrations. Inventory counts remain
32 owned-validated, 12 sample-validated, 27 portable-foundation, 23 partial and
6 pending. Deposition, remaining spray/other operator contracts, Linux, native
multi-GPU and broad visual/performance/reference-retirement gates continue.
