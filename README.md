# CoA AzerothCore – One-Click Docker Deployment

One-command deployment for the **[jealous-sound/azerothcore-wotlk-coa](https://github.com/jealous-sound/azerothcore-wotlk-coa)**
fork (Conquest of AzerothCore) on your own Linux server – including a one-command updater.

---

## Requirements

| | |
|---|---|
| OS | Debian 12/13 or Ubuntu 22.04/24.04, **x86_64**, root access |
| CPU / RAM | 4+ cores, 8 GB RAM (12 GB recommended; the script creates a swap file) |
| Disk | 25 GB free (build + client data + docker images) |
| Network | ports **3724** (auth), **8085** (world), optional 7878 (SOAP) open |
| Client | WoW **3.3.5a (build 12340)** or the CoA/Ascension client matching the realm |

> Already running **MariaDB** on the host? No problem: the stack ships its own MySQL 8.4
> and binds it to `127.0.0.1:13306` only (see `DB_EXTERNAL_PORT`).

---

## Quick start

```bash
# 1) copy the scripts to your server (keep all files in the same folder)
scp coa-oneclick.sh coa-update.sh apply-missing-updates.sh \
    check-repo-updates.sh fix-build-network.sh fix-container-dns.sh \
    fix-config-warnings.py docker-compose.override.yml root@<SERVER-IP>:/root/

# 2) deploy (base: standard AzerothCore world, downloaded client data v20.0)
bash /root/coa-oneclick.sh 2>&1 | tee /root/coa-deploy.log
```

With **CoA content**, simply upload the two data files to `/root` first – the script finds them
automatically (see [Data files](#data-files-required-for-real-coa-content)):

```bash
scp databases.sql.gz Data.rar root@<SERVER-IP>:/root/     # from your PC
bash /root/coa-oneclick.sh 2>&1 | tee /root/coa-deploy.log
```

Or pass the paths explicitly:

```bash
COA_WORLD_DUMP=/root/databases.sql.gz \
CLIENT_DATA=/root/Data.rar \
GM_ACCOUNT=MyName:MyPass:3 \
bash /root/coa-oneclick.sh 2>&1 | tee /root/coa-deploy.log
```

Player bots (optional): add `WITH_PLAYERBOTS=1` to any command above, or install them later on a
running server with `bash enable-playerbots.sh` – see [Player bots](#player-bots-optional).

Then, in your client `realmlist.wtf`:

```
set realmlist <SERVER-IP>
```

---

## Data files (required for real CoA content)

**These files are NOT part of this repository** – they cannot be redistributed publicly.
Get them from the CoA Discord and upload them to your server. **This is the only manual step.**

| File | What it is | Where to get it |
|---|---|---|
| World database dump, e.g. `databases.sql.gz` | CoA world content (items, spells, quests, creatures) | CoA Discord – world/database package |
| Client data, e.g. `Data.rar` | `dbc/`, `maps/`, `vmaps/`, `mmaps/` – required by the worldserver | CoA Discord – client data package |

### Simplest way: drop them into `/root`

The script **finds the files automatically** – no options needed:

```bash
# 1) from your PC: upload both files to the server's /root
scp databases.sql.gz Data.rar root@<SERVER-IP>:/root/

# 2) run the deployment
bash coa-oneclick.sh
```

The script tells you what it found:

```
[INFO ] World database dump : /root/databases.sql.gz
[INFO ] Client data         : /root/Data.rar
```

If nothing is found it prints `none found` and continues with standard AzerothCore content.

### Or pass the paths explicitly

```bash
COA_WORLD_DUMP=/root/my_dump.sql.gz \
CLIENT_DATA=/root/clientdata.zip \
GM_ACCOUNT=MyName:MyPass:3 \
bash coa-oneclick.sh
```

### Details

* `COA_WORLD_DUMP` – any `.sql` or `.sql.gz` mysqldump. **Only the `acore_world` section is used**,
  so a full "all databases" dump works fine: your accounts and characters stay untouched.
* `CLIENT_DATA` – `.rar`, `.zip` or a folder containing `dbc`, `maps`, `vmaps`, `mmaps`.
  RAR5/WinRAR-7 archives are supported (the script installs RARLAB's `unrar`).
* **Without these files the server still runs**: the `ac-client-data-init` container downloads the
  standard client data (v20.0) and the standard AzerothCore world is used – just without CoA content.
* **Alternative for the client data:** extract them yourself from a WoW 3.3.5a client.
  The map extractors are part of this repository and end up in `env/dist/bin/` after the build
  (`map_extractor`, `vmap4_extractor`, `vmap4_assembler`, `mmaps_generator`).

---

## What the deploy script does

| Phase | Content |
|---|---|
| Base | Installs Docker + Compose if missing, creates a swap file (OOM protection) |
| Repository | Clones/updates `/opt/azerothcore`, applies the **build fix** for `mod-ascension-compat` |
| Configuration | Writes `.env` (DB bound to `127.0.0.1:13306`, **random DB root password**), module configs |
| Player bots (optional) | `WITH_PLAYERBOTS=1`: clones `modules/mod-playerbots`, writes `playerbots.conf`, creates `acore_playerbots` + the module base data (see [Player bots](#player-bots-optional)) |
| Client data | Extracts `.rar`/`.zip`/folder (`CLIENT_DATA`) or lets the container download v20.0 |
| Images | `docker compose build` (skipped when images already exist, forced with `WITH_PLAYERBOTS=1`) |
| Database | Imports **only the `acore_world` part** of a CoA dump (auth/characters stay untouched), keeps a rollback copy as `acore_world_old`, disables the AzerothCore auto-updater |
| Updates | Applies all missing repo SQL fixes for **auth, characters, world** – and `acore_playerbots` when the bot module is installed |
| Start | Starts the stack, adds missing core options, sets the realm address |
| Summary | Optional GM account + status report |

Result: `ac-authserver` (3724), `ac-worldserver` (8085), `ac-database` (internal).

The script is **idempotent** – running it again only installs what is missing.

---

## Updating

```bash
bash /root/coa-update.sh            # check for updates, then update if needed
FULL=1 bash /root/coa-update.sh     # force an image rebuild
SKIP_DB=1 bash /root/coa-update.sh  # code only, no database updates
```

What it does:

1. **Checks for updates** (`git fetch`, compares local vs. remote) and prints the new commits
2. If something changed: updates the repo, re-applies the build fix, **applies all missing
   SQL updates** for `acore_auth`, `acore_characters` and `acore_world`
3. Rebuilds the docker images **only if the code changed** (or `FULL=1`)
4. Frees old images (`docker image prune -f`), restarts the stack (with visible progress and
   hard time limits) and prints a status report

If nothing changed, the run finishes in seconds and only re-checks the database.

### What happens while the worldserver restarts

`docker compose up` does not return before `ac-database` is healthy and `ac-db-import` /
`ac-client-data-init` have completed, and the worldserver needs a few minutes to load the
CoA world data. So the scripts print a progress line every 15 seconds while waiting
(`state=... restarts=...` plus the last worldserver log line) and use two safety limits:

* `docker compose up` is limited to **5 minutes**
* the worldserver start is limited to **7 minutes**

If the stack does not come up, all `ac-*` container states plus the last 30 log lines are
printed and the run continues with a clear `[WARN ]` – it never waits silently. The realm
flag is cleared only once the world is really up, because a later start would set the
offline/version-mismatch bits again (the client would show *Realm Offline*).

`apply-missing-updates.sh` registers updates exactly like AzerothCore does
(`name` = file name with `.sql`, `hash` = SHA1 in uppercase, `state` from the source folder:
`PENDING` / `ARCHIVED` / `MODULE`). Files whose content changed are re-applied and re-hashed.
Duplicate-key errors simply mean "content already present" and are registered as applied.
Manual helper scripts under `data/sql/manual/` are never touched.

---

## Player bots (optional)

The deployment can run **[Zyth45/mod-playerbots](https://github.com/Zyth45/mod-playerbots)** – the
*Conquest of Azeroth* port of `mod-playerbots`: random bots fill the world, alt characters can be
driven by the bot AI, and `.playerbots coa tank|heal|dps` recruits a bot of a CoA class with its
specialization, rotation and gear weights.

Player bots are **optional and can be added at any time** – the module is compiled into the
worldserver image only while it is present in `modules/`. A server without bots stays a server
without bots; the deployment only gets one extra file (`enable-playerbots.sh`).

### Add bots to an existing server (one command)

```bash
scp enable-playerbots.sh root@<SERVER-IP>:/root/
bash /root/enable-playerbots.sh        # module + config + database + rebuild + restart
```

The script is idempotent – run it again after a module update or to change a setting.
In the game afterwards: `.playerbots coa dps` recruits a DPS bot, `.playerbots rndbot stats` shows
the pool, `/w <bot> help` lists every command.

### Or install them together with the deployment

```bash
WITH_PLAYERBOTS=1 bash /root/coa-oneclick.sh                        # 200 random bots
PLAYERBOTS_COUNT=500 WITH_PLAYERBOTS=1 bash /root/coa-oneclick.sh   # 500 random bots
PLAYERBOTS_AUTOLOGIN=0 WITH_PLAYERBOTS=1 bash /root/coa-oneclick.sh # only bots you recruit
```

### Settings

The `PLAYERBOTS_*` values are remembered in `/opt/azerothcore/.env`, so `coa-update.sh` keeps them.

| Variable | Default | Meaning |
|---|---|---|
| `PLAYERBOTS_COUNT` | `200` | random bots; ~3.5 GB RAM for 200, ~10 GB for 1000 |
| `PLAYERBOTS_AUTOLOGIN` | `1` | `0` = no random bots at all (only bots you recruit) |
| `PLAYERBOTS_MAP_THREADS` | `8` | raises `MapUpdate.Threads` in `worldserver.conf` (`0` = leave it) |
| `PLAYERBOTS_REPO` / `PLAYERBOTS_BRANCH` | `Zyth45/mod-playerbots` / `coa` | module source |
| `PLAYERBOTS_REF` | – | tag or commit to pin (the script prints the available `bots-*` tags) |
| `BASE_FORCE` | `0` | `1` = import the module base data again |
| `SKIP_BUILD` | `0` | `1` = no image rebuild (config/database only) |

Everything else lives in `env/dist/etc/modules/playerbots.conf`. The file is yours: the script only
syncs the values it manages (CoA zone channel `3`, Ascension world channel, database, bot count,
`CoaSpecRotations`, `BotActiveAlone`, `GroupInvitationPermission`) and appends keys a module update
adds – a key that is defined nowhere logs `Config: Missing property` on every read and silently
falls back to the code default.

### What the script does (and why the database work runs on the host)

| Step | Content |
|---|---|
| Module | `git clone`/`fetch` of `modules/mod-playerbots` (branch `coa`) |
| Config | `playerbots.conf` + `MapUpdate.Threads` (the stock default `1` starves hundreds of bots) |
| Database | `acore_playerbots` + module base data (names, texts, travel nodes) + all missing module updates for `acore_playerbots`, `acore_world` and `acore_characters` |
| Images | `docker compose build` (the worldserver compiles the module in) |
| Start | stack restart, realm flag, verification (module, image, database, bot accounts) |

`mod-playerbots` normally populates and updates its own database at worldserver startup. The runtime
image contains no module sources (only the `ac-db-import` image gets `data/` and `modules/`), so the
worldserver would stop with an empty source directory. This deployment therefore keeps the module
updater off (`Playerbots.Updates.EnableDatabases = 0`, the `AUTOUPDATER ... disabled` warning for
`Playerbots` in the log is expected) and applies the SQL from the host – the same place where the
core updates are applied:

```bash
bash /root/enable-playerbots.sh --status        # read-only: module, image, database, bots
bash /root/apply-missing-updates.sh             # missing updates for all four databases
bash /root/check-repo-updates.sh                # which updates are not registered yet
docker exec ac-worldserver tail -30 /azerothcore/env/dist/logs/Playerbots.log
```

`coa-update.sh` keeps everything in sync: it updates the module, re-syncs `playerbots.conf`,
applies the missing module updates and rebuilds the image when the module changed.

### Notes

* After enabling the bots the first start takes a few minutes: the module creates the bot accounts
  and the first bots log in (`enable-playerbots.sh --status` shows the count).
* Memory: 200 random bots ≈ 3.5 GB on top of the worldserver, 1000 ≈ 10 GB. The swap file of the
  deployment protects the build, not the running server.
* Recommended by the module for CoA (set it manually if you want it):
  `CharacterCreating.Disabled.ClassMask = 2047` in `worldserver.conf` stops **players** rolling the
  nine WotLK classes – the bots do not need it (`AiPlayerbot.CoaClassesOnly` keeps them on CoA
  classes on their own).
* Removing the bots again:
  `cd /opt/azerothcore && rm -rf modules/mod-playerbots && FULL=1 bash /root/coa-update.sh`
  (the `acore_playerbots` database and the bot characters stay, nothing uses them any more).

---


## Useful commands

```bash
cd /opt/azerothcore
docker compose ps                        # status
docker compose logs -f ac-worldserver    # live log
docker compose restart ac-worldserver    # restart
docker compose down                      # stop (data stays in volumes)

bash /root/check-repo-updates.sh         # list SQL updates that are not registered yet
bash /root/apply-missing-updates.sh      # apply them
python3 /root/fix-config-warnings.py     # module configs + "Missing property" check (--dry-run: report only)
docker system df                         # disk usage of images / volumes / cache
```

The database root password lives in `/opt/azerothcore/.env`
(`DOCKER_DB_ROOT_PASSWORD`); on the first run it is also stored in
`/root/coa-db-password.txt`.

---

## Important notes

* **CoA content is not public.** The world database and the client data come from the
  CoA Discord. Without them the deployment runs with the standard AzerothCore world and
  the standard client data (v20.0) – fully functional, but without CoA content.
* **The AzerothCore auto-updater is disabled** (`docker-compose.override.yml`) as soon as a
  CoA world dump was imported: AC update SQL would overwrite CoA content or fail on
  duplicate keys. Updates run through `coa-update.sh` instead.
* **Remote Ascension/CoA clients** need `AscensionCompat.AllowRemoteClients = 1`
  (the script sets it) **and** a patched `Extensions.dll` on the client side
  (`patch_world_endpoint.py` in the fork repository), otherwise the client breaks when
  entering the world.
* **Build fix:** the fork removed `SPELL_EFFECT_NONE` from `enum SpellEffects` while
  `mod-ascension-compat` still uses the name – the build fails. Both scripts patch that line
  automatically (value `0` equals `SPELL_EFFECT_NONE`). If upstream fixes it, nothing happens.
* **Your dump is only used partially:** only the `acore_world` section of a full mysqldump is
  imported, so accounts and characters on the target server stay untouched.
* **After a Docker daemon restart** (`fix-build-network.sh`, `fix-resolv.sh`, a package update) the
  network sandbox and the DNS alias registration of already running containers can become stale.
  Such a container no longer resolves its peers: the worldserver then restarts in a loop with
  `Could not connect to MySQL database at ac-database: Unknown MySQL server host 'ac-database' (-3)`
  (MySQL error `-3` = `CR_UNKNOWN_HOST`). Nothing is damaged – `docker compose up -d --force-recreate`
  (or `bash /root/fix-container-dns.sh`) puts every container back on the same network with a fresh
  resolver configuration; accounts, characters and the CoA world data stay in the Docker volumes.
  Docker normally gives each container the embedded resolver `127.0.0.11`, which answers the
  compose service names – a custom `"dns"` entry in `/etc/docker/daemon.json` only changes which
  servers that resolver forwards *external* lookups to.
* **Missing table after a core update** (e.g. `[1146] Table 'acore_world.creature_display_preset'
  doesn't exist` → `>> ABORTED`): upstream sometimes ships module code that reads a table without
  shipping the SQL. Such SQL belongs in `patches/db-<db>/*.sql` next to these scripts –
  `apply-missing-updates.sh` picks it up automatically (state `MODULE`, registered with its SHA1)
  and `coa-update.sh` / `coa-oneclick.sh` apply it for you. Shipped patches: `creature_display_preset`
  (commit `e8f9afcc5`). The table may stay empty, the mirror-image NPCs then use their default display.
* **Backups & logs:** `acore_world_old` (world before the import, drop it when you are happy),
  `/root/updates_backup_acore_*.sql` (overwritten on every run), `/root/coa-deploy.log`,
  `/root/apply-missing-updates.log`.
* **Disk:** docker's build cache is the largest consumer (it makes rebuilds fast –
  a cached rebuild takes ~1-2 minutes instead of 15-30). Free it with
  `docker builder prune -f` if you need space (the next build will be a full build).
  Container logs are rotated (max. 20 MB x 3 files per service).

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Permission denied (publickey)` | install your SSH key on the server or use password login |
| Build fails: `no matching member function for call to 'NearTeleportTo'` | upstream bug in mod-ascension-compat – the scripts patch it automatically, just re-run `bash coa-oneclick.sh` |
| `Import failed (only 0 items in item_template)` | the base databases did not exist yet – run `cd /opt/azerothcore && docker compose up ac-db-import` once, then import the CoA dump again |
| Build fails: `use of undeclared identifier 'SPELL_EFFECT_NONE'` | run `bash coa-oneclick.sh` again – it patches the line automatically |
| Build fails: `E: Unable to locate package tzdata`, `Some index files failed to download` after ~240 s | the build container cannot reach the apt mirrors (broken IPv6 or a DNS stub) – run `bash fix-build-network.sh` (the deploy scripts call it automatically). Manual fix: pin Docker DNS (`/etc/docker/daemon.json` with `"dns": ["1.1.1.1","8.8.8.8"]`) and, if the host has no working IPv6, disable it (`net.ipv6.conf.all.disable_ipv6 = 1`) |
| `docker compose up` fails on `ac-db-import ... exit 1` | the AC auto-updater tried to write into CoA data – `docker-compose.override.yml` must be present (the script creates it) |
| Client log: "malformed packet" | the client sends plaintext world headers – apply `AscensionCompat.AllowRemoteClients = 1` (script) **and** patch `Extensions.dll` |
| Client cannot enter the realm / crashes | apply `patch_world_endpoint.py` (from the CoA fork repository) to `Extensions.dll` |
| `unrar: Unsupported Method` | the archive is RAR5 / WinRAR 7 – the script installs RARLAB's `unrar`; alternatively provide a `.zip` |
| Port 3306 already in use | `DB_EXTERNAL_PORT=127.0.0.1:13306` (the default) – only needed if a host MySQL/MariaDB runs |
| `coa-update.sh` looks frozen after `Starting worldserver ...` | `docker compose up` is waiting for a dependency (`ac-database` healthy, `ac-db-import` / `ac-client-data-init` completed) or the worldserver is in a crash loop. Current scripts report progress every 15 s, stop after 5 / 7 minutes and print the `ac-*` container states plus the last 30 log lines. Older copies polled the port for 4 minutes without any output. Manual check: `cd /opt/azerothcore && docker compose ps -a`, `docker logs --tail 50 ac-worldserver`, `docker logs --tail 20 ac-client-data-init`, `df -h /` |
| Worldserver restart loop, log: `Could not connect to MySQL database at ac-database: Unknown MySQL server host 'ac-database' (-3)` + `DatabasePool Login NOT opened` | MySQL error `-3` is `CR_UNKNOWN_HOST`, so the container cannot resolve the compose service name – **no database or image damage**. Check the database side with `bash /root/check-db-access.sh` (read-only: databases, MySQL users, a real login over the compose network) and repair the container side with `bash /root/fix-container-dns.sh`: it prints the facts (resolv.conf, networks, DNS aliases, `daemon.json`), probes the name with a throwaway container in the same network and then applies the smallest fix – restart the application containers, or recreate the stack so all containers share one network with a fresh resolver configuration and re-registered DNS aliases. Only if that is not enough does it remove a custom `"dns"` entry from `/etc/docker/daemon.json` (backup kept) and restart the Docker daemon. Data stays in the volumes. |
| Vanity items: "has no AzerothCore item template yet" | CoA world data missing → import the CoA dump (`COA_WORLD_DUMP`) |
| Worldserver log is flooded with `> Config: Missing property <KEY> in config file ... or module config` and `Config::LoadFile: Duplicate key name '<KEY>'` | The core loads `env/dist/etc/modules/<name>.conf` **only** – a module config that was never copied from its `.conf.dist` is not loaded at all, so every config key that module reads logs one warning per read (this server: 92 839 lines in one day from `mod-coa-challenges` and `mod-dynamic-xp`, because older `coa-oneclick.sh` copies activated three hard-coded modules). Neither message is an error – the hardcoded code default was used – but they bury real errors. Fix: `python3 /root/fix-config-warnings.py` – it fetches the module config templates from the image, activates every missing module config, defines the keys the log reported as missing (with the value that was in effect – the warning disappears and nothing else changes), keeps the value that was in effect for keys whose `.dist` default differs, removes the duplicate keys from `worldserver.conf` (the first definition is the one that counts), restarts the worldserver and verifies both message types are gone. Use `--dry-run` to see the report without writing anything. `coa-oneclick.sh` and `coa-update.sh` call it automatically with `--no-restart` before they start the stack (skip with `SKIP_CONFIG_FIX=1`), so a core update that adds a new module can no longer bring the flood back. |

| Bots are missing in the game (no `.playerbots` command) | `bash /root/enable-playerbots.sh --status` shows the three parts: the module, the image and the database. Missing image → `cd /opt/azerothcore && docker compose build`; missing database → `bash /root/enable-playerbots.sh --db`; module not installed → `bash /root/enable-playerbots.sh` |
| Worldserver restart loop, log: `DatabasePool Playerbots NOT opened` | the module is compiled into the image, but `acore_playerbots` does not exist (hand-made `docker compose build` before `enable-playerbots.sh`) → `bash /root/enable-playerbots.sh --db` |
| Log: `> AUTOUPDATER: Automatic database updates are disabled for all databases in the config!` (logger `server.playerbots`) | expected in this deployment: the bot database is maintained from the host (see [Player bots](#player-bots-optional)), the module's own updater has no sources in the runtime image |
| Bots log in very slowly / the server lags with many bots | `PLAYERBOTS_COUNT` is too high for the machine (200 ≈ 3.5 GB, 1000 ≈ 10 GB) and `MapUpdate.Threads` too low – `bash /root/enable-playerbots.sh --config` after a `PLAYERBOTS_COUNT=... PLAYERBOTS_MAP_THREADS=...` change |

---

## Moving CoA content from an existing server

Already running a CoA server elsewhere? Both data sets can be copied over the network.

On the **old** server (serves the files over HTTP while the copy runs):

```bash
# tarball the client data and start a temporary web server
VOL=/var/lib/docker/volumes/azerothcore_ac-client-data/_data
cd "$VOL"
for d in dbc maps vmaps mmaps Cameras; do tar -cf "/root/client-data-$d.tar" "$d"; done
nohup python3 -m http.server 9999 --directory /root >/tmp/http9999.log 2>&1 &
# stop it again when the copy is done:  pkill -f 'http.server 9999'
```

On the **new** server:

```bash
scp transfer-data.sh root@<NEW-SERVER>:/root/
bash /root/transfer-data.sh <OLD-SERVER-IP> 9999
```

`transfer-data.sh` creates the Docker volume if needed, downloads the world dump
(`databases.sql.gz` from `/root`) plus `dbc/maps/vmaps/mmaps/Cameras`, replaces
the directories completely (mixing two data sets breaks the server), fixes the
ownership to uid 1000 and writes the `data-version` marker so the
`ac-client-data-init` container does not download anything again.

Afterwards verify the DBC guard and import the world database:

```bash
python3 check-dbc-rows.py /var/lib/docker/volumes/azerothcore_ac-client-data/_data/dbc
# -> 5/5 required rows present
FORCE_IMPORT=1 COA_WORLD_DUMP=/root/databases.sql.gz bash coa-oneclick.sh
```

The base databases must exist before the CoA world dump is imported. If the
first deployment failed with `Import failed (only 0 items in item_template)`,
run the AzerothCore importer once:

```bash
cd /opt/azerothcore && docker compose up ac-db-import
```

---

## Files

| File | Purpose |
|---|---|
| `coa-oneclick.sh` | full deployment (idempotent, safe to re-run); `WITH_PLAYERBOTS=1` installs the bots as well |
| `coa-update.sh` | update: repo + core fixes + SQL updates + rebuild + restart (keeps the bot module in sync) |
| `enable-playerbots.sh` | optional player bots: module + config + `acore_playerbots` + rebuild (`--prepare` / `--config` / `--db` / `--status`) |
| `apply-missing-updates.sh` | applies repo SQL updates to auth/characters/world – and to playerbots when the module is installed (SHA1 + state exactly like AC) |
| `check-repo-updates.sh` | read-only check: which repo updates are not registered yet (all four databases) |
| `docker-compose.override.yml` | disables the auto-updater for CoA world data + log rotation |
| `fix-build-network.sh` | repairs container DNS/IPv6 so image builds can reach the apt mirrors |
| `fix-container-dns.sh` | repairs container DNS/network when the worldserver cannot resolve `ac-database` (error -3) |
| `check-db-access.sh` | read-only check: databases, MySQL users and a real login over the compose network |
| `patches/db-<db>/*.sql` | project patches for tables the core/module code needs but upstream never shipped as SQL |
| `transfer-data.sh` | copies the CoA world dump + client data from another server |
| `check-dbc-rows.py` | verifies the CoA client DBC set the core requires (5 rows) |
| `fix-config-warnings.py` | fetches the module config templates from the image, activates every module config, defines the keys the log reported as missing, removes duplicate keys, verifies the worldserver log is free of config warnings (runs automatically in `coa-oneclick.sh` / `coa-update.sh`) |
| `README.md` | this guide |

---

## Update semantics (what `coa-update.sh` / `apply-missing-updates.sh` apply)

The CoA world dump is a **snapshot of one point in time**. Afterwards every update that exists in
the repository is reconciled against the databases, so that all commits after that snapshot arrive.

| Repository directory | State | Applied in |
|---|---|---|
| `data/sql/updates/db_<db>` | RELEASED | pass 1 |
| `data/sql/archive/db_<db>` | ARCHIVED | pass 1 |
| `data/sql/custom/db_<db>` | CUSTOM | pass 2 |
| `data/sql/updates/pending_db_<db>` | PENDING | pass 2 |
| `modules/*/data/sql/*<db>*` (recursive: `db-world` as well as mod-playerbots' `data/sql/world`) | MODULE | pass 2 |
| `modules/mod-playerbots/data/sql/playerbots/{updates,archive,custom}` | RELEASED / ARCHIVED / CUSTOM | pass 1 / 2 |
| `patches/db-<db>` (next to the scripts) | MODULE | pass 2 |

`<db>` is `auth`, `characters` or `world` – each is routed to `acore_auth`, `acore_characters` or
`acore_world`. This is exactly what AzerothCore does: the directories come from the table
`updates_include`, and the order mirrors `UpdateFetcher::Update()`
(pass 1 = RELEASED + ARCHIVED, pass 2 = PENDING + CUSTOM + MODULE, each sorted byte-wise by file name).

A file is skipped when it is already registered in that database's `updates` table **with the same
SHA1** (AzerothCore's redundancy check). Consequences:

* a commit adds a core fix → its SQL lands in `data/sql/updates/...` or `data/sql/archive/...` → it
  is applied (registered like AC: name with `.sql`, SHA1 uppercase, matching state)
* rows already containing the change are reported as `[EXISTS]` and registered
* a changed file is re-applied and its hash is updated
* the run is repeatable – a second run reports `applied 0`

### Dry run and order preview (nothing is written)

```bash
DRY=1 bash /root/apply-missing-updates.sh           # lists what WOULD be applied
DEBUG_ORDER=1 DRY=1 bash /root/apply-missing-updates.sh   # + application order + state counts
```

The `updates` tables of **all three** databases are backed up before every run
(`/root/updates_backup_acore_auth.sql`, `..._acore_characters.sql`, `..._acore_world.sql`).

---

## License / legal

These scripts are deployment helpers only (no game content). AzerothCore and the CoA fork are
licensed under **GPL-2.0**. World of Warcraft is a trademark of Blizzard Entertainment – this
project is not affiliated with or endorsed by Blizzard. Use at your own risk and for private
or testing purposes only.