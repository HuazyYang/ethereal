# Slang-next Linux developer handoff

Status: **deferred to a Linux-host developer by the user on 2026-10-20**. These
unchecked jobs remain required for final project acceptance. They do not block
continued Windows implementation, packaging checks or documentation. Do not mark
them passed from Windows results or retire the retained reference prematurely.

## Inputs and return contract

Use the aggregate `slang-next` checkout containing this document and its exact
recursive gitlinks. The last fully validated implementation is aggregate
`f2eae3e`, samples `40174a9`, NVRHI `2c06d77`, Donut `c7ca1b2`, shader-tool
`15b6ab0`; subsequent aggregate commits add handoff/validation tooling. Ensure
these commits have been transferred to the Linux checkout before starting;
following moving submodule branch tips is not equivalent.

- [ ] L0: Record `git rev-parse HEAD`, `git submodule status --recursive`, clean
  source status, OS/kernel, compiler/CMake/Ninja versions, Slang compiler identity,
  CUDA/OptiX versions, Vulkan driver/layers and GPU UUIDs/ordinals.
- [ ] Return a commit containing fixes, updated parent gitlinks and a concise
  result table. Preserve full logs, JUnit and `acceptance.json` outside source.
  Report failed, skipped and unavailable jobs explicitly. Do not import Windows
  test counts as expected Linux counts; required backend coverage must be present.

Baseline toolchains are Slang 2026.10.2, CUDA 12.9 and OptiX 9.0. Install a C++17
compiler, CMake >= 3.24, Ninja, Vulkan SDK/loader/validation layers and the X11
development packages listed in the `linux` preset. Native window cases require
a working display on the GPU under test. Set `OPTIX_ROOT` to the Linux SDK root.
Run GPU processes serially, including captures, sanitizer and package consumers.

## L1: Full Linux Vulkan/CUDA/OptiX matrix

```sh
cmake --preset slang-next-linux -B build/linux-full -DOPTIX_ROOT="$OPTIX_ROOT"
cmake --build build/linux-full --config Release --parallel 4
python3 tools/run-slang-acceptance.py --build build/linux-full --profile linux-full --require-clean --output build/acceptance/linux-full
```

- [ ] All tests succeed without unexpected skips. In particular, retain evidence
  for CUDA compute/OptiX, native interop, Vulkan external-memory/semaphore interop,
  public ownership/topology, GPU point discovery, rendering and sample windows.
- [ ] Investigate Linux FD ownership, dedicated allocations, offsets and repeated
  semaphore acquisition/release if interop fails. Do not substitute CPU staging.

## L2: Vulkan-only and tests-disabled production

```sh
cmake --preset slang-next-linux-graphics -B build/linux-graphics -DCMAKE_DISABLE_FIND_PACKAGE_CUDAToolkit=TRUE
cmake --build build/linux-graphics --config Release --parallel 4
python3 tools/run-slang-acceptance.py --build build/linux-graphics --profile linux-graphics --require-clean --output build/acceptance/linux-graphics

cmake --preset slang-next-linux-graphics -B build/linux-production -DBUILD_TESTING=OFF -DGVDB_NVRHI_BUILD_API_TESTS=OFF -DCMAKE_DISABLE_FIND_PACKAGE_CUDAToolkit=TRUE
cmake --build build/linux-production --config Release --parallel 4 --target point-cloud interactive-optix
build/linux-production/bin/point-cloud -vk --headless --samples 2 --verify-volume --width 128 --height 96 --output build/acceptance/linux-production.png
build/linux-production/bin/interactive-optix -vk --self-test
```

- [ ] Graphics-only matrix passes without CUDA discovery.
- [ ] Production runs pass and match the equivalent Vulkan configuration within
  documented fixture tolerances. Compare like configurations; Windows found
  small differences between graphics-only and CUDA-enabled builds.

## L3: Native diagnostics and memory checking

Use each supported adapter's actual Vulkan ordinal with the commands below;
do not assume its ordinal equals the CUDA ordinal.

```sh
build/linux-full/bin/gvdb_slang_tests -vk --adapter 0 --validation
build/linux-full/bin/gvdb_nvrhi_topology_edit_tests -vk --adapter 0 --validation
build/linux-full/bin/gvdb_point_cloud_reconstruction_tests -vk --adapter 0 --validation
build/linux-full/bin/gvdb_scene_rt_tests -vk --adapter 0 --validation
compute-sanitizer --tool memcheck --error-exitcode 99 build/linux-full/bin/gvdb_nvrhi_topology_edit_tests -cuda
compute-sanitizer --tool memcheck --error-exitcode 99 build/linux-full/bin/gvdb_scene_rt_tests -cuda
compute-sanitizer --tool memcheck --error-exitcode 99 build/linux-full/bin/gvdb_point_cloud_reconstruction_tests -cuda --asset ethereal-samples/src/gvdb_samples/samples/assets
```

- [ ] Native validation has no errors; review warnings rather than accepting only
  process exit codes. CUDA memory checking reports zero errors. Include public
  owner/generation lifetime and atlas remap checks in the diagnostic run.

## L4: Installed SDK and compiler-free deployment

- [ ] Build/install compiler-independent ShaderTool artifacts with
  `SHADERTOOL_BUILD_COMPILER=OFF` and `SHADERTOOL_BUILD_TESTS=OFF`.
- [ ] Build/install standalone NVRHI static and shared SDKs against that prefix,
  with `NVRHI_INSTALL=ON`, `NVRHI_INSTALL_EXPORTS=ON`, `NVRHI_WITH_SLANG=ON`,
  `NVRHI_WITH_CUDA=ON`, `NVRHI_WITH_OPTIX=ON`, `NVRHI_WITH_VULKAN=ON` and
  `OPTIX_ROOT`. Build and test `ethereal-nvrhi/tests/installed-consumer` against
  each installed SDK, with CUDA toolkit discovery disabled in the consumer.
- [ ] Build/install both GVDB linkage variants using the committed portable
  wrapper below. Use installed NVRHI rather than aggregate build-tree targets.
  Repeat the commands with `kind=shared; shared=ON`.

```sh
kind=static
shared=OFF
# Set NVRHI_PREFIX to the installed runtime SDK (and its artifact dependencies).
cmake -S tools/gvdb-acceptance-package -B "build/gvdb-package-$kind" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$NVRHI_PREFIX" -DCMAKE_INSTALL_PREFIX="$PWD/build/gvdb-sdk-$kind" -DGVDB_NVRHI_API_SHARED="$shared" -DCMAKE_DISABLE_FIND_PACKAGE_CUDAToolkit=TRUE
cmake --build "build/gvdb-package-$kind" --parallel 4
cmake --install "build/gvdb-package-$kind"
ctest --test-dir "build/gvdb-package-$kind" --output-on-failure --no-tests=error

cmake -S ethereal-samples/src/gvdb_samples/gvdb/tests/topology-edit-api-consumer -B "build/gvdb-topology-consumer-$kind" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$PWD/build/gvdb-sdk-$kind;$NVRHI_PREFIX" -DCMAKE_DISABLE_FIND_PACKAGE_CUDAToolkit=TRUE -DGVDB_TOPOLOGY_EDIT_CONSUMER_CUDA_TEST=ON -DGVDB_OWNER_TEST_ARTIFACT="$PWD/build/linux-full/bin/shaders/gvdb_owner/ptx/GVDBAtlasRepack_relocateAtlas.bin" -DGVDB_MARKER_TEST_ARTIFACT="$PWD/build/linux-full/bin/shaders/gvdb_slang/ptx/GVDBTopology_applyLeafMarkers.bin"
cmake --build "build/gvdb-topology-consumer-$kind" --parallel 4
ctest --test-dir "build/gvdb-topology-consumer-$kind" --output-on-failure --no-tests=error
```

- [ ] Also configure `tests/ray-query-api-consumer` under the same GVDB source
  directory, with `GVDB_RAY_QUERY_CONSUMER_CUDA_TEST=ON`, the same owner artifact,
  and `GVDB_RAY_QUERY_TEST_ARTIFACT` pointing to
  `build/linux-full/bin/shaders/gvdb_ray_query/ptx/GVDBRayRecords_queryRayRecords.bin`.
  Both consumers must run their CUDA case as well as their ABI case.
- [ ] Stage actual application binaries, runtime `.so` dependencies and offline
  shaders into a separate runtime directory. Check RPATH/loader resolution and
  run compute, RT and production GVDB fixtures without Slang/NVRTC libraries or
  SDK search paths. CUDA driver PTX JIT and OptiX remain valid runtime requirements.
  The Windows-only `tools/run-slang-isolated-runtime.py` documents the analogous
  deployment check; port its isolation to Linux rather than claiming it ran there.

## H1: Supported real CUDA peers (separate hardware prerequisite)

The user deferred Linux work; the peer requirement is still required and has not
been waived. The Linux developer should run this if their host has a supported
pair. Otherwise return it as **unassigned hardware work**, not a Linux pass.

```sh
cmake --preset slang-next-linux -B build/linux-peer -DOPTIX_ROOT="$OPTIX_ROOT" -DNVRHI_TEST_REQUIRE_CUDA_PEER=ON -DNVRHI_TEST_CUDA_LOCAL_ADAPTER=0 -DNVRHI_TEST_CUDA_PEER_ADAPTER=1
cmake --build build/linux-peer --config Release --parallel 4
python3 tools/run-slang-acceptance.py --build build/linux-peer --profile linux-full --require-peer --require-clean --output build/acceptance/linux-peer
```

- [ ] Substitute the actual supported ordinals. Verify real native transfers and
  retain pair capability/identity evidence. Run supported directional routes;
  unsupported reverse directions must reject explicitly.
- [ ] Missing or unsupported required hardware fails the job. Do not delete the
  required test or count the Windows single-CUDA-adapter negative case as success.

## Final reconciliation

- [ ] Record each job's tested aggregate commit and recursive gitlinks, result,
  hardware and artifact paths. Rerun affected Windows jobs if Linux fixes change
  shared runtime, shader, ABI or ownership behavior.
- [ ] Update `docs/slang-next-status.md` and `docs/slang-next-handoff.md` once the
  returned evidence is reviewed. Final acceptance and reference retirement stay
  pending until both Linux and supported-peer requirements are satisfied.
