# WoW Server — AzerothCore + Conquest of Azeroth (21 Classes + LLM Bots)

A complete, self-contained World of Warcraft private server stack featuring **Conquest of Azeroth (CoA)** 21 custom classes, Level 80 progression through Northrend, **Playerbots AI Alt-Squad** companions, and **LLM-driven roleplay chatter** (DeepSeek / OpenAI / Ollama).

Auth server: port `3724` · World server: port `8085` · DB: port `3307`

---

## Requirements

Only Docker + Docker Compose v2 + Git are required on the host system. All build tools, dependencies, and database engines run inside isolated Docker containers.

- **CPU:** 4+ cores (3.0 GHz+ recommended).
- **RAM:** 8 GB minimum (16 GB comfortable for 2,500 bots).
- **Disk:** ~30–40 GB free space (SSD recommended).
- **OS:** Linux (Arch, CachyOS, Ubuntu, Debian, Fedora, SteamOS) or Windows via WSL2.

---

## Quick Start

### 1. Start the Server
From the root of this directory:
```bash
docker compose up -d --build
```
*(On subsequent runs, omit `--build` to boot instantly: `docker compose up -d`)*

### 2. Create Your First Account
Once the containers are running, attach to the worldserver console:
```bash
docker attach coa-bots-worldserver
```
*(If you customized container names, use `docker attach <container-name>`)*

Type:
```text
account create <username> <password>
account set gmlevel <username> 3 -1
```
- `3` = Administrator (full GM access).
- `-1` = Grants GM access across all realms.
- **To detach cleanly without stopping the server:** Press `Ctrl+P`, followed by `Ctrl+Q`.

### 3. Change Realm Name or Server IP (for LAN / Tailscale)
By default, the server is set to `127.0.0.1` for local play. To play with friends over LAN or Tailscale VPN:
```bash
docker exec coa-bots-database sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "UPDATE acore_auth.realmlist SET name=\"Conquest of Azeroth\", address=\"<your-server-ip>\" WHERE id=1;"'
docker compose restart ac-authserver
```

---

## Client Setup

To connect and use all features (Transmog UI, custom CoA progression, and the Chatter Companion bot-editor UI), apply the client patches and addons below to your **Ascension Conquest of Azeroth (3.3.5a)** client folder (`<Client>`, e.g. `ascension-live/`).

### 1. Apply Required Client Patches (`client-patch/`)
Copy the files from `client-patch/` into your `<Client>` directory (see also `client-patch/README_CLIENT.md`):
- **Client root (`<Client>/`, alongside `Ascension.exe`):**
  - `client-patch/DivxTac.dll` — native 32-bit stub DLL that prevents the 100% loading-screen deadlock under Wine/Proton.
  - `client-patch/play.sh` — Wine/DXVK launch script (`WINEDLLOVERRIDES="d3d9=n,b" wine Ascension.exe`).
- **Data directory (`<Client>/Data/`, overwrite when prompted):**
  - `client-patch/Data/patch-B.MPQ` — fixes the Transmog UI (`C_Appearance.ApplyPendingAppearances()`) and silences obsolete `localtalent` / `localspec` chat spam.
  - `client-patch/Data/realmlist.wtf` — pre-configured with `set realmlist 127.0.0.1`. For LAN or Tailscale play, edit this file to `set realmlist <your-server-ip>`.

### 2. Install Client AddOns (`client-addons/`)
- **Chatter Companion (recommended for `mod-llm-chatter`):** Copy `client-addons/Chatter` into `<Client>/Interface/AddOns/Chatter` so `Chatter.toc` sits directly inside `Interface/AddOns/Chatter/Chatter.toc`. **Keep the folder name `Chatter` exact**, otherwise the 3.3.5a client will not list or load it.
- **Crow's Cache (optional):** Copy `client-addons/CoACrowsCache` into `<Client>/Interface/AddOns/CoACrowsCache` if you enable the High-Risk level-60 Crow's Cache world-map marker event.

Expected `<Client>` layout after setup:
```text
<Client>/
├── Ascension.exe
├── DivxTac.dll                  # from client-patch/
├── play.sh                      # from client-patch/ (Linux/Wine)
├── Data/
│   ├── patch-B.MPQ              # from client-patch/Data/ (overwrite)
│   └── realmlist.wtf            # from client-patch/Data/ (127.0.0.1 or server IP)
└── Interface/
    └── AddOns/
        ├── Chatter/             # from client-addons/Chatter/
        │   └── Chatter.toc
        └── CoACrowsCache/       # optional, from client-addons/CoACrowsCache/
            └── CoACrowsCache.toc
```

### 3. Launch & Activate AddOns
1. **Launch the game:**
   - **Linux / Wine / Proton:** run `./play.sh` (or `WINEDLLOVERRIDES="d3d9=n,b" wine Ascension.exe`).
   - **Windows:** launch `Ascension.exe`.
   - *(Always perform a full client restart after adding new addon folders for the first time — `/reload` alone will not detect newly added files.)*
2. **Enable AddOns at Character Select:** Click **AddOns** in the bottom-left corner, make sure **Chatter** is checked, and tick **Load out of date AddOns**.
3. **Open Chatter In-Game:** Type `/chatter` or `/llmc` in chat (or open **Esc → Interface → AddOns → Chatter → Bot Traits / Background Stories**) to view Known Bots, edit traits, and edit or regenerate bot backstories.

---

## The 21 Custom Conquest of Azeroth Classes

This server replaces the standard 10 classes with **21 completely unique, fully fleshed-out classes** (IDs 12 through 32), each with bespoke talent trees, stances, mechanics, resource systems, and spells:

| Class ID | Class Name | Combat Role | Class Fantasy & Signature Mechanics |
| :---: | :--- | :---: | :--- |
| **12** | **Barbarian** | Melee DPS / Tank | Dual-wield bruiser powered by Fury; charges, skull-cracking physical devastation, and berserker survivability. |
| **13** | **Witch Doctor** | Healer / Caster DPS | Mojo and voodoo hexes; summons spirit totems, dark hexes, and powerful tribe restoration wards. |
| **14** | **Felsworn** | Melee / Hybrid DPS | Corrupted warrior channeling demonic chaos flame; transforms pain into raw offensive power. |
| **15** | **Witch Hunter** | Ranged DPS | Inquisitor utilizing crossbows, holy seals, silver bullets, and cleansing pyres against darkness. |
| **16** | **Stormbringer** | Hybrid DPS / Tank | Master of thunder and lightning; channels crashing tempest strikes, gale-force winds, and static shocks. |
| **17** | **Knight of Xoroth** | Tank / Melee DPS | Dread vanguard rider steeped in hellfire; commands dreadsteeds, defensive brimstone, and demonic pacts. |
| **18** | **Guardian** | Pure Tank | Unshakeable bastion of physical defense; towers behind massive shields with heavy mitigation and defensive formations. |
| **19** | **Templar** | Tank / Healer / Melee | Zealous crusader radiating blinding holy light; smites foes with righteous judgment and lays on hands. |
| **20** | **Bloodmage** | Caster DPS / Healer | Hemomancer manipulating lifeforce; sacrifices health to power devastating crimson magic and blood shields. |
| **21** | **Ranger** | Physical Ranged DPS | Wilderness sniper and trapper; lethal long-range precision shots, camouflage, and survivalist utility. |
| **22** | **Chronomancer** | Healer / Caster DPS | Master of time; rewinds ally damage, accelerates attack speeds, slows enemies, and loops temporal echoes. |
| **23** | **Necromancer** | Caster DPS / Healer | Macabre commander of death; animates skeleton armies, casts bone armor, and channels life siphon curses. |
| **24** | **Pyromancer** | Pure Caster DPS | Consumed by elemental fire; combustion chains, blazing infernos, and relentless escalating heat damage. |
| **25** | **Cultist** | Caster DPS / Support | Herald of the Old Gods; channels void madness, shadow tentacles, and sanity-draining psychic whispers. |
| **26** | **Starcaller** | Caster DPS / Healer | Celestial astronomer; channels lunar wrath, starlight showers, solar flares, and astrological alignments. |
| **27** | **Sun Cleric** | Healer / Support | Solar devotee; channels warm restorative dawn rays, radiant shields, and blinding sunbursts. |
| **28** | **Tinker** | Hybrid DPS / Tank | High-tech inventor; deploys automated turrets, steam-powered mechs, mortar cannons, and electric gadgets. |
| **29** | **Venomancer** | DoT Caster / Shapeshifter | Toxic plague master; inflicts debilitating paralytic poisons, corrosive acid, and insectoid morphs. |
| **30** | **Reaper** | Melee DPS | Grim executioner wielding two-handed scythes; harvests soul fragments and delivers executioner strikes. |
| **31** | **Primalist** | Shapeshifter / Hybrid | The ultimate wild druid: Bear Form (*Son of Ursoc*), Tree Form (*Ancient of War*), Earth Golem, and Beast Master. |
| **32** | **Runemaster** | Melee / Hybrid DPS | Inscribes ancient ley-runes into flesh and earth; channels elemental surges through bare-fist martial arts. |

---

## Companion & Solo Systems

### 1. `mod-playerbots` (Alt-Squad System)
- **Random Bots:** 2,500 bots roam the world, questing, fighting, chatting, and running dungeons.
- **Alt-Squad Party:** You can log in your own alternate characters as intelligent AI bots to form a permanent 5-man leveling squad!
  - **Summon your alt:** `.playerbots bot add <AltName>` *(or `.bot +<AltName>`)*
  - **Invite to party:** `/invite <AltName>` *(they instantly accept, follow, fight, heal, and gain XP with you)*
  - **Dismiss alt:** `.playerbots bot remove <AltName>` *(or `.bot -<AltName>`)*
  - **Party Chat commands:** Whisper or say `follow`, `stay`, `attack`, `nc -loot` (stop looting), `nc +loot`.

### 2. `mod-llm-chatter` (AI Roleplay Personalities)
Bots use LLM-driven intelligence (DeepSeek / OpenAI / Anthropic / Google / OpenRouter / Ollama) to hold in-character conversations across party/raid chat, proximity `/say`, General, Guild, battlegrounds, and raids, complete with persistent shared memories and generated background stories.
- Configured with **bespoke roleplay speech modifiers for all 21 custom CoA classes** (e.g. Barbarians roar about battle fury, Witch Doctors speak of spirits and mojo, Chronomancers speak in temporal paradoxes).
- See `CONFIG.md` to configure your DeepSeek / OpenRouter API key.

### 3. Chatter Companion Addon (`client-addons/Chatter`)
An in-game WoW 3.3.5a companion UI ([Hokken/Chatter-Companion](https://github.com/Hokken/Chatter-Companion)) for managing `mod-llm-chatter` bot personalities directly inside the client:
- Browse your **Known Bots** roster (bots that hold memories with your character).
- Edit each bot's **3 persistent personality traits** (up to 64 characters each) and view its LLM-generated speaking **tone**.
- Read, rewrite (**Save Story**, up to 1,000 characters), or **Regenerate Story** for each bot's background story.
- **Forget selected** bots to erase their shared memories with your character while preserving their global personality.

**Installation:**
1. Copy `client-addons/Chatter` into your client's `Interface/AddOns/` folder so `Chatter.toc` sits directly at `<Client>/Interface/AddOns/Chatter/Chatter.toc` (the folder must be named exactly `Chatter`).
2. Fully restart the WoW / Ascension client (a `/reload` alone will not discover newly added files on first install).
3. At the character selection screen, click **AddOns** (bottom-left), verify **Chatter** is enabled, and tick **Load out of date AddOns**.

**How to Use In-Game:**
- Type `/chatter` or `/llmc` to open the floating editor window (or open **Interface → AddOns → Chatter** for the dedicated **Bot Traits** and **Background Stories** panels).
- Group up with a bot and play briefly so it forms a memory of your character and appears in the **Known Bots** list (click **Refresh** to update the roster).
- Select a bot, edit its 3 traits, and click **Save Traits** — the Python bridge regenerates its tone and background story asynchronously while the UI polls and displays the result automatically.
- Edit the story box and click **Save Story** to write a custom backstory without regenerating traits/tone, or click **Regenerate Story** to generate a fresh origin story.
- Check one or more bots in the list and click **Forget selected** to clear their memories with your character.

### 4. `mod-autobalance`
- Automatically scales creature health and damage dynamically based on your group size.
- 5-man dungeons are tuned for 1 player; 10/25/40-man raids are tuned for your 5-man Alt-Squad party.

### 5. `mod-transmog`
- Full transmog system with **all restrictions removed**:
  - `IgnoreReqClass = 1` (wear any appearance across classes).
  - `IgnoreReqLevel = 1` (transmog high-level appearances at level 1).
  - `AllowMixedArmorTypes = 1` (freely mix cloth, leather, mail, and plate).
  - `CopperCost = 0` (free transmogrification).

---

## What We Did on the Client to Make It Work

Running the Ascension Conquest of Azeroth client on modern Linux/Wine or Windows required solving several critical issues:

### 1. The Character Loading Screen Freeze (Wine Loader Deadlock)
- **The Problem:** Upon character selection, the loading screen progressed to 100% and froze indefinitely. Wine logs showed threads waiting forever in `RtlpWaitForCriticalSection` on `ntdll/loader.c: loader_section`.
- **The Cause:** Ascension's client ships with `DivxTac.dll`, which attempts to hook into low-level video capture and codec interfaces on world entry. Under Wine's thread loader, this triggered a fatal deadlock.
- **The Fix:** We compiled and installed a lightweight **32-bit native stub export DLL** (`DivxTac.dll`) that satisfies the client's import table while bypassing the buggy capture hooks entirely. Character loading now completes instantly.

### 2. Transmog UI Error Fix (`patch-B.MPQ`)
- **The Problem:** Clicking to apply transmog appearances threw a chat error: `"command localappearance does not exist"`.
- **The Cause:** The UI script (`CustomTransmog.lua`) was attempting to send an obsolete, hardcoded server chat command (`.localappearance <item>`).
- **The Fix:** We modified `CustomTransmog.lua` inside `patch-B.MPQ` to invoke the native client C-API:
  ```lua
  C_Appearance.ApplyPendingAppearances()
  ```
  Transmog appearances now apply directly and instantly.

### 3. Silencing Talent & Spec Spam (`patch-B.MPQ`)
- **The Problem:** Leveling up or selecting talents flooded the chat frame with errors:
  `"command localtalent <id> does not exist"` and `"command localspec <id> does not exist"`.
- **The Cause:** Legacy compatibility scripts (`CharacterAdvancementStateCompat.lua` and `CharacterAdvancementCompat.lua`) were sending deprecated slash commands on every state change.
- **The Fix:** Neutralized the command dispatchers inside `patch-B.MPQ`.

### 4. Wine Execution Parameters
To ensure DXVK renders custom CoA particle effects, spell overlays, and UI textures properly, launch the game with:
```bash
WINEDLLOVERRIDES="d3d9=n,b" wine Ascension.exe
```
*(All patched files are pre-packaged inside `client-patch/` and optional addons inside `client-addons/`; see [Client Setup](#client-setup) and `client-patch/README_CLIENT.md` for full installation steps.)*

---

## What We Tweaked on the Server Core

### 1. Plaintext World Headers Compatibility (`WorldSocket.cpp` & `WorldSocket.h`)
- **The Problem:** The Ascension client modified opcode encryption and packet headers. Standard AzerothCore RC4 header encryption caused world socket connection drops immediately after authentication.
- **The Fix:** Added `CoA.PlaintextWorldHeaders = 1` support in `WorldSocket.cpp`, enabling clean, desync-free authentication for Ascension clients while preserving security.

### 2. Taxi Path Store Bounds & Item Check Fix (`DBCStores.cpp`)
- **The Problem:** Ascension added custom flight paths exceeding standard row counts, triggering index-out-of-bounds assertion crashes on startup. Additionally, the server checked for Rune of Ascension in `CurrencyTypes.dbc` where Ascension moved it to `Item.dbc`.
- **The Fix:** Updated `DBCStores.cpp` to dynamically iterate `TaxiPathStore` and verified Rune of Ascension (375250) via `sItemStore`.

### 3. Auto-Progression (`coa.conf`)
- Set `CoA.AutoProgression = 1` so that as you level up, all CoA class spells, passives, and weapon/armor proficiencies are automatically awarded without needing manual trainer visits.

### 4. Database Overlays (`mod-ethereal-bazaar`)
- Fixed SQL syntax error in `06_ethereal_bazaar_set_caches.sql` (`count TINYINT UNSIGNED NOT NULL DEFAULT 1`).

---

## In-Game Cheats, Commands & Controls

Enable GM powers in-game:
```text
.account on
```

### Fast Progression & Cheats
```text
.character level 80           # Instantly set level to 80
.localclassrepair             # Learn all CoA class spells & proficiencies for level 80
.maxskill                     # Maximize all weapon, defense, and profession skills
.modify money 2000000000      # Grant ~200,000 Gold (near max gold cap)
```

### Bot Alt-Squad Commands
```text
.playerbots bot add <Name>    # Summon your offline alt into the world as an AI bot
/invite <Name>                # Invite them to your group
.playerbots bot remove <Name> # Dismiss your alt bot
```

### Chatter Companion Addon
```text
/chatter                      # Open the floating Chatter Companion bot traits & backstory editor
/llmc                         # Alias to open Chatter Companion
```

### Handy GM Utilities
```text
.gm fly on                    # Enable flight anywhere
.speed 2                      # Double your movement speed
.tele stormwind               # Teleport to Stormwind (or orgrimmar, dalaran, shattrath)
.additem <id> [count]         # Spawn any item
.revive                       # Resurrect yourself
```
