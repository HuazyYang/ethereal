"""Run a serial CTest matrix and reject missing coverage, failures and skipped tests.

This validates one platform job, not the whole project's acceptance. Required
peer hardware, installed-package jobs, reference comparisons and other platforms
remain separate evidence. Configure NVRHI_TEST_REQUIRE_CUDA_PEER=ON for the peer job.
"""
import argparse
import json
from pathlib import Path
import platform
import subprocess
import sys
import xml.etree.ElementTree as ET


def output(command, cwd=None):
    return subprocess.check_output(command, cwd=cwd, text=True, encoding="utf-8").strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--profile", choices=["windows-full", "windows-graphics", "linux-full", "linux-graphics"], required=True)
    parser.add_argument("--configuration", default="Release")
    parser.add_argument("--require-peer", action="store_true")
    parser.add_argument("--require-clean", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if (args.profile.startswith("windows") and sys.platform != "win32") or (
            args.profile.startswith("linux") and not sys.platform.startswith("linux")):
        parser.error("profile must match the actual operating system")
    if args.require_peer and args.profile.endswith("graphics"):
        parser.error("required peers need a full CUDA configuration")
    root = Path(__file__).resolve().parents[1]
    build, folder = args.build.resolve(), args.output.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    revision = output(["git", "rev-parse", "HEAD"], root)
    submodules = output(["git", "submodule", "status", "--recursive"], root)
    dirty = output(["git", "status", "--porcelain", "--untracked-files=normal"], root)
    if args.require_clean and (dirty or any(line.startswith(("+", "-", "U")) for line in submodules.splitlines())):
        raise RuntimeError("Acceptance requires clean sources and submodules at committed parent gitlinks")
    ctest = ["ctest", "--test-dir", str(build), "-C", args.configuration]
    listing = json.loads(output(ctest + ["--show-only=json-v1"]))
    names = {test["name"] for test in listing["tests"]}
    apis = ["VULKAN"]
    if args.profile.startswith("windows"):
        apis += ["DX11", "DX12"]
    required = set()
    if args.profile.endswith("full"):
        apis += ["CUDA"]
        required |= {"cuda_compute", "cuda_slang_optix", "cuda_native_interop", "cuda_vulkan_interop"}
        required.add("slang_graphics_interop_VULKAN")
    if args.require_peer:
        required.add("cuda_required_peer")
    for api in apis:
        required |= {f"gvdb_owned_modes_{api}", f"gvdb_owned_sections_{api}", f"gvdb_render_file_{api}",
                     f"gvdb_owned_layers_{api}", f"gvdb_render_layers_{api}"}
        required |= {f"gvdb_render_mode_{mode}_{api}" for mode in range(8)}
    missing = sorted(required - names)
    if missing:
        raise RuntimeError(f"Configuration omits required tests: {missing}")
    junit = folder / "ctest.xml"
    result = subprocess.run(ctest + ["--parallel", "1", "--no-tests=error", "--output-on-failure",
                                   "--output-junit", str(junit), "--output-log", str(folder / "ctest.log")])
    if not junit.exists():
        raise RuntimeError("CTest did not produce its result report")
    cases = ET.parse(junit).getroot().findall(".//testcase")
    bad = [case.get("name") for case in cases
           if case.find("skipped") is not None or case.find("failure") is not None or case.find("error") is not None]
    absent = sorted(names - {case.get("name") for case in cases})
    report = {"profile": args.profile, "platform": platform.platform(), "commit": revision,
              "submodules": submodules.splitlines(), "dirty": dirty.splitlines(),
              "requirePeer": args.require_peer, "testCount": len(cases), "failedOrSkipped": bad,
              "missingResults": absent, "ctestExitCode": result.returncode,
              "passed": not result.returncode and not bad and not absent}
    (folder / "acceptance.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    if not report["passed"]:
        raise RuntimeError(f"Acceptance failed: failed/skipped={bad}, missing results={absent}, exit={result.returncode}")
    print(f"{args.profile}: {len(cases)} tests passed without skips; {folder / 'acceptance.json'}")


if __name__ == "__main__":
    main()
