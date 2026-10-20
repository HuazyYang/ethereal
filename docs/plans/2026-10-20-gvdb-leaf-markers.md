# Public leaf-marker workflow acceptance

Authorized continuation of the handoff, 2026-10-20.

The retained `gvdbMarkLeafNode` kernel assigns integer markers directly to byte
flags. The existing public host API already supplies that behavior: `editNode`
preserves exact byte assignments, and `setActive` normalizes to 0/1. Publication
through the existing immutable generation owner replaces mutable GPU pool writes.
No new interface, kernel or runtime change is necessary for this role.

## Implemented acceptance

`LeafMarkerApiFixture.h` is shared by integrated public API tests and the installed
CUDA consumer. It creates three signed adjacent leaves and records five immutable
generations: initial data; flags 0/2/255 from markers 256/258/-1; normalized and
reactivated leaves; all leaves inactive; all leaves reactivated. It checks:

- Invalid edits leave the host clean; identical boolean flags are no-ops.
- Successful mutable borrows dirty topology even without writes. Dirty preparation
  clears outputs and rejects publication; finishing advances the revision and
  leaves old tickets stale.
- Finished counts/bounds reflect nonzero flags; inactive nodes retain IDs/links.
  Host edits and finishing do not implicitly publish.
- GPU nodes preserve every serialized byte except the placement-owned atlas
  coordinates, including exact flags and internal topology nodes.
- Old snapshots retain original data after later publications and owner release.
  Reactivation initializes omitted interiors to the channel void value, without
  resurrecting old data. All channel interiors, aprons and unused slots are checked.

The first channel comparison exposed a fixture assumption: unused atlas slots
contain zero independently of the channel void value. The oracle was corrected to
the existing documented contract; runtime code did not change. An initial build
also caught an incorrect CUDA adapter field name in the test harness; it now uses
`deviceOrdinal` and validates explicit adapter arguments.

## Verification

All GPU runs were serial. Logs are local under `build/m5-leaf-markers`.

| Validation | Result | Log |
| --- | --- | --- |
| Public ABI / D3D11 / D3D12 / Vulkan / CUDA | 5/5, 3.17 s | `api-tests.log` |
| Related host/import/point/volume regressions | 11/11, 8.53 s | `related-tests.log` |
| Graphics-only, CUDA discovery disabled | 4/4, 2.65 s | `graphics-tests.log` |
| Native graphics validation, adapters 0 and 1 on each API | 6/6 | `*-adapter*.log` |
| CUDA Compute Sanitizer memcheck | Zero errors | `cuda-memcheck.log` |
| Rebuilt installed static consumer: ABI, ownership, CUDA | 3/3, 2.16 s | `installed-static-tests.log` |
| Rebuilt installed shared consumer: ABI, ownership, CUDA | 3/3, 0.62 s | `installed-shared-tests.log` |

Reproduce integrated acceptance with:

```powershell
./build.ps1 -Preset slang-next -Target gvdb_nvrhi_api_tests,gvdb_nvrhi_api_abi_tests
ctest --test-dir build -C Release -R '^gvdb_nvrhi_api_' --output-on-failure -j 1
build/bin/gvdb_nvrhi_api_tests.exe -vk --adapter 1 --validation
compute-sanitizer --tool memcheck --error-exitcode 99 build/bin/gvdb_nvrhi_api_tests.exe -cuda
```

The installed fixture is `tests/api-consumer` with
`GVDB_API_CONSUMER_CUDA_TEST=ON` and `GVDB_API_TEST_ARTIFACT` pointing to the offline
PTX remap artifact. Both libraries were rebuilt and installed before consumption.

Inventory: **48 owned-validated / 14 sample-validated / 18 portable-foundation /
20 partial / 0 pending**. These counts classify roles, not completion percentages.
GPU-authored marker ingestion and incremental key/link/delink integration are not
claimed by this host workflow. Exported rendering/section/compositing contracts,
consumer/control/visual comparisons, timing/memory, Linux and supported multi-GPU
acceptance remain open. This is focused acceptance, not a new full matrix. Keep all
legacy sources and the retained reference build path.
