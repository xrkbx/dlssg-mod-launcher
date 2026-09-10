# DLSSG Mod Launcher

A Windows GUI launcher that installs the [dlssg_for_sm86](https://github.com/sdli1995/dlssg_for_sm86) DLSS Frame Generation mod into your games and manages your DLSS DLLs (Super Resolution and Ray Reconstruction), with automatic game and folder detection, one-click safe install/uninstall, and full backups.

Built for RTX 20 and 30 series cards (Turing / Ampere) that do not have native DLSS Frame Generation.

> [!WARNING]
> This tool is intended **solely for single-player games** to enhance hardware performance and feature accessibility. **Do not use it in multiplayer games or titles protected by anti-cheat systems** (BattlEye, Easy Anti-Cheat, etc.). Doing so may result in a permanent, non-reversible ban. The launcher refuses to install into games where it detects anti-cheat, but you are responsible for how you use it.

---

## What it does

- **Scans your machine** for installed games across Steam, Epic, GOG, Ubisoft, EA/Origin, Xbox, Battle.net, and custom folders, and lists the ones that have DLSS DLLs.
- **Installs the DLSS Frame Generation mod** (`dlssg_for_sm86`) into the correct folder for each game (next to the render executable, which for Unreal Engine games is the `Binaries\Win64` shipping-exe folder, not the plugin folder).
- **Updates DLSS DLLs** (`nvngx_dlss.dll` upscaler, `nvngx_dlssd.dll` Ray Reconstruction) to the latest version, either by automatic verified download or manually from TechPowerUp.
- **Backs up everything** before making changes, and can fully uninstall and restore.

## Features

- **Multi-launcher + all-drive scanning** with an optional deep scan and custom search folders.
- **Engine-aware install-folder detection** (Unreal, Unity, RED/Cyberpunk-style, and a best-guess fallback) with a confidence rating and a confirm-or-override step before anything is written.
- **One row per game**, even when a game splits its DLSS DLLs across separate `DLSS` and `Streamline` folders (common on Unreal Engine titles).
- **DLSS DLL manager** with verified auto-download from the [DLSS Swapper](https://github.com/beeradmoore/dlss-swapper) manifest (MD5-checked) or manual download from [TechPowerUp](https://www.techpowerup.com/download/nvidia-dlss-dll/).
- **Scan cache** so it only rescans when you ask it to.
- **Rename** games and keep the names across rescans.
- **Windows Defender exclusion** helper (the mod is a common false positive).

## Requirements

- Windows 10 / 11 (x64)
- An NVIDIA RTX 20 or 30 series GPU with current drivers (the mod needs the NVIDIA NGX / NVAPI / CUDA driver interfaces)
- Windows PowerShell 5.1 (built in) or PowerShell 7+
- A DirectX 12 game with native DLSS support

## Installation and usage

1. Download or clone this repository.
2. Double-click **`Run-DLSSG-Launcher.cmd`**.
3. On first run it offers to download the mod package from the [dlssg_for_sm86](https://github.com/sdli1995/dlssg_for_sm86) repository. It is **not** bundled here; it is downloaded from the original source.
4. Pick a game, confirm the detected install folder, and click **Install / update mod**.
5. Launch the game and enable **DLSS Super Resolution**, **NVIDIA Reflex**, then **DLSS Frame Generation** in its graphics settings.

The launcher never installs into a game without you confirming the target folder, and it always backs up first.

## Safety features

- **Confirm-or-override** the detected install folder before every install.
- **Backups** of each game's original DLSS DLLs and of any file about to be overwritten. Full uninstall and restore.
- **No double-install**: it detects if the mod is already present under any proxy name and refuses to add a second copy (which would crash the game).
- **Anti-cheat block**: refuses to install into games that ship BattlEye / Easy Anti-Cheat.
- **Verified downloads**: auto-downloaded DLLs are checked against the source manifest's MD5 hashes.

## How it picks the install folder

The DLSS Frame Generation proxy (`version.dll`) must sit next to the executable the OS launches. The launcher detects that folder in priority order: Unreal `*-Shipping.exe`, Unreal exe in a `Binaries\Win64` folder, an exe sitting with the DLSS DLLs, Unity (`*_Data` sibling), then the largest real game exe as a fallback. Each detection carries a confidence level, and you confirm or override it before installing. DLSS DLL updates target the `nvngx_*.dll` folders separately.

---

## Credits and attribution

This launcher is an orchestration tool. It does not contain the mod or the DLSS DLLs; it downloads them from their original sources. All credit for the underlying work belongs to:

- **[dlssg_for_sm86](https://github.com/sdli1995/dlssg_for_sm86)** by **sdli1995** &middot; the native DLSS Frame Generation implementation for SM86 / SM75 that this launcher installs.
- **[dlssg_for_sm75](https://github.com/Coldwood1026/dlssg_for_sm75)** by **Coldwood1026** &middot; the RTX 20 series / SM75 adaptation that `dlssg_for_sm86` builds on.
- **[DLSS Swapper](https://github.com/beeradmoore/dlss-swapper)** by **beeradmoore** &middot; the open-source manifest and hosting used for the verified automatic DLSS DLL downloads.
- **[TechPowerUp](https://www.techpowerup.com/download/nvidia-dlss-dll/)** &middot; the canonical DLSS DLL database used for manual downloads.
- **[dlss-unlocked](https://github.com/ShyVortex/dlss-unlocked)** by **ShyVortex** &middot; the disclaimer and legal notice here are adapted from this project.
- **NVIDIA** &middot; DLSS, DLSS Frame Generation, Ray Reconstruction, NGX, and Streamline.

Please support and star the original projects above.

## Disclaimer

This project is an independent, open-source community modification and interoperability tool. See **[DISCLAIMER.md](DISCLAIMER.md)** for the full legal notice. In short: it is provided "as is", without warranty of any kind, use at your own risk, single-player only, and it is not affiliated with or endorsed by NVIDIA, AMD, Intel, or any game developer or publisher.

## License

The launcher code in this repository is released under the [MIT License](LICENSE). The mod and DLLs it downloads are the property of their respective authors and are covered by their own licenses.
