#!/usr/bin/env python3
import hashlib
import html
import re
import sys
from pathlib import Path
from urllib.parse import quote

if len(sys.argv) != 4:
    raise SystemExit(
        "Usage: release-display.py STAGING_DIR GIT_URL RELEASE_TAG"
    )

staging = Path(sys.argv[1])
release_url = (
    f"{sys.argv[2].rstrip('/')}/releases/download/"
    f"{quote(sys.argv[3], safe='-._~')}"
)

CATEGORIES = (
    ("primary", "🏁 Primary Downloads", "Production Image"),
    ("verification", "🔐 Verification", "OpenPGP Key, Signature & Public Key"),
    ("checksums", "📋 Checksums", "SHA-512 Checksums"),
    ("torrents", "🧲 Torrents", "Torrent File"),
    ("buildinfo", "ℹ️ Build Information", "Build Metadata"),
)

# Test the longer suffixes first
PRIMARY_SUFFIXES = (
    ".qcow2.libvirt.xz",
    ".raw.libvirt.xz",
    ".iso",
    ".ova",
    ".vdi",
    ".vmdk",
    ".img",
    ".raw",
    ".xz",
)

ARCHITECTURES = ("Intel_AMD64", "ARM64", "amd64", "arm64")


def unsplit(name):
    """Return the original asset name for a GNU split part."""
    return re.sub(r"\.part_[^.]+$", "", name)


def is_primary(name):
    original_name = unsplit(name)

    if original_name.startswith("derivative-maker-source-"):
        return False

    return original_name.lower().endswith(
        tuple(suffix.lower() for suffix in PRIMARY_SUFFIXES)
    )


def product_label(name):
    """Infer the image's product label from its versioned filename."""
    if not is_primary(name):
        return None

    original_name = unsplit(name)
    suffix = next(
        suffix
        for suffix in PRIMARY_SUFFIXES
        if original_name.lower().endswith(suffix.lower())
    )
    stem = original_name[:-len(suffix)]

    architecture_pattern = "|".join(
        re.escape(architecture) for architecture in ARCHITECTURES
    )
    match = re.match(
        rf"^(?P<label>.+)-"
        rf"(?P<version>[0-9][A-Za-z0-9.+~_-]*)\."
        rf"(?P<architecture>{architecture_pattern})$",
        stem,
        flags=re.IGNORECASE,
    )
    if match:
        return match.group("label")

    return None


def category(name):
    original_name = unsplit(name).lower()

    if original_name.endswith((".asc", ".sig", ".pub")):
        return "verification"
    if original_name.endswith(".sha512sums"):
        return "checksums"
    if original_name.endswith(".torrent"):
        return "torrents"
    if original_name.endswith(".dm-buildinfo"):
        return "buildinfo"
    if is_primary(name):
        return "primary"
    return "buildinfo"


def size(path):
    value = path.stat().st_size
    for unit in ("B", "K", "M", "G", "T"):
        if value < 1024 or unit == "T":
            if unit == "B":
                return f"{value:.0f}{unit}"
            return f"{value:.1f}{unit}"
        value /= 1024


def digest(path, algorithm):
    result = hashlib.new(algorithm)
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def markdown_name(name):
    return name.replace("|", r"\|").replace("`", r"\`")


def link(path):
    label = markdown_name(path.name)
    url = f"{release_url}/{quote(path.name, safe='-._~')}"
    return f"[`{label}`]({url})"


def artifact_type(name):
    lowered_name = unsplit(name).lower()
    if ".qcow2.libvirt.xz" in lowered_name:
        return "⚡ KVM / QEMU image"
    if lowered_name.endswith(".iso"):
        return "💿 Live ISO"
    if lowered_name.endswith(".ova"):
        return "🧊 VirtualBox Appliance"
    return "📦 Download"


files = sorted(path for path in staging.iterdir() if path.is_file())

# Derive product headings from primary artifact filenames.
labels = sorted(
    {
        label
        for path in files
        if (label := product_label(path.name)) is not None
    },
    key=str.casefold,
)

files_by_label = {label: [] for label in labels}
support_files = []
unclassified_images = []

# Prefer the longest matching label
labels_by_length = sorted(labels, key=len, reverse=True)

for path in files:
    matched_label = next(
        (
            label
            for label in labels_by_length
            if path.name.casefold().startswith(label.casefold())
            and len(path.name) > len(label)
            and path.name[len(label)] in "-."
        ),
        None,
    )

    if matched_label is None:
        support_files.append(path)
        if is_primary(path.name):
            unclassified_images.append(path)
        continue

    files_by_label[matched_label].append(path)

print("### 📦 Downloads\n")

for label in labels:
    label_files = sorted(files_by_label[label])
    escaped_label = html.escape(label, quote=True)

    print(
        f"<details>\n"
        f"<summary>🗂️ {escaped_label}</summary>\n"
        f"<br>\n"
    )

    for category_key, title, heading in CATEGORIES:
        selected = [
            path for path in label_files
            if category(path.name) == category_key
        ]

        print(f"<details>\n<summary>{title}</summary>\n")

        if not selected:
            print("No files in this category.\n")
        elif category_key == "primary":
            print("| Artifact | Production Image | Size | SHA-256 |")
            print("|---|---|---:|---|")
            for path in selected:
                print(
                    f"| {artifact_type(path.name)} | {link(path)} "
                    f"| {size(path)} | `{digest(path, 'sha256')}` |"
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

print("<details>\n<summary>📄 Support Files</summary>\n")

if support_files:
    print("| Artifact | Size |")
    print("|---|---:|")
    for path in sorted(support_files):
        print(f"| {link(path)} | {size(path)} |")
    print()
else:
    print("No support files.\n")

if unclassified_images:
    print(
        "> **Warning:** The following primary image files did not match the "
        "expected version-and-architecture filename pattern:"
    )
    for path in sorted(unclassified_images):
        print(f"> - `{markdown_name(path.name)}`")
    print()

print("</details>\n")

# Include primary images and their signature files in the quick verification menu
important = {
    path.name
    for path in files
    if category(path.name) in ("primary", "verification")
}

print("### 🔢 Quick SHA-512 Checksums\n")
print("Verify downloads using the provided checksums and signatures.\n")
print("```text")
for name in sorted(important):
    print(f"{digest(staging / name, 'sha512')}  {name}")
print("```")
