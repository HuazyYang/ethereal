"""Stage and run Windows production samples with only runtime DLLs and offline shaders.

Uses existing CTest command/oracle definitions, but never runs the build-directory
executables. Source assets remain available: this checks shader/compiler deployment,
not an asset redistribution package. Run serially with every other GPU job.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


def required_names(graphics_only):
    apis = ["DX11", "DX12", "VULKAN"] + ([] if graphics_only else ["CUDA"])
    names = {"slang_render_shader_specializations_VULKAN"}
    families = ("gvdb_render_file", "gvdb_render_kernel", "gvdb_sph_pool",
                "gvdb_resample_head", "gvdb_print_lucy", "gvdb_point_cloud_compute",
                "gvdb_fluid_compute", "gvdb_spray_application", "gvdb_point_fusion_city")
    for api in apis:
        names.update(f"{family}_{api}" for family in families)
        names.add(f"slang_headless_{'cuda' if api == 'CUDA' else api}")
        if api != "CUDA":
            names.add(f"slang_render_basic_triangle_{api}")
            names.add(f"gvdb_depth_map_asset_{api}_graphics")
            if not graphics_only:
                names.add(f"gvdb_depth_map_asset_{api}_cuda")
        if api != "DX11":
            names.add(f"gvdb_point_cloud_rt_{api}")
            names.add(f"gvdb_fluid_rt_{api}")
            names.add(f"gvdb_interactive_optix_asset_{api}_volume")
            if api != "CUDA":
                names.add(f"slang_render_rt_triangle_{api}")
    return names


def source_state(root):
    def git(*arguments):
        return subprocess.check_output(["git", *arguments], cwd=root, text=True).splitlines()
    return {"commit": git("rev-parse", "HEAD")[0],
            "submodules": git("submodule", "status", "--recursive"),
            "dirty": git("status", "--porcelain")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="new directory; never overwrites a previous package")
    parser.add_argument("--graphics-only", action="store_true")
    parser.add_argument("--require-clean", action="store_true")
    parser.add_argument("--dumpbin", type=Path, help="MSVC dumpbin; discovered with vswhere when omitted")
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("this deployment check is Windows-specific; Linux is a separate host TODO")
    build, output = args.build.resolve(), args.output.resolve()
    root = Path(__file__).resolve().parents[1]
    state = source_state(root)
    if args.require_clean and (state["dirty"] or any(
            line.startswith(("+", "-", "U")) for line in state["submodules"])):
        raise RuntimeError("Deployment acceptance requires clean committed sources and parent gitlinks")
    listing = json.loads(subprocess.check_output(
        ["ctest", "--test-dir", str(build), "-C", "Release", "--show-only=json-v1"], text=True))
    tests = {t["name"]: t for t in listing["tests"]}
    required = required_names(args.graphics_only)
    missing = sorted(required - tests.keys())
    if missing:
        raise RuntimeError(f"Required sample coverage missing: {missing}")
    dumpbin = args.dumpbin
    if dumpbin is None:
        vswhere = Path(os.environ["ProgramFiles(x86)"]) / "Microsoft Visual Studio/Installer/vswhere.exe"
        found = subprocess.check_output([str(vswhere), "-latest", "-products", "*", "-find",
            "VC/Tools/MSVC/**/bin/Hostx64/x64/dumpbin.exe"], text=True).splitlines()
        if not found:
            raise RuntimeError("MSVC dumpbin was not found; supply --dumpbin")
        dumpbin = Path(found[0])
    output.mkdir(parents=True, exist_ok=False)
    package = output / "runtime"
    package.mkdir()
    logs = output / "logs"
    logs.mkdir()
    images = output / "images"
    images.mkdir()
    selected = [tests[name] for name in sorted(required)]
    executables = {Path(t["command"][0]) for t in selected}
    # Audit the transitive Ninja compile/link commands, including static libraries.
    ninja_file = "build-Release.ninja" if (build / "build-Release.ninja").is_file() else "build.ninja"
    commands = subprocess.check_output(["ninja", "-C", str(build), "-f", ninja_file, "-t", "commands",
        *sorted(exe.stem for exe in executables)], text=True, encoding="utf-8", errors="replace")
    (output / "production-commands.log").write_text(commands, encoding="utf-8")
    forbidden_commands = re.compile(r"\bgpdevice|\bthrust\b|\bcudart|\bnvcc(?:\.exe)?\b|\.(?:cu|cuh)(?:[\"\s]|$)", re.I)
    if forbidden_commands.search(commands):
        raise RuntimeError("Production build graph includes a retained CUDA/GP dependency; inspect production-commands.log")
    for exe in executables:
        shutil.copy2(exe, package / exe.name)
    # Explicit runtime allowlist: never copy the compiler DLLs in build/bin.
    shutil.copy2(build / "bin/nvrhi_core.dll", package / "nvrhi_core.dll")
    shutil.copytree(build / "bin/D3D12", package / "D3D12")
    # Copy only executable artifacts and legacy precompiled graphics blobs.
    for source in (build / "bin/shaders").rglob("*"):
        if source.is_file() and source.suffix.lower() in (".bin", ".nvsp"):
            destination = package / "shaders" / source.relative_to(build / "bin/shaders")
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
    imports = {}
    forbidden = re.compile(r"(?:slang|nvrtc|cudart|gpdevice|shadertool)", re.I)
    for binary in sorted(package.rglob("*")):
        if binary.suffix.lower() not in (".exe", ".dll"):
            continue
        result = subprocess.check_output([str(dumpbin), "/DEPENDENTS", str(binary)])
        dependencies = sorted(set(re.findall(rb"[\w.+-]+\.dll", result, flags=re.I)))
        imports[str(binary.relative_to(package))] = [name.decode("ascii") for name in dependencies]
        if any(forbidden.search(name.decode("ascii")) for name in dependencies):
            raise RuntimeError(f"Forbidden production dependency in {binary}: {dependencies}")
    # Drop developer PATH, SDK roots, compiler overrides and working directories.
    env = {key: value for key, value in os.environ.items()
           if key.upper() in {"SYSTEMROOT", "WINDIR", "TEMP", "TMP", "USERPROFILE", "LOCALAPPDATA", "APPDATA"}}
    env["PATH"] = str(Path(os.environ["SystemRoot"]) / "System32")
    report = {"scope": "Windows isolated offline-shader execution; source assets remain available",
              "sourceBuild": str(build), "graphicsOnly": args.graphics_only,
              "imports": imports, "environmentPath": env["PATH"], "tests": []}
    report.update(state)
    report["buildGraphAudit"] = "No GPDevice, Thrust, cudart, NVCC or .cu/.cuh compilation in selected target commands"
    report["files"] = {str(p.relative_to(package)): hashlib.sha256(p.read_bytes()).hexdigest()
                       for p in sorted(package.rglob("*")) if p.is_file()}
    for test in selected:
        command = [str(package / Path(test["command"][0]).name), *test["command"][1:]]
        for i, value in enumerate(command[:-1]):
            if value in ("--output", "--screenshot"):
                command[i + 1] = str(images / f"{test['name']}{Path(command[i + 1]).suffix}")
        start = time.perf_counter()
        with (logs / f"{test['name']}.log").open("w", encoding="utf-8") as log:
            try:
                result = subprocess.run(command, cwd=package, env=env, stdout=log,
                                        stderr=subprocess.STDOUT, timeout=240)
                code = result.returncode
            except subprocess.TimeoutExpired:
                code = "timeout"
        # A developer skip (77) fails this required deployment job.
        report["tests"].append({"name": test["name"], "command": command, "exitCode": code,
                                "processSeconds": time.perf_counter() - start})
        print(f"{'PASS' if code == 0 else 'FAIL'} {test['name']}", flush=True)
    report["sourceUnchanged"] = source_state(root) == state
    report["passed"] = report["sourceUnchanged"] and all(t["exitCode"] == 0 for t in report["tests"])
    (output / "acceptance.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if not report["passed"]:
        raise SystemExit("Isolated runtime acceptance failed; inspect the per-test logs")
    print(f"PASS {len(selected)} isolated production runs; {output / 'acceptance.json'}")


if __name__ == "__main__":
    main()
