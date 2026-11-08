#!/usr/bin/env python3
import hashlib
import re
import sys
from pathlib import Path
from urllib.parse import quote

staging = Path(sys.argv[1])
release_url = f"{sys.argv[2].rstrip('/')}/releases/download/{sys.argv[3]}"

CATEGORIES = (
    ("primary", "🏁 Primary Downloads"),
    ("verification", "🔐 Verification"),
    ("checksums", "📋 Checksums"),
    ("torrents", "🧲 Torrents"),
    ("buildinfo", "🛠️ Build Information"),
)
PRIMARY_SUFFIXES = (
    ".qcow2.libvirt.xz", ".iso", ".ova", ".xz",
    ".vdi", ".vmdk", ".img", ".raw",
)


def category(name):
    if name.endswith((".asc", ".sig")):
        return "verification"
    if name.endswith(".sha512sums"):
        return "checksums"
    if name.endswith(".torrent"):
        return "torrents"
    if name.endswith(".dm-buildinfo"):
        return "buildinfo"
    base = re.sub(r"\.part_[^.]+$", "", name)
    return "primary" if base.endswith(PRIMARY_SUFFIXES) else "buildinfo"


def flavor_of_primary(name):
    if name.startswith("derivative-maker-source-"):
        return None
    base = re.sub(r"\.part_[^.]+$", "", name)
    if not base.endswith(PRIMARY_SUFFIXES):
        return None
    match = re.match(r"^([A-Za-z0-9_]+)-", name)
    return match.group(1) if match else None


def flavor_label(name):
    label = re.sub(r"\.part_[^.]+$", "", name)
    label = re.sub(
        r"\.(?:qcow2\.libvirt\.xz|iso|ova|xz|vdi|vmdk|img|raw)$", "", label
    )
    label = re.sub(r"\.Intel_.*$", "", label)
    return re.sub(r"-nightly$", "", label)


def url(name):
    return f"{release_url}/{quote(name, safe='-._~')}"


def size(path):
    value = path.stat().st_size
    for unit in ("B", "K", "M", "G", "T"):
        if value < 1024 or unit == "T":
            return f"{value:.0f}{unit}" if unit == "B" else f"{value:.1f}{unit}"
        value /= 1024


def sha(path, algorithm):
    digest = hashlib.new(algorithm)
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def link(path):
    name = path.name.replace("|", r"\|")
    return f"[`{name}`]({url(path.name)})"


def purpose(name):
    if name.endswith(".asc"):
        return "OpenPGP Signature/Key"
    if name.endswith(".sig"):
        return "Signify Signature"
    if name.endswith(".sha512sums"):
        return "SHA-512 Checksums"
    if name.endswith(".torrent"):
        return "Torrent File"
    if name.endswith(".dm-buildinfo"):
        return "Reproducible Metadata"
    if name.endswith(".log"):
        return "Build Log"
    return "Supporting File"


files = sorted(p for p in staging.iterdir() if p.is_file())
flavors = {}
for path in files:
    flavor = flavor_of_primary(path.name)
    if flavor:
        flavors.setdefault(flavor, path.name)

print("### 📦 Downloads\n")

for flavor, example in flavors.items():
    print(f"<details>\n<summary>🗂️ {flavor_label(example)}</summary>\n")

    flavor_files = [p for p in files if p.name.startswith(f"{flavor}-")]
    for key, title in CATEGORIES:
        selected = [p for p in flavor_files if category(p.name) == key]
        print(f"<details>\n<summary>{title}</summary>\n")

        if not selected:
            print("No files in this category.\n")
        elif key == "primary":
            print("| Artifact | File | Size | SHA-256 |")
            print("|---|---|---:|---|")
            for path in selected:
                name = path.name
                artifact = (
                    "💿 Live ISO" if ".iso" in name else
                    "⚡ KVM / QEMU Image" if ".qcow2.libvirt.xz" in name else
                    "🧊 VirtualBox Appliance" if ".ova" in name else
                    "📦 Download"
                )
                print(f"| **{artifact}** | {link(path)} | {size(path)} | "
                      f"`{sha(path, 'sha256')}` |")
            print()
        else:
            print("| File | Purpose | Size |")
            print("|---|---|---:|")
            for path in selected:
                print(f"| {link(path)} | {purpose(path.name)} | {size(path)} |")
            print()

        print("</details>\n")

    print("</details>\n")

flavor_files = {
    p for p in files
    if any(p.name.startswith(f"{flavor}-") for flavor in flavors)
}
misc = [p for p in files if p not in flavor_files]

print("<details>\n<summary>📄 Miscellaneous</summary>\n")
if misc:
    print("| File | Purpose | Size |")
    print("|---|---|---:|")
    for path in misc:
        print(f"| {link(path)} | {purpose(path.name)} | {size(path)} |")
    print()
else:
    print("No miscellaneous files.\n")
print("</details>\n")

# Hash primary images, their direct signatures, and flavor developer keys.
important = set()
for path in files:
    if flavor_of_primary(path.name):
        important.add(path.name)
        important.update(
            sidecar for sidecar in (f"{path.name}.asc", f"{path.name}.sig")
            if (staging / sidecar).is_file()
        )

for flavor in flavors:
    important.update(
        p.name for p in files
        if p.name.lower().startswith(f"{flavor.lower()}-")
        and "developer" in p.name.lower()
        and p.name.endswith(".asc")
    )

print("### 🔐 Quick SHA-512 Checksums\n")
print("Primary images, available direct signatures, and flavor developer keys:\n")
print("```text")
for name in sorted(important):
    print(f"{sha(staging / name, 'sha512')}  {name}")
print("```")
