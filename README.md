<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://github.com/tabletseeker/whonix-cloud/blob/master/media/dark_logo.png" width=74% height=58%>
    <source media="(prefers-color-scheme: light)" srcset="https://github.com/tabletseeker/whonix-cloud/blob/master/media/light_logo.png" width=74% height=58%>
    <img alt="Shows a black logo in light color mode and a white one in dark color mode.">
  </picture>
</p>

[![License](https://img.shields.io/badge/LICENSE-AGPL3+-2f3542?style=for-the-badge&logo=unlicense&logoColor=white)](https://github.com/tabletseeker/whonix-cloud/blob/master/LICENSE) [![Issues](https://img.shields.io/github/issues/tabletseeker/mobian?style=for-the-badge&color=26b861&logo=helpdesk&logoColor=white)](https://github.com/tabletseeker/whonix-cloud/issues) [![CI Status](https://img.shields.io/badge/CI-PASSED-26b861?style=for-the-badge&logo=bilibili&logoColor=white)](https://github.com/tabletseeker/whonix-cloud/actions) [![Discussions](https://img.shields.io/badge/DISCUSSIONS-ACTIVE-1e90ff?style=for-the-badge&logo=livechat&logoColor=white)](https://github.com/tabletseeker/whonix-cloud/discussions) [![Release](https://img.shields.io/badge/RELEASE-V18.2.4.2-ff4757?style=for-the-badge&logo=github&logoColor=white)](https://github.com/tabletseeker/whonix-cloud/releases)

A community project, maintained by Whonix contributors, that provides **100%** transparency and reproducibility of the entire **Kicksecure** and **Whonix** build process by delivering upstream identical, cryptographically signed production releases, using the official `derivative-maker` build scripts, while executing and publishing the complete pipeline via GitHub Actions CI, featuring detailed trace logs of every single executed command, live tracking of every individual stage and a 24h rotating nightly tag. To ensure maximum security and consistency, all CI build runners are encapsulated inside an accelerated QEMU guest, based on a pinned Debian Trixie Cloud image, which itself is assembled and verified during the build.
Every tag and release asset is publicly created, tracked, signed, verified and uploaded directly via Github CI & Releases, without the use or involvement of any external servers, tools or third parties.
<p align="center">
<img src="https://github.com/tabletseeker/whonix-cloud/blob/master/media/runner.webp" width=100% height=100%>
</p>

## Roadmap
- [ ] [Highlights](#highlights)
- [ ] [Images & Releases](#images--releases)
    - [ ] [GitHub Releases](#github-releases)
    - [ ] [Release Artifact Layout](#release-artifact-layout)
- [ ] [Modifications & Commits](#modifications-and-commits)
- [ ] [CI Architecture](#ci-architecture)
    - [ ] [4-Layer Execution Pipeline](#4-layer-execution-pipeline)
    - [ ] [Repository Layout](#repository-layout)
    - [ ] [Build Modes & Schedules](#build-modes--schedules)
    - [ ] [Matrix Asset System](#matrix-asset-system)
    - [ ] [Multi-Layer Caching](#multi-layer-caching)
- [ ] [Workflow Parameters & Secrets](#workflow-parameters--secrets)
    - [ ] [Matrix Dispatch Inputs](#matrix-dispatch-inputs)
    - [ ] [Secrets & Variables](#secrets--variables)
- [ ] [Cryptographic Verification & Publishing](#cryptographic-verification--publishing)
    - [ ] [Signing & Policy Enforcement](#signing--policy-enforcement)
    - [ ] [Atomic Release & Rollback](#atomic-release--rollback)
- [ ] [Local Building & Operations](#local-building--operations)
    - [ ] [Building Locally](#building-locally)
    - [ ] [Operational Runbook](#operational-runbook)
- [ ] [Credits](#credits-)
- [ ] [Donations](#donations-)
- [ ] [Community](#community-)


## Highlights
- [x] Features

* **100% Reproducibility:** Users have full access to and knowledge of the entire build process.
* **No 3rd Party Involvement:** All vanilla build assets, i.e. scripts, workflows, keys etc. are directly accessible and traceable.
* **Minimal Footprint:** Changes are exclusively made to the CI implementation. Official Whonix/Kicksecure related code remains completely unmodified.
* **End-to-End Supply Chain Security:** Enforces upstream identical Sequoia commit and tag signature policies.
* **Three Dedicated CI Modes (`release`, `nightly`, `cache`):**
  * **Production Releases:** Auto-incremented with new point releases, featuring full OpenPGP/Signify signatures and SHA-256/SHA-512 manifests.
  * **Daily Nightlies (`06:00 UTC`):** Rolling 24h `nightly` builds with in-place asset replacement and automatic tag rollback on failure.
  * **Weekly Cache Warmups (`Monday 00:05 UTC`):** Pre-warms weekly `approx` APT caches, Debian Trixie Base QUEMU image and Podman/Buildah OCI container image across all Whonix/Kicksecure flavors.
* **Nested KVM Isolation:** Using a pinned Debian Trixie cloud image inside KVM on standard GitHub Actions runners that executes `derivative-maker`.
* **Full system integration:** All available configuration options of `derivative-maker` are leveraged to create production (`dm-build-official`) or custom releases.
* **Containerization with Podman:**  Featuring the fully open-source, engine-agnostic `derivative-maker-oci`. An upgrade to my originally contributed `derivative-maker-docker` solution still used upstream.
* **Dynamic JSON Matrix Expansion:** Modular asset definitions expand individual flavors or bundle presets into parallel matrix workers.
* **Clean Artifacts Display:** A neatly organized, collapsed artifact view is automatically generated with every release.
* **Code Sophistication:** The full pipeline is written solidly using best practices and prescribed SoD/SoC workflow logic.

[🔼 Back to Top](#roadmap)

## Images & Releases
- [x] Installation

### GitHub Releases

Ready-to-use images are published automatically to the https://github.com/tabletseeker/whonix-cloud/releases page across two channels:

1. **Production Releases (`<version>-release`)**
   * Built against frozen Debian snapshot timestamps (`freshness: frozen`, `dist_build_redistributable: true`).
   * Includes **Kicksecure** (`CLI` & `LXQt`) and **Whonix** (`Gateway` & `Workstation`, `CLI` & `LXQt`) for **KVM** (`.qcow2.libvirt.xz`) and **VirtualBox** (`.ova`), alongside source archives, `.torrent` files, `.dm-buildinfo` metadata, OpenPGP (`.asc`) & Signify (`.sig`) signatures, and `SHA-512` checksums.

2. **Nightly Pre-Releases (`nightly`)**
   * Built daily at `06:00 UTC` against live Debian Trixie repositories (`freshness: current`) so upstream updates and new commits can be tested immediately.

### Release Artifact Layout

   Every release contains three components.

  1. Manifest table, which chronicles the selected options.

  <img src="https://github.com/tabletseeker/whonix-cloud/blob/master/media/manifest.png" width=50% height=50%>

  2. Collapsed and flavor sorted assets display.
    
  <img src="https://github.com/tabletseeker/whonix-cloud/blob/master/media/downloads.png" width=80% height=80%>

  3.  Full assets list that combines all artifacts.

  <img src="https://github.com/tabletseeker/whonix-cloud/blob/master/media/assets.png" width=70% height=70%>


#### Verifying & Extracting Downloads

1. Download the image archive, `.sha512sums`, and signature files (`.asc` / `.sig`) from the release page. If a large image was split into chunks (`*.part_aa`, `*.part_ab`, ...), reassemble it first:
   ```sh
   cat Kicksecure-LXQt-<version>.Intel_AMD64.qcow2.libvirt.xz.part_* > Kicksecure-LXQt-<version>.Intel_AMD64.qcow2.libvirt.xz
   ```
2. Verify the cryptographic checksums and signatures:
   ```sh
   sha512sum --ignore-missing -c *.sha512sums
   sq verify --signer-file derivative-maker-openpgp.asc --detached Kicksecure-LXQt-<version>.Intel_AMD64.qcow2.libvirt.xz.asc Kicksecure-LXQt-<version>.Intel_AMD64.qcow2.libvirt.xz
   ```
3. Decompress the `.xz` archive:
   ```sh
   unxz -kv Kicksecure-LXQt-<version>.Intel_AMD64.qcow2.libvirt.xz
   ```

## Modifications and Commits
- [x] What has been added

The ultimate goal of this project is to transform Whonix Development and Release Cycles into a publicly interactive experience, allowing community members to jointly decide the direction of development, while enabling the general public to build, inspect, customize, and cryptographically sign their own images through automated CI workflows.

At the time of writing this repo strictly acts as an upstream tracker/wrapper that publicly builds, verifies and releases vanilla Whonix/Kicksecure tags.
Thus, no changes have been and will be made to any core infrastructure, packages or other files of any official nature, until there has been an official announcement.

Removed files:
```
- .github/*
```
Reason: Upstream CI only runs isolated validation checks and dry run steps that a full build pipeline inherently performs while producing actual release artifacts.

Added files:
```
  - oci/*
  - help-steps/ci-signing-setup
  - .github/*
  - .github/actions/*
  - .github/scripts/*
  - .github/workflows/*
  - media/*
  - README.md
```
Reason: 
* Upgrade deprecated and semi-closed source `derivative-maker-docker`
  * This docker implementation for derivative-maker was originally based on a contributed hobby project of mine, called [whonix-builder](https://github.com/tabletseeker/whonix_builder).
  * The new `derivative-maker-oci` improves systemd initialization, modernizes/simplifies the codebase using buildah and enables the use of multiple (open) engines, i.e. podman, nerdctl, buildah, colima etc.
* Enable signing setup and buildconfig.d optimization
* Implement Whonix-Cloud CI Workflows and Scripts 

Modified derivative-maker files:

* build-steps.d/5200_prepare-release - Commit [e2f92e0](https://github.com/tabletseeker/whonix-cloud/commit/e2f92e0c4bcb7c16809a4283fd55635c7ae62642)

  Reason:
  Bug fix - Upstream's version fails to export the signing key.

  Pull Request: Active

  PR URL: https://github.com/adrelanos/derivative-maker/pull/5

My (@tabletseeker) upstream commits:
https://github.com/adrelanos/derivative-maker/commits?author=tabletseeker&before=077c50645bebdb4d871abdb91a55a6f2f8a63701+35

All current upstream contributors:
https://github.com/adrelanos/derivative-maker/graphs/contributors?all=1


[🔼 Back to Top](#roadmap)

## CI Architecture
- [x] How It Works

### 4-Layer Execution Pipeline

Building Debian derivative images requires privileged loop devices (`losetup`, `kpartx`), chroot mounting (`mmdebstrap`, `cowbuilder`), and `systemd-nspawn` execution—operations that fail or conflict on standard containerized CI runners. To achieve full host isolation and deterministic caching, the pipeline nests four distinct execution layers:

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ Layer 1: GitHub Actions Control Plane (.github/workflows/matrix.yaml)        │
│  ├── resolve-config       (Maps manual inputs / cron schedules -> env vars)  │
│  ├── select-matrix-assets (Validates JSON presets -> parallel build matrix)  │
│  ├── resolve-version      (Queries release tags -> semantic version & tag)   │
│  ├── dm-matrix            (Fans out parallel container.yaml worker jobs)     │
│  └── publish              (Deduplicates assets, signs tag, publishes release)│
└──────────────────────────────────────┬───────────────────────────────────────┘
                                       │ workflow_call (per matrix asset)
                                       ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ Layer 2: Ubuntu Runner Host (.github/workflows/container.yaml)               │
│  ├── setup-host.sh         (Optional runner cleanup, KVM udev, QEMU install) │
│  ├── prepare-debian-base   (Restores or builds pinned 75G Debian QCOW2)      │
│  ├── actions/cache         (Restores weekly OCI image & approx repo archive) │
│  └── vm-setup.sh           (Creates CoW overlay, boots KVM guest, SSH bridge)│
└──────────────────────────────────────┬───────────────────────────────────────┘
                                       │ SSH (127.0.0.1:2222) + tar/zstd streams
                                       ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ Layer 3: Ephemeral KVM Guest VM (Debian Trixie, 4 vCPU, 8 GiB RAM)           │
│  ├── vm-provision.sh       (Installs podman, buildah, sq, qemu-utils)        │
│  ├── vm-sync-helper.sh     (Restores /home/debian/approx_cache_mnt & OCI)    │
│  └── vm-build.sh           (Clones repo at GITHUB_SHA, launches OCI runner)  │
└──────────────────────────────────────┬───────────────────────────────────────┘
                                       │ Buildah / Podman OCI Container
                                       ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ Layer 4: Derivative-Maker OCI Container (oci/derivative-maker-oci-run)       │
│  ├── ci-signing-setup      (Imports GPG/sq keys, signify key, sq-git check)  │
│  └── dm-build-official     (cowbuilder, grml-debootstrap, approx :9977)      │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Repository Layout

```text
.github/
├── actions/
│   ├── prepare-debian-base/       # Composite action: builds/caches pinned Debian Trixie QCOW2
│   └── update-approx-cache/       # Composite action: threshold-gated approx cache saver & pruner
├── scripts/
│   ├── matrix-assets/             # JSON definitions for individual & bundle build targets
│   ├── build-debian-base.sh       # Fetches pinned salsa.debian.org cloud-images & builds the QEMU base image
│   ├── verify-debian-base.sh      # Validates the base image's buildinfo provenance, SHA-512 digest, & QCOW2 invariants
│   ├── resolve-config.sh          # Resolves workflow_dispatch inputs vs. cron schedule presets
│   ├── generate-matrix.sh         # Validates JSON schemas & expands matrix-assets into job matrix
│   ├── resolve-version.sh         # Queries git release tags to compute version & tag names
│   ├── setup-host.sh              # Configures /dev/kvm permissions & installs QEMU/cloud-init tools
│   ├── vm-setup.sh                # Boots KVM guest, restores caches, executes vm-build.sh via SSH
│   ├── vm-provision.sh            # Provisions Buildah, Podman, Sequoia, & subuid/subgid inside guest
│   ├── vm-build.sh                # Initializes guest workspace, clones repo, runs OCI build
│   ├── vm-sync-helper.sh          # Host<->Guest SSH/tar/zstd transport for caches, artifacts, & poweroff
│   ├── gather-artifacts.sh        # Pulls built images/checksums/sigs, splits >2GB files, writes notes
│   ├── publish-release.sh         # Deduplicates matrix outputs, signs Git tags, updates GitHub Release
│   └── render-notes.py            # Generates categorized Markdown download tables & SHA-512 block
└── workflows/
    ├── matrix.yaml                # Top-level orchestrator (workflow_dispatch + cron schedules)
    └── container.yaml             # Reusable single-asset worker workflow
help-steps/
└── ci-signing-setup               # In-container GPG/Sequoia/Signify setup & sq-git verification
```

### Build Modes & Schedules

`Whonix Cloud Matrix` (`matrix.yaml`) enforces concurrency groups keyed by `<version_prefix>-<build_mode>` (`cancel-in-progress: false`) so production releases, daily nightlies, and weekly cache warmups never block or overwrite one another:

| Mode | Trigger | `freshness` | `allow_unfrozen` | `redistributable` | Tag & Publication |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`release`** | Manual `workflow_dispatch` (default) | `frozen` | `false` | `true` | Increments release tag & generates signed Release |
| **`nightly`** | Cron `0 6 * * *` (Daily 06:00 UTC) or manual | `current` | `true` | `false` | Force-updates signed rolling`nightly` tag |
| **`cache`** | Cron `5 0 * * 1` (Monday 00:05 UTC) or manual | `current` | `true` | `false` | Populates `approx`, OCI & base image caches |

#### How `cache` Mode Eliminates Redundant Work
* **Weekly Pre-Warming:** Because `approx` and unfrozen OCI cache keys rotate every ISO week (`%G-W%V`), the Monday `00:05 UTC` cron job warms both caches before the daily `06:00 UTC` multi-job `nightly` matrix launches—preventing parallel runners from downloading duplicate packages on a cold cache.
* **Native `SKIP_SCRIPTS` Optimization (`ci-signing-setup`):** When `BUILD_MODE == "cache"`, `ci-signing-setup` appends `dist_build_max_jobs="$(nproc)"`, `dist_build_reuse_cowbuilder_base="true"`, `XZ_OPT="-T0 -1"`, and `SKIP_SCRIPTS` (`1600`, `1700`, `4310`–`5200`, `dm-prepare-release`, `dm-upload-images`) into `~/buildconfig.d/30_ci-override.conf`.
* **Complete Package Coverage:** Steps `1100` through `4300` execute across all six flavors in `cache-amd64` so every host tool, `cowbuilder` chroot dependency, `grml-debootstrap` base package, and flavor metapackage is stored in `approx`, while `5300_free-build-scratch` deletes each flavor's working `.raw` image immediately after completion.
* **Rolling Approx Cache:** Within a weekly cycle the approx cache file is continuously restored and saved if it has grown by more than 20MB during a run (excluding Matrix jobs).

[🔼 Back to Top](#roadmap)

### Matrix Asset System

Build targets are defined as modular JSON files under `.github/scripts/matrix-assets/` and validated by `generate-matrix.sh`. Each asset filename must match its `.id` field (`<id>.json`):

```json
{
  "id": "kicksecure-lxqt-amd64-vm",
  "release_flavor": "Kicksecure-LXQt",
  "flavors_list": "kicksecure-lxqt",
  "arch": "amd64",
  "target": "virtualbox qcow2",
  "type": "vm",
  "container_engine": "podman",
  "flavor_meta_packages_to_install": "",
  "install_package_list": "",
  "derivative_apt_repository_opts": ""
}
```

#### Available AMD64 Asset Presets

| Asset ID | Flavors Built (`flavors_list`) | Target(s) | Purpose |
| :--- | :--- | :--- | :--- |
| `kicksecure-lxqt-amd64-vm` | `kicksecure-lxqt` | `virtualbox qcow2` | Kicksecure LXQt desktop VM (KVM + VirtualBox) |
| `kicksecure-cli-amd64-vm` | `kicksecure-cli` | `qcow2` | Kicksecure headless CLI VM (KVM) |
| `whonix-gateway-lxqt-amd64-vm` | `whonix-gateway-lxqt` | `virtualbox qcow2` | Standalone Whonix-Gateway LXQt VM |
| `whonix-gateway-cli-amd64-vm` | `whonix-gateway-cli` | `virtualbox qcow2` | Standalone Whonix-Gateway CLI VM |
| `whonix-lxqt-amd64-vm` | `whonix-gateway-lxqt whonix-workstation-lxqt` | `qcow2` | Paired Whonix Gateway + Workstation LXQt (KVM) |
| `cli-vm-amd64` | `kicksecure-cli whonix-gateway-cli whonix-workstation-cli` | `qcow2` | Combined CLI bundle across Kicksecure & Whonix |
| `lxqt-vm-amd64` | `kicksecure-lxqt whonix-gateway-lxqt whonix-workstation-lxqt` | `qcow2` | Combined LXQt bundle across Kicksecure & Whonix |
| `cache-amd64` | All 6 CLI + LXQt flavors | `qcow2` | Single-runner weekly `approx` + OCI cache primer |

* **Individual vs. `all` Selection:** Pass space-separated IDs (e.g., `cli-vm-amd64 kicksecure-lxqt-amd64-vm whonix-lxqt-amd64-vm`) or `all` (which expands all standalone assets while automatically skipping composite/bundle assets matching `kind == "bundle"`, `*all-*`, or `*bundle*`).

### Multi-Layer Caching

Three cache layers persist state across ephemeral GitHub Actions runners without external storage infrastructure.

<img src="https://github.com/tabletseeker/whonix-cloud/blob/master/media/cache.png" width=80% height=80%>

1. **Pinned Debian Trixie Base Image (`prepare-debian-base`):**
   * `build-debian-base.sh` clones a pinned 40-character commit SHA from `salsa.debian.org/cloud-team/debian-cloud-images.git`, builds `image_trixie_generic_amd64`, converts it to QCOW2, resizes it to `75G`, and writes a `.buildinfo` provenance file (`CLOUD_IMAGES_REF`, `DISK_SIZE`, `SHA512`).
   * `verify-debian-base.sh` validates the SHA-512 checksum, virtual disk byte size, standalone backing-file invariant, and `qemu-img check` integrity before `vm-setup.sh` creates an ephemeral Copy-on-Write overlay (`build-work.qcow2`).
   * Whenever any of the hashed base files, weekly ISO identifier or the git ref changes, the base image is automatically rebuilt.

    Example Cache:
    ```
    # current ISO Week: week="$(date -u +%G-W%V)"
    # current ref: cc29a4adc3366b4739b388dc862fd17bad6c2835 -> https://salsa.debian.org/cloud-team/debian-cloud-images.git
    # concatenated sha256sum of `.github/scripts/build-debian-vm-base.sh`, `.github/scripts/setup-host.sh`, `.github/scripts/verify-debian-vm-base.sh`

    debian-trixie-base-cc29a4adc3366b4739b388dc862fd17bad6c2835-1f9f89a2c4d1e787e1475274fba98866b16706578f1c66642e8f73b0b29e8c99
    ```
2. **Buildah OCI Container Image (`oci-image.tar.zst`):**
   * `oci/derivative-maker-oci-run` forms the basis for every run, assembles the base container image via buildah and exports it to the chosen build engine. In this case podman is used to launch the build container. Depending on whether frozen (official) or unfrozen (nightly) sources are used, two separate caches will be generated. Whenever the hashed oci files or weekly ISO identifier change, the container image is automatically rebuilt. 

    Example Cache:
    ```
    # frozen/unfrozen + architecture
    # current ISO Week: week="$(date -u +%G-W%V)"
    # concatonated sha256sum of `oci/*`, `build_sources/frozen-snapshot-timestamp`, `build_sources/debian_stable_frozen_direct_clearnet.sources.in`

    oci-trixie-unfrozen-amd64-2026-W48-3e67d4075ff72c750eb2fdebbb22308dba9e0d3bbeb5194bfb55220597da8127
    ```

4. **Approx APT Cache (`approx-cache.tar.zst`):**
   * The largest of all weekly caches, generated cumulatively across multiple builds or cache runs. The approx cache is always restored, but only saved if it has grown by a reasonable amount.      It can be specific to certain flavors or runners using specialized package lists.
   
    Example Cache:
    ```
    # current ISO Week: week="$(date -u +%G-W%V)"
    # architecture
    # runner id
    # matrix asset id

    approx-trixie-2026-W48-amd64-45440250191-all-amd64-kvm
    ```
## Workflow Parameters & Secrets
- [x] Configuration

### Matrix Dispatch Inputs

Trigger **Actions -> Whonix Cloud Matrix -> Run workflow** with any combination of the following inputs:

| Input | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `build_mode` | `choice` | `release` | Execution mode: `release`, `nightly`, or `cache` |
| `matrix_assets` | `string` | `all-amd64-kvm` | Space-separated asset IDs from `.github/scripts/matrix-assets/` or `all` |
| `version_prefix` | `string` | `""` (`vars.DEFAULT_VERSION_PREFIX`) | Semantic version family prefix (e.g., `18.0.0`) |
| `release_name` | `string` | `Production Release:` | Title prefix applied to created GitHub Releases |
| `freshness` | `choice` | `frozen` | APT sources mode: `frozen` (`snapshot.debian.org`) or `current` (live mirrors) |
| `allow_untagged` | `boolean` | `false` | Permits building from commits without an existing release tag |
| `allow_uncommitted` | `boolean` | `false` | Permits dirty git worktrees during local/CI testing |
| `allow_unfrozen` | `boolean` | `false` | Allows `current` APT sources and selects weekly unfrozen OCI cache keys |
| `remote_derivative_packages` | `boolean` | `false` | Uses remote derivative `.deb` repositories instead of building all locally |
| `dist_build_redistributable` | `boolean` | `true` | Enforces official redistributable build settings and Tor Browser fail-closed checks |
| `cleanup` | `boolean` | `false` | Purges unused host runner toolchains (`/usr/share/dotnet`, Android SDK, CodeQL, Docker) |
| `debfullname` | `string` | `tabletseeker-ci` | Maintainer/CI identity used for `dch`, OpenPGP lookup, and Git tag commits |
| `debemail` | `string` | `tabletseeker-ci@github.com` | Email identity matched against `CI_PRIVATE_KEY` in GnuPG and Sequoia |

### Secrets & Variables

| Name | Kind | Required | Purpose |
| :--- | :--- | :--- | :--- |
| `CI_PRIVATE_KEY` | Repository Secret | Yes | ASCII-armored OpenPGP private key imported by `ci-signing-setup` and `publish-release.sh` |
| `GITHUB_TOKEN` | Automatic Token | Yes | Authorizes submodule clones, Actions cache saves/pruning, tag pushes, and Releases |
| `DEFAULT_VERSION_PREFIX` | Repository Variable | Yes | Fallback version family (e.g., `18.0.0`) when `version_prefix` dispatch input is left empty |

[🔼 Back to Top](#roadmap)

## Cryptographic Verification & Publishing
- [x] Security & Releases

### Signing & Policy Enforcement

Inside every build container, `help-steps/ci-signing-setup` enforces supply-chain integrity before `dm-build-official` starts:

1. **Worktree Verification:** Refuses to proceed if `git diff` detects uncommitted changes unless `ALLOW_UNCOMMITTED=true`. (pre `git-sanity-test`)
2. **Dual GnuPG & Sequoia Keyring Import:** Imports `CI_PRIVATE_KEY` into both GnuPG (`gpg --batch --import`) and Sequoia (`sq key import` / `sq cert import`), resolves the secret key fingerprint matching `DEBEMAIL`, and binds the certificate to `DEBEMAIL` and `GIT_GITHUB_EMAIL` via `sq pki link add`.
3. **`signify-openbsd` Keys:** Generates `/home/user/.signify/keyname.{pub,sec}` (`chmod 600`) inside the container so `5200_prepare-release` signs every image with `.sig` alongside OpenPGP `.asc`.
4. **In-Container Tagging & `sq-git` Audit:** Signs `RELEASE_TAG` onto `HEAD`, verifies it with `git tag -v`, runs `./help-steps/signing-key-test`, and executes `./help-steps/git_sanity_test --mode all --context "main repo"` against `buildconfig.d/openpgp-policy.toml`.

### Atomic Release & Rollback

When `build_mode` is `release` or `nightly`, the `publish` job merges all matrix outputs and publishes atomically:

1. **Chunk Splitting (`gather-artifacts.sh`):** Any staged file exceeding `2000 MB` is automatically split into `1500M` segments (`*.part_aa`, `*.part_ab`, ...) so uploads never fail GitHub's 2 GiB per-asset limit.
2. **Keyring Filtering & Byte-Level Deduplication:** Strips internal build-support keyrings (`derivative.asc`, `kicksecure-developer-patrick.asc`, `mullvad-keyring.asc`, `oracle_vbox_2016.asc`, `tbb-team.asc`, `torprojectarchive.asc`, and `<40-hex-sha>.asc`) and deduplicates shared assets across workers via `cmp -s` (aborting immediately if two workers produce conflicting files with the same name).
3. **GNUPGHOME & Rollback Protection:** Imports `CI_PRIVATE_KEY` into a temporary `chmod 700` `GNUPGHOME` directory, backs up any existing `nightly` tag to `refs/rollback/nightly-<run_id>`, signs and verifies the tag, creates/updates the GitHub Release, and automatically rolls back tags or draft releases if any upload step fails.
4. **Categorized Release Notes (`render-notes.py`):** Generates collapsible `<details>` download cards per product (⚡ KVM, 💿 ISO, 🧊 VBX) with live-computed `SHA-256` hashes, signature/checksum/torrent tables, and a unified `SHA-512` verification block.

[🔼 Back to Top](#roadmap)

## Local Building & Operations
- [x] Runbook

### Building Locally

1. **Host Dependencies (Debian Trixie):**
   ```sh
   sudo apt-get update && sudo apt-get install -y \
     git qemu-system-x86 qemu-utils cloud-image-utils \
     podman buildah uidmap sq sequoia-git signify-openbsd
   ```
2. **Clone Repository & Submodules:**
   ```sh
   git clone --recurse-submodules https://github.com/tabletseeker/whonix-cloud
   cd whonix-cloud
   ```
3. **Launch OCI Build:**
   ```sh
   ./oci/derivative-maker-oci-run -- ./derivative-maker <args>
   ```
See [🔼 Derivative-Maker-OCI](https://github.com/tabletseeker/whonix-cloud/blob/master/oci/README.md) to view the full documentation.
### Operational Runbook

#### Adding a New Matrix Asset
1. Create `.github/scripts/matrix-assets/<asset-id>.json` matching the schema in [Matrix Asset System](#matrix-asset-system) (`id` must equal `<asset-id>`).
2. If defining a multi-asset bundle or cache primer that should be skipped during `MATRIX_ASSETS=all` expansion, set `"kind": "bundle"` or include `all-` / `bundle` in `id`.
3. Validate locally before committing:
   ```sh
   MATRIX_ASSETS="<asset-id>" GITHUB_OUTPUT=/dev/stdout ./.github/scripts/generate-matrix.sh
   ```

#### Refreshing Caches & Pinned Base Images
* **Manual Cache Warmup:** Run **Whonix Cloud Matrix** with `build_mode: cache`, `matrix_assets: cache-amd64`, `freshness: current`, and `allow_unfrozen: true`.
* **Force Cache Reset:** Delete `approx-trixie-*`, `oci-trixie-*`, or `debian-trixie-base-*` under **Actions -> Caches** (or via `gh cache delete`) to trigger a clean rebuild on the next run.
* **Bump Pinned Debian Cloud Base Image:** Resolve the latest commit SHA via `./.github/scripts/build-debian-base.sh --resolve` and update `CLOUD_IMAGES_REF` in `.github/actions/prepare-debian-base/action.yml`.

## Credits 🥇

**Huge** thanks to **Patrick** aka @adrelanos and his awesome team for `derivative-maker` and their pioneering work on security-hardened Debian derivatives, as well as the **Debian Cloud Team** for `debian-cloud-images`! 

🎉 HulaHoopWhonix, Mycobee, velnias75, GavinPacini, Algernon-01, JasonJAyalaP, onions-knight, coquizen. Karim13014, HulaHoop0, unman, alisa-rend, JeremyRand 🎉

* Upstream: https://github.com/adrelanos/derivative-maker
* Kicksecure Project: https://kicksecure.com
* Whonix Project: https://whonix.org

## Coffee Break ☕

This CI infrastructure and fork will be maintained for the foreseeable future. Any support is appreciated.

Bitcoin Address: `bc1qxaf820c6zynvlqv62xkyucd654e8j2xqxc4nmw`

 <img src=https://i.postimg.cc/BbxdX478/Screenshot-2026-06-22-11-58-33.png width=10% height=10%>

## Community 🤝

For questions, feature requests, build logs, or general discussion, head over to the Discussions section:

https://github.com/tabletseeker/whonix-cloud/discussions

[🔼 Back to Top](#roadmap)
