"""Build a release folder with an installer ZIP and accompanying licenses."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile

from assemble import assemble, ROOT

PINKY = "natives/STM/BoneSystemForNPC/Constraints/WyverianPinky_DSG.jcns.102"
LICENSES = ("LICENSE", "THIRD_PARTY_NOTICES.md", "docs/licenses/ArmorVariantManager.txt",
            "docs/licenses/LLVM-MinGW.txt", "docs/licenses/MinGW-w64.txt",
            "docs/licenses/MinGW-w64-runtime.txt", "docs/licenses/winpthreads.txt")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run(command):
    subprocess.run([str(value) for value in command], cwd=ROOT, check=True)


def build(compiler):
    compiler = Path(compiler).resolve()
    if not compiler.is_file():
        raise ValueError("Pass x64 LLVM-MinGW clang++.exe with --compiler")
    assemble()
    manifest = json.loads((ROOT / "manifest.json").read_text("utf-8"))
    out = ROOT / "out/release"
    out.mkdir(parents=True, exist_ok=True)
    (out / "build.json").write_text('{"status":"BUILDING"}\n', encoding="utf-8")
    flags = ["-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror", "-static",
             "-Wl,--no-insert-timestamp", "-I", ROOT / "vendor"]
    bridge = out / "BSFNStockBridge.dll"
    foot = out / "BSFNForefoot.dll"
    run([compiler, *flags, "-shared", ROOT / "src/bridge/bridge.cpp", "-lbcrypt", "-o", bridge])
    run([compiler, *flags, "-I", ROOT / "src/forefoot", "-shared",
         ROOT / "src/forefoot/forefoot_plugin.cpp", "-o", foot])
    notices = {name: (ROOT / name).read_bytes() for name in LICENSES}
    files = {name: (ROOT / name).read_bytes() for name in ("README.md",
             "reframework/autorun/BSNPC.lua", "reframework/autorun/BSFNStockBridge/bootstrap.lua")}
    files["reframework/plugins/BSFNStockBridge.dll"] = bridge.read_bytes()
    files["reframework/plugins/BSFNForefoot.dll"] = foot.read_bytes()
    files[PINKY] = (ROOT / "assets" / PINKY).read_bytes()
    if digest(files[PINKY]) != manifest["pinky_asset_sha256"]:
        raise ValueError("Private constraint resource differs from manifest")
    fields = {"name": f'BSFN v{manifest["version"]}', "version": manifest["version"],
              "description": "BoneSystem support for NPCs. Requires original BoneSystem separately.",
              "author": manifest["author"], "category": "Framework", "NameAsBundle": manifest["bundle"]}
    files["modinfo.ini"] = ("\r\n".join(f"{k}={v}" for k, v in fields.items()) + "\r\n").encode("utf-8")
    release_name = f'BSFN_v{manifest["version"]}'
    folder = ROOT / "dist" / release_name
    destination = folder / (release_name + ".zip")
    # The folder is the complete distribution; only its inner ZIP is installed.
    allowed = set(notices) | {destination.name}
    if not folder.resolve().is_relative_to(ROOT.resolve()):
        raise ValueError("Release folder is outside this source tree")
    for path in folder.rglob("*"):
        if path.is_symlink() or (path.is_file() and path.relative_to(folder).as_posix() not in allowed):
            raise ValueError(f"Use a clean release folder; unexpected entry: {path}")
    folder.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".zip.tmp")
    with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            item = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            item.compress_type = zipfile.ZIP_DEFLATED
            item.external_attr = 0o100644 << 16
            archive.writestr(item, data)
    with zipfile.ZipFile(temporary) as archive:
        if archive.testzip() or archive.namelist() != sorted(files):
            raise ValueError("Installer ZIP verification failed")
        if any(archive.read(name) != data for name, data in files.items()):
            raise ValueError("Installer ZIP content differs")
    for name, data in notices.items():
        path = folder / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    temporary.replace(destination)
    result = {"status": "BUILT", "version": manifest["version"],
              "release_folder": folder.relative_to(ROOT).as_posix(),
              "archive": destination.name, "sha256": digest(destination.read_bytes()),
              "accompanying_files": {name: digest(data) for name, data in sorted(notices.items())},
              "files": {name: digest(data) for name, data in sorted(files.items())}}
    (out / "build.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", required=True)
    build(parser.parse_args().compiler)
