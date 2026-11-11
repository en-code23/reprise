#!/usr/bin/env python3
"""Bundle dependency notices without exposing Cargo's local source paths."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
destination = Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
metadata = json.loads(subprocess.check_output([
    os.environ.get("CARGO", "cargo"), "metadata", "--locked", "--format-version", "1",
    "--manifest-path", str(root / "runner/Cargo.toml")
]))
notices = ["Reprise managed-session dependencies", "", "Package | Version | License", "--- | --- | ---"]
for package in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"])):
    if package["name"] == "reprise-agent":
        continue
    notices.append(f'{package["name"]} | {package["version"]} | {package.get("license") or "See included notice"}')
    source = Path(package["manifest_path"]).parent
    candidates = [p for p in source.iterdir() if p.is_file() and p.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE", "COPYRIGHT"))]
    if package.get("license_file"):
        candidates.append(source / package["license_file"])
    for folder in (source / "LICENSES", source / "licenses"):
        if folder.is_dir():
            candidates.extend(p for p in folder.rglob("*") if p.is_file())
    for index, file in enumerate(dict.fromkeys(candidates)):
        if file.is_file():
            folder = destination / f'{package["name"]}-{package["version"]}'
            folder.mkdir(exist_ok=True)
            shutil.copyfile(file, folder / f"{index}-{file.name}")
(destination / "ThirdPartyNotices.md").write_text("\n".join(notices) + "\n", encoding="utf-8")
print(f"Bundled notices for {len(metadata['packages']) - 1} Rust dependencies.")
