# Remote Linux developer handoff: H1 CUDA peer acceptance

This is the only remaining acceptance gate for the Ethereal Slang-next plan.
Linux L0-L4 and Windows W1 are complete. Do not close the plan or retire the
legacy references until this H1 job succeeds on a supported two-CUDA-GPU host.

## Exact source checkpoint

Use aggregate branch `slang-next` at commit `b7e78ea` or a later descendant that
preserves these recursive gitlinks:

| Component | Required revision |
| --- | --- |
| Aggregate | `b7e78ea` |
| NVRHI | `7c6a8944dfcaaba907906714292fd76511565d3f` |
| Samples | `d8acf1eddab61c7adb01e2fd5a74c0e6c6deaef6` |
| Donut | `c7ca1b2f451d1d1ec26525fedad32c7ccdfbf768` |
| Nested shader-tool | `15b6ab0875b88f41cd6c197f0b9c9bba7e5d0b53` |

Start from a clean recursive checkout. Do not substitute moving submodule branch
tips. Record `git rev-parse HEAD`, `git status --short`, and
`git submodule status --recursive` before building.

## Hardware requirement

Use a Linux host with two CUDA-visible GPUs that support native peer access and
peer copies. Record each GPU name, UUID, PCI identity, driver, CUDA version,
CUDA ordinals, topology, and the directional peer capability matrix. A single
CUDA GPU, a display-only non-CUDA adapter, or a peer-unsupported pair does not
satisfy H1.

The previously configured `work-studio` host (`fysics`) has only one RTX 5070 Ti
and is not suitable. Do not mark H1 passed there.

## Required run

Set the Linux CUDA/OptiX/Vulkan toolchain paths for the host, then run GPU jobs
serially:

```sh
cmake --preset slang-next-linux -B build/linux-peer \
  -DOPTIX_ROOT="$OPTIX_ROOT" \
  -DNVRHI_TEST_REQUIRE_CUDA_PEER=ON \
  -DNVRHI_TEST_CUDA_LOCAL_ADAPTER=0 \
  -DNVRHI_TEST_CUDA_PEER_ADAPTER=1
cmake --build build/linux-peer --config Release --parallel 4
python3 tools/run-slang-acceptance.py \
  --build build/linux-peer --profile linux-full --require-peer --require-clean \
  --output build/acceptance/linux-peer
```

The required test must be present and pass. A missing adapter, unsupported peer
route, developer skip, or absent result is a failed H1 job. Do not weaken
`--require-peer`, remove the test, or count a negative single-GPU diagnostic as
success.

Run the direct diagnostic as well and retain its output:

```sh
build/linux-peer/bin/nvrhi_cuda_interop \
  --require-peer --peer-only --adapter 0 --peer-adapter 1
```

Verify both supported transfer directions where the hardware reports them. For
any unsupported reverse direction, retain an explicit rejection result rather
than silently omitting it. Run the native Vulkan validation and CUDA memcheck
routes from the Linux checklist if the peer host uses a different adapter
mapping or driver stack.

## Return package

Return a commit or immutable result bundle containing:

- aggregate revision and recursive gitlinks;
- clean-source status and complete toolchain versions;
- GPU identities, ordinals, topology, and peer-capability matrix;
- `build/acceptance/linux-peer/acceptance.json`, CTest XML/logs, and direct
  diagnostic output;
- failed, skipped, unavailable, and unsupported directional routes;
- confirmation that no host-staging fallback was used.

Update [the Linux checklist](slang-next-linux-todos.md) and
[the main handoff](slang-next-handoff.md) only after the required-peer report
passes and the evidence is reviewed. Then perform final reconciliation and
retained-reference disposition.
