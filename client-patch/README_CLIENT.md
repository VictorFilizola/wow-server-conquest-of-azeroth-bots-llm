# Conquest of Azeroth Client Patch

This directory contains the pre-configured fixes needed to run the Conquest of Azeroth / Ascension live client smoothly with this server and Wine/Proton.

## What is in here?

1. **`DivxTac.dll`**: Native 32-bit stub DLL. Replaces Ascension's bundled `DivxTac.dll` which attempts to hook video capture APIs that trigger an infinite deadlock (`RtlpWaitForCriticalSection` in Wine loader section) on the character loading screen.
2. **`Data/patch-B.MPQ`**: 
   - Fixes the custom Transmog UI so it uses native `C_Appearance.ApplyPendingAppearances()` instead of the broken `.localappearance` chat command.
   - Neutralizes obsolete `CharacterAdvancementStateCompat.lua` and `CharacterAdvancementCompat.lua` scripts that spammed the chat log with `localtalent` and `localspec` errors on level up.
3. **`Data/realmlist.wtf`**: Configured to connect to `127.0.0.1` (or change to your server's LAN/Tailscale IP).
4. **`play.sh`**: Launch script with `WINEDLLOVERRIDES="d3d9=n,b"` to force DXVK for proper rendering.

## Installation Instructions

1. Locate your Ascension client directory (e.g. `client-coa/ascension-live`).
2. Copy `DivxTac.dll` and `play.sh` directly into the client root folder (alongside `Ascension.exe`).
3. Copy `patch-B.MPQ` and `realmlist.wtf` into the client's `Data/` folder (overwrite when prompted).
4. Launch the game using:
   ```bash
   ./play.sh
   ```
   Or manually:
   ```bash
   WINEDLLOVERRIDES="d3d9=n,b" wine Ascension.exe
   ```
