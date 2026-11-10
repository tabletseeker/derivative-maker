#!/usr/bin/env python3
import hashlib
import re
import sys
from pathlib import Path
from urllib.parse import quote

staging = Path(sys.argv[1])
release_url = f"{sys.argv[2].rstrip('/')}/releases/download/{sys.argv[3]}"

CATEGORIES = (
    ("primary", "🏁 Primary Downloads", "Production Image"),
    ("verification", "🔐 Verification", "OpenPGP Key & Signature"),
    ("checksums", "📋 Checksums", "SHA-512 Checksums"),
    ("torrents", "🧲 Torrents", "Torrent File"),
    ("buildinfo", "ℹ️ Build Information", "Build Metadata"),
)
PRIMARY_SUFFIXES = (
    ".qcow2.libvirt.xz", ".iso", ".ova", ".xz",
    ".vdi", ".vmdk", ".img", ".raw",
)


def unsplit(name):
    return re.sub(r"\.part_[^.]+$", "", name)


def category(name):
    if name.endswith((".asc", ".sig")):
        return "verification"
    if name.endswith(".sha512sums"):
        return "checksums"
    if name.endswith(".torrent"):
        return "torrents"
    if name.endswith(".dm-buildinfo"):
        return "buildinfo"
    return "primary" if unsplit(name).endswith(PRIMARY_SUFFIXES) else "buildinfo"


def flavor_of(name):
    if name.startswith("derivative-maker-source-"):
        return None
    if not unsplit(name).endswith(PRIMARY_SUFFIXES):
        return None
    match = re.match(r"^([A-Za-z0-9_]+)-", name)
    return match.group(1) if match else None


def flavor_label(name):
    label = unsplit(name)
    label = re.sub(
        r"\.(?:qcow2\.libvirt\.xz|iso|ova|xz|vdi|vmdk|img|raw)$", "", label
    )
    label = re.sub(r"\.Intel_.*$", "", label)
    return re.sub(r"-nightly$", "", label)


def size(path):
    value = path.stat().st_size
    for unit in ("B", "K", "M", "G", "T"):
        if value < 1024 or unit == "T":
            return f"{value:.0f}{unit}" if unit == "B" else f"{value:.1f}{unit}"
        value /= 1024


def digest(path, algorithm):
    result = hashlib.new(algorithm)
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def link(path):
    name = path.name.replace("|", r"\|")
    url = f"{release_url}/{quote(path.name, safe='-._~')}"
    return f"[`{name}`]({url})"


def artifact_type(name):
    if ".qcow2.libvirt.xz" in name:
        return "⚡ KVM / QEMU image"
    if ".iso" in name:
        return "💿 Live ISO"
    if ".ova" in name:
        return "🧊 VirtualBox Appliance"
    return "📦 Download"


files = sorted(path for path in staging.iterdir() if path.is_file())

# Group files by flavor, discovering flavors from primary artifacts.
flavors = {}
for path in files:
    flavor = flavor_of(path.name)
    if flavor:
        flavors.setdefault(flavor, path.name)

print("### 📦 Downloads\n")

for flavor, example in flavors.items():
    print(f"<details>\n<summary>🗂️ {flavor_label(example)}</summary>\n<br>\n")
    flavor_files = [p for p in files if p.name.startswith(f"{flavor}-")]

    for key, title, heading in CATEGORIES:
        selected = [p for p in flavor_files if category(p.name) == key]
        print(f"<details>\n<summary>{title}</summary>\n")

        if not selected:
            print("No files in this category.\n")
        elif key == "primary":
            print("| Artifact | Production Image | Size | SHA-256 |")
            print("|---|---|---:|---|")
            for path in selected:
                print(
                    f"| {artifact_type(path.name)} | {link(path)} | {size(path)} "
                    f"| `{digest(path, 'sha256')}` |"
                )
            print()
        else:
            print(f"| {heading} | Size |")
            print("|---|---:|")
            for path in selected:
                print(f"| {link(path)} | {size(path)} |")
            print()

        print("</details>\n")

    print("</details>\n")

flavor_files = {
    path for path in files
    if any(path.name.startswith(f"{flavor}-") for flavor in flavors)
}
miscellaneous = [path for path in files if path not in flavor_files]

print("<details>\n<summary>📄 Support Files</summary>\n")
if miscellaneous:
    print("| Artifact | Size |")
    print("|---|---:|")
    for path in miscellaneous:
        print(f"| {link(path)} | {size(path)} |")
    print()
else:
    print("No support files.\n")
print("</details>\n")

# Summarize primary images, direct signatures, and flavor developer keys.
important = set()
for path in files:
    if flavor_of(path.name):
        important.add(path.name)
        important.update(
            sidecar
            for sidecar in (f"{path.name}.asc", f"{path.name}.sig")
            if (staging / sidecar).is_file()
        )

for flavor in flavors:
    important.update(
        path.name for path in files
        if path.name.lower().startswith(f"{flavor.lower()}-")
        and "developer" in path.name.lower()
        and path.name.endswith(".asc")
    )

print("### 🔢 Quick SHA-512 Checksums\n")
print("Verify all downloads using the provided checksums and signatures.\n")
print("```text")
for name in sorted(important):
    print(f"{digest(staging / name, 'sha512')}  {name}")
print("```")
