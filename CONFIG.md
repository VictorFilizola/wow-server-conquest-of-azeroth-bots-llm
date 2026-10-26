# Configuration Guide

All live configuration files live under `env/dist/etc/`. Docker bind-mounts this directory into the containers, so edits take effect after a worldserver restart (or a quick `docker compose restart ac-worldserver`).

---

## Where Things Are

| File | Purpose |
| :--- | :--- |
| `env/dist/etc/coa.conf` | **Conquest of Azeroth core:** class models, progression, plaintext world headers, scaling, rulesets |
| `env/dist/etc/worldserver.conf` | **Core World Server:** max level (80), drop rates, ports, packet rates |
| `env/dist/etc/authserver.conf` | **Auth Server:** login realm port (3724), database credentials |
| `env/dist/etc/modules/playerbots.conf` | **AI Companions & Alt-Squad:** bot count, alt bot behavior, quest sync |
| `env/dist/etc/modules/mod_llm_chatter.conf` | **LLM Roleplay:** DeepSeek / OpenRouter API keys, model selection, trigger rates |
| `env/dist/etc/modules/transmog.conf` | **Transmog:** visual rules, class/level restrictions, copper cost |
| `env/dist/etc/modules/AutoBalance.conf` | **Instance Scaling:** 5-man raid scaling, dynamic HP/damage multipliers |
| `env/dist/etc/modules/npc_allmounts.conf` | **Mount Vendor:** vendor configurations and taught spells |

---

## Secrets & API Keys

- `env/dist/etc/modules/mod_llm_chatter.conf` → `LLMChatter.OpenRouter.ApiKey` = **your DeepSeek / OpenRouter API key**. Committed as placeholder `YOUR_DEEPSEEK_API_KEY`; paste your real key there.
- DB password: `DOCKER_DB_ROOT_PASSWORD` in `.env` (defaults to `password`).

---

## 1. Conquest of Azeroth Core — `env/dist/etc/coa.conf`

Key knobs that control custom CoA features:

- `CoA.Enable = 1` — Enables the 21 custom classes, custom advancement, and CoA rulesets.
- `CoA.PlaintextWorldHeaders = 1` — **CRITICAL:** Allows the Ascension client to authenticate and communicate without encryption desync on the world socket.
- `CoA.AutoProgression = 1` — **CRITICAL:** Automatically grants all CoA class spells and proficiencies when you level up. (If spells ever desync, use `.localclassrepair` in-game).
- `CoA.AllowRemoteClients = 1` — Allows connections from remote machines and LAN/VPN.
- `CoA.UnlockAllVanity = 1` — Automatically grants all vanity transmog appearances and mounts.
- `CoA.MaxRidingFromStart = 1` — Unlocks fast ground and flying mounts from the start.
- `CoA.EquippedGearLoot = 1` & `CoA.EquippedGearLootChance = 10` — Humanoid enemies drop the gear they are visually wearing.

---

## 2. Bots & Alt-Squad — `env/dist/etc/modules/playerbots.conf`

The heart of the solo companion experience:

- `PlayerbotsDatabaseInfo = "ac-database;3306;root;password;acore_playerbots"` — Database connection string inside Docker.
- `AiPlayerbot.KeepAltsInGroup = 1` — Automatically keeps your alternate characters in your party when you invite them.
- `AiPlayerbot.SummonWhenGroup = 1` — Teleports your alt bot directly to your side upon grouping up.
- `AiPlayerbot.SyncQuestWithPlayer = 1` — Bots auto-accept and auto-complete your quests when you hand them in.
- `AiPlayerbot.MinRandomBots = 2500` / `AiPlayerbot.MaxRandomBots = 2500` — Random bots populating the world.
- `AiPlayerbot.RandomBotMinLevel = 1` / `AiPlayerbot.RandomBotMaxLevel = 80` — Level range of roaming bots.

### In-Game Bot Commands:
```text
.playerbots bot add <AltName>   # summon your offline alt into the world as a bot
/invite <AltName>               # invite them into party (auto-accepts and follows)
.playerbots bot remove <AltName># dismiss/logout the bot
```

Party chat / whisper commands:
```text
follow / stay / attack
nc -loot            # tell bots to stop looting corpses
nc +loot            # resume bot looting
```

---

## 3. LLM Chatter — `env/dist/etc/modules/mod_llm_chatter.conf`

Pre-configured for **DeepSeek** (with custom roleplay personas for all 21 CoA classes):
```text
LLMChatter.Provider        = openrouter
LLMChatter.Model           = deepseek-chat
LLMChatter.OpenRouter.BaseUrl = https://api.deepseek.com
LLMChatter.OpenRouter.ApiKey  = "YOUR_DEEPSEEK_API_KEY"
```

To switch providers:
* **OpenAI:** `Provider = openai`, `Model = gpt-4o-mini`, `OpenAI.ApiKey = "sk-..."`
* **Anthropic:** `Provider = anthropic`, `Model = claude-3-5-haiku-latest`, `Anthropic.ApiKey = "sk-..."`
* **Ollama (local):** `Provider = ollama`, `Model = qwen2.5:7b-instruct`, `Ollama.BaseUrl = http://host.docker.internal:11434`

Restart the worldserver and bridge container after editing:
```bash
docker compose restart ac-worldserver ac-llm-chatter-bridge
```

---

## 4. Transmog & Scaling — `env/dist/etc/modules/`

- **`transmog.conf`**:
  - `Transmogrification.IgnoreReqClass = 1` (Wear plate on mages, cloth skulls on warriors).
  - `Transmogrification.IgnoreReqLevel = 1` (Transmog level 80 gear at level 1).
  - `Transmogrification.AllowMixedArmorTypes = 1` (Mix cloth/leather/mail/plate).
  - `Transmogrification.CopperCost = 0` (Free transmog).
- **`AutoBalance.conf`**:
  - `AutoBalance.MinPlayers = 1` (Scales 5-man dungeons to 1 player).
  - `AutoBalance.MinPlayers.Raid = 5` (Scales 10/25/40-man raids to a 5-man playerbot squad).
- **`worldserver.conf`**:
  - `MaxPlayerLevel = 80` (Enables progression through Northrend / WotLK content).
  - `Rate.Drop.Item.GroupAmount = 4` (Bosses drop 4x loot for your 5-man party).
