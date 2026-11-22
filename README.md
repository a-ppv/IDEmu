# IDEmu: a BMW iDrive head-unit emulator for macOS and Windows

IDEmu runs the **original head-unit software** of BMW iDrive systems (HMI, window system and services) inside QEMU virtual machines, with its own
web interface, a virtual iDrive controller, virtual CAN bus and GPS, and a coding editor. It is a research and learning tool: you bring your own
firmware packages, IDEmu builds the disk images locally.

> Português: [README.pt-BR.md](README.pt-BR.md) · License: [PolyForm Noncommercial 1.0.0](LICENSE) · See [NOTICE](NOTICE) for what is **not** in this repo.

## Download

<p>
  <a href="https://github.com/herrbimmer/IDEmu/releases/latest/download/IDEmu-macos-arm64.zip"><img alt="Download for macOS (Apple Silicon)" src="https://img.shields.io/badge/Download-macOS%20(Apple%20Silicon)-000000?style=for-the-badge&logo=apple&logoColor=white"></a>
  <a href="https://github.com/herrbimmer/IDEmu/releases/latest/download/IDEmu-windows-x64.zip"><img alt="Download for Windows (x64)" src="https://img.shields.io/badge/Download-Windows%2010%2F11%20(x64)-0078D4?style=for-the-badge&logo=windows&logoColor=white"></a>
</p>

All releases: [Releases](https://github.com/herrbimmer/IDEmu/releases). The packages hold the program and the QEMU/renderer binaries only. **No BMW firmware, images or data are included**: you bring your own packages (see [NOTICE](NOTICE)).

* **Windows:** unzip, double-click `IDEmu.bat` (Python is bundled; you need a GPU driver with OpenGL, see [docs/WINDOWS.md](docs/WINDOWS.md)).
* **macOS (Apple Silicon):** unzip, then once: `brew install glib pixman gnutls libpng libslirp zstd` and `xattr -dr com.apple.quarantine .`, then run `./IDEmu.command` (or `python3 -m idemu gui`).

### Suggested minimum system requirements

These are suggestions taken from how the emulator is built and from the Windows tests in [docs/WINDOWS.md](docs/WINDOWS.md), not a formal benchmark.

| | macOS | Windows |
|---|---|---|
| **OS** | macOS 14 or later | Windows 10 (1803+) or 11, 64-bit |
| **CPU** | Apple Silicon: M1 minimum, M2 Pro / M3 or newer recommended (Intel Macs are not supported by the packaged build) | 64-bit x86, 4+ cores: minimum Intel Core i5-8400 or AMD Ryzen 5 2600; recommended Core i7-12700 / Ryzen 7 5800X or better (the VMs run in software emulation, single-core speed matters) |
| **RAM** | 8 GB for iDrive 5/6 and CIC; 16 GB for iDrive 7 and 8 | 8 GB for iDrive 5/6 and CIC; 16 GB plus a large page file for iDrive 7; **32 GB recommended for iDrive 8** (it commits 12 GiB) |
| **Disk (free)** | 20 GB (images and environments are built from your own firmware) | 20 GB, on an SSD; exclude the IDEmu folder from Defender for iDrive 7 |
| **GPU** | The built-in Apple GPU (Metal) is enough; nothing to install | Minimum NVIDIA GTX 1050 Ti or AMD RX 570 (OpenGL 4.1 core driver required for iDrive 7); recommended GTX 1660 / RX 6600 or newer. Integrated Intel UHD 630 works for iDrive 5/6 and CIC only. iDrive 8 also needs Edge or Chrome for ANGLE. VMs and Remote Desktop have no OpenGL |
| **Other** | Python 3 and the Homebrew libraries listed above | Nothing else: Python is bundled in the zip |
| **Speed** | iDrive 8 runs near native speed (HVF) | iDrive 8 runs in TCG: minutes to boot and a slow interface; iDrive 5/6 boots in ~25-45 s |

You always need your own BMW firmware packages (PSdZData); none are included.

## Supported systems

| System | Hardware / OS emulated | Level* | What works | What does not (yet) |
|---|---|---|---|---|
| **iDrive 6** (NBT Evo, 2016–2020) | OMAP5 board, QNX 6.5, ARM | **75% High** | Real HMI, touch, rotor and buttons, virtual CAN and GPS, cluster and HUD, connected phone, SSH, coding editor (1,333 parameters), V850 emulation, fast boot (~1 s) | Radio/media/audio, USB stick, some vehicle menu items |
| **iDrive 5** (NBT / NBT Evo) | Same as iDrive 6 (same packages, `HMI_ID_VERSION=id5`) | **54% Medium** | Real HMI, touch, rotor, CAN, cluster and HUD, SSH, phone, coding editor | Maps, media, USB; the HMI crashes now and then in navigation menus; slow reaction to input |
| **iDrive 8** (MGU22, BMW i7 G70) | Qualcomm SA8155 class, Linux 5.15, ARM64 (QEMU `virt` + HVF) | **58% Medium** | Real HMI at 2880×960, touch, rotor and buttons, phone screens, clock and temperature, coding editor (1,264 parameters), SSH (root shell), virtual cluster/HUD (simulated CAN/GPS, not fed by the HMI), boot in ~25 s | CAN to the HMI, maps/GPS, media, USB stick |
| **iDrive 7** (MGU, Linux x86-64) | Intel Apollo Lake class, Linux 4.14, x86-64 (QEMU TCG) | **42% Low** | **Center screen (HU) and rear-seat entertainment screen (RSE)**, touch, rotor and buttons, SSH (root shell), virtual cluster/HUD (simulated CAN/GPS, not fed by the HMI), coding editor (1,288 parameters), first boot ~2 min then ~1 s from a snapshot | CAN to the HMI, GPS/maps, media, USB stick; many vehicle services are not faked yet |
| **CIC** (High, "BMW L6") | SH7785 (SH-4A) board, QNX 6.3 | **29% Low** | Real HMI (Hauptmenü), rotor, push, tilt, MENU/BACK/OPTION/MEDIA/MAP keys, SSH (QNX shell), virtual cluster/HUD (simulated CAN/GPS, not fed by the HMI), HMI in 12 languages (follows the environment's language) | Touch (the CIC has none), CAN to the HMI, maps (the virtual GPS receiver is detected and feeds the driver, but nothing shows without maps), coding editor, fast boot; NAV and COM keys do nothing; boot ~1 min |

\* Functionality level as shown in the "New environment" assistant (average over 12 features). Maps and route guidance are not available on any
system: the firmware packages do not carry map data and the navigation engine does not run.

## What you need

* A Mac with Apple Silicon (iDrive 8 uses the Hypervisor framework) and macOS 14 or later. Python 3 (the system one is enough). NBT Evo / iDrive 5/6 can also run on Linux and WSL; see [Linux/WSL](docs/LINUX.md).
* **Windows 10/11 (iDrive 5/6 / NBT Evo):** native build for all generations (Python + custom QEMU .exe builds + renderers, no WSL; iDrive 8 is slow on x86 PCs because it runs in TCG): compile once with `windows\Build.ps1` (MSYS2), then `IDEmu.bat`; or use a packaged zip from `windows\Package.ps1`. A WSL2 launcher (`IDEmu-wsl.bat`) is kept as a fallback. See [Windows](docs/WINDOWS.md). Built and run on Windows 10: iDrive 5/6, iDrive 7 and CIC boot to the real HMI; iDrive 8 builds and its pieces start, but its full boot was not verified (the guest needs 12 GiB of committed memory).
* **Linux (iDrive 5/6 / NBT Evo):** native build with `linux/build-linux.sh`, run with `linux/IDEmu.sh`, package with `linux/package-linux.sh`: see [Linux](docs/LINUX.md).
* Your **own firmware packages** (PSdZData / SWFL files). The assistant tells you which exact files each iDrive version needs and can scan a folder
  for them. Nothing is modified; images are built in the project folder.
* A QEMU build: the project uses custom QEMU 11.1.2 builds (OMAP5, SH7785 and `idemu-shm` devices). Source and recipe: [src/qemu](src/qemu) and
  [tools/qemu/build.sh](tools/qemu/build.sh). Homebrew `qemu` provides `qemu-img` (needed for the iDrive 7 snapshot) and `qemu-system-aarch64` (iDrive 8).
* Renderer helpers (`glhost`, `glhost7`, `mguhost`) are built from [src](src) with clang. iDrive 8 also needs ANGLE (`libEGL.dylib` and `libGLESv2.dylib`),
  found in any installed Chromium-based app, or set `IDEMU_ANGLE`.

## Quick start

```bash
./IDEmu.command        # opens IDEmu in an Electron window (cd electron && npm install once); without Electron it opens your browser
python3 -m idemu gui   # the same, web interface at http://127.0.0.1:8765
```

On Windows: `windows\Build.ps1 -InstallMsys2` once, then double-click `IDEmu.bat` (native, see [docs/WINDOWS.md](docs/WINDOWS.md)). On Linux: `linux/build-linux.sh` once, then `linux/IDEmu.sh`.

New environment → iDrive version → car model → required files → parameters → create → build (~20 s for iDrive 5/6) → start. Command line:
`python3 -m idemu list | build <id> | run <id>`.

## Highlights

* **Real software**: the original HMI binaries run unmodified; hardware that is missing in the VM is replaced by small shims (graphics, window system,
  coding, vehicle services) kept outside the system images.
* **Virtual controller**: rotor, push, tilt and buttons on screen and on the keyboard; mouse as touch screen.
* **Virtual car**: CAN signals, scenarios, record/replay and a TCP server; GPS with NMEA/UBX output and GPX routes; cluster and HUD views (iDrive 5/6).
* **Rear-view camera**: your computer's webcam is shown over the display when reverse is engaged on the virtual CAN bus, with parking guide lines (see [docs/CAMERA.md](docs/CAMERA.md)). Host-side overlay: the emulated HMI does not receive the video.
* **Your own car from its VIN**: the type key (VIN characters 4–7) is decoded with the KIS database of your PSdZData into chassis, body, engine, model year,
  market and iDrive generation, and the new environment is set up to match. iDrive 5/6 head units can be **Navigation Professional**, **Business** or **EntryNav**.
* **System files, unpacked**: one click extracts the SWFL/HAR packages (or the built image) into normal files you can browse in the app or open in Finder.
* **Coding editor**: parameters with their factory values from the firmware, backups, import/export, flash and verified restart.
* **Fast boot**: the booted state is saved and restored in about a second (iDrive 5, 6 and 7).
* **Tools**: SSH into the head unit, phone link over Wi-Fi, V850 firmware viewer, live statistics (CPU, RAM, GPU, FPS).

## Repository map

| Path | Content |
|---|---|
| `idemu/` | Python package: build, runtime, web server and interface (`idemu/web`) |
| `src/` | C sources: QEMU patches and boards, GL renderers, guest shims, V850 emulation |
| `tools/` | Image builders, analysers and test helpers (`tools/mgu`, `tools/cic`, `tools/qemu`) |
| `electron/` | Desktop wrapper |
| `docs/` | Technical notes: [architecture](docs/ARQUITETURA.md), [API](docs/API.md), [other generations](docs/OUTRAS_GERACOES.md), [CIC](docs/CIC.md), [touch](docs/TOQUE.md), [V850](docs/V850.md), [cluster and HUD](docs/CLUSTER_HUD.md) (in Portuguese) |
| `tests/` | `python3 -m unittest discover -s tests` |

## License and legal

IDEmu is licensed under the **[PolyForm Noncommercial License 1.0.0](LICENSE)**: you may use, study, change and share it for noncommercial purposes
(personal use, research, education, hobby). Commercial use needs a separate license from the licensor. Files in `src/qemu` are derived from QEMU and
stay under GPL-2.0-or-later (see [NOTICE](NOTICE)).

IDEmu is not affiliated with or endorsed by BMW AG or any supplier. This repository contains **no BMW software, firmware or map data**; use only files
you are entitled to use, and respect the licenses that come with them.
