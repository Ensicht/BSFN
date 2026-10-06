"""Generate formal and commented Lua from the same ordered source units."""

import argparse
import hashlib
import json
from pathlib import Path

from lua_source import executable_tokens, strip_comments

ROOT = Path(__file__).resolve().parent.parent
RUNTIME = Path("reframework/autorun/BSNPC.lua")
BOOTSTRAP = Path("reframework/autorun/BSFNStockBridge/bootstrap.lua")


def source_pair():
    manifest = json.loads((ROOT / "manifest.json").read_text("utf-8"))
    units = manifest["lua_units"]
    actual = sorted(path.name for path in (ROOT / "src/lua").glob("*.lua"))
    if len(set(units)) != len(units) or sorted(units) != actual:
        raise ValueError("Every Lua source unit must occur exactly once in manifest.json")
    header = "-- BoneSystemForNPC | Copyright (c) 2026 Laz | SPDX-License-Identifier: MIT\n"
    header += "-- Generated from src/lua in manifest order; edit the source units, not this file.\n\n"
    beta = header + "\n".join((ROOT / "src/lua" / name).read_text("utf-8") for name in units)
    bootstrap = (ROOT / "src/bridge/bootstrap.lua").read_text("utf-8")
    version = manifest["version"]
    if f'local VERSION = "{version}"' not in beta or f'version = "{version}"' not in bootstrap:
        raise ValueError("Version constants must match manifest.json")
    formal = {RUNTIME: strip_comments(beta), BOOTSTRAP: strip_comments(bootstrap)}
    commented = {RUNTIME: beta, BOOTSTRAP: bootstrap}
    for path in formal:
        assert executable_tokens(formal[path]) == executable_tokens(commented[path])
    return formal, commented


def assemble(check=False):
    formal, commented = source_pair()
    hashes = {}
    for relative, source in formal.items():
        destination = ROOT / relative
        data = source.encode("utf-8")
        if check:
            if not destination.is_file() or destination.read_bytes() != data:
                raise ValueError(f"Generated formal source is stale: {relative}")
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            beta_path = ROOT / "out/beta" / relative
            beta_path.parent.mkdir(parents=True, exist_ok=True)
            beta_path.write_bytes(commented[relative].encode("utf-8"))
        hashes[relative.as_posix()] = hashlib.sha256(data).hexdigest()
    return hashes


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check tracked generated files without writing")
    args = parser.parse_args()
    print(json.dumps(assemble(args.check), indent=2))
