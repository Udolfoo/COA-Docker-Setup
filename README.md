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
    check-repo-updates.sh docker-compose.override.yml root@<SERVER-IP>:/root/

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
| Client data | Extracts `.rar`/`.zip`/folder (`CLIENT_DATA`) or lets the container download v20.0 |
| Images | `docker compose build` (skipped when images already exist) |
| Database | Imports **only the `acore_world` part** of a CoA dump (auth/characters stay untouched), keeps a rollback copy as `acore_world_old`, disables the AzerothCore auto-updater |
| Updates | Applies all missing repo SQL fixes for **auth, characters and world** |
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
4. Frees old images (`docker image prune -f`), restarts the stack, prints a status report

If nothing changed, the run finishes in seconds and only re-checks the database.

`apply-missing-updates.sh` registers updates exactly like AzerothCore does
(`name` = file name with `.sql`, `hash` = SHA1 in uppercase, `state` from the source folder:
`PENDING` / `ARCHIVED` / `MODULE`). Files whose content changed are re-applied and re-hashed.
Duplicate-key errors simply mean "content already present" and are registered as applied.
Manual helper scripts under `data/sql/manual/` are never touched.

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
| Build fails: `use of undeclared identifier 'SPELL_EFFECT_NONE'` | run `bash coa-oneclick.sh` again – it patches the line automatically |
| `docker compose up` fails on `ac-db-import ... exit 1` | the AC auto-updater tried to write into CoA data – `docker-compose.override.yml` must be present (the script creates it) |
| Client log: "malformed packet" | the client sends plaintext world headers – apply `AscensionCompat.AllowRemoteClients = 1` (script) **and** patch `Extensions.dll` |
| Client cannot enter the realm / crashes | apply `patch_world_endpoint.py` (from the CoA fork repository) to `Extensions.dll` |
| `unrar: Unsupported Method` | the archive is RAR5 / WinRAR 7 – the script installs RARLAB's `unrar`; alternatively provide a `.zip` |
| Port 3306 already in use | `DB_EXTERNAL_PORT=127.0.0.1:13306` (the default) – only needed if a host MySQL/MariaDB runs |
| Vanity items: "has no AzerothCore item template yet" | CoA world data missing → import the CoA dump (`COA_WORLD_DUMP`) |

---

## Files

| File | Purpose |
|---|---|
| `coa-oneclick.sh` | full deployment (idempotent, safe to re-run) |
| `coa-update.sh` | update: repo + core fixes + SQL updates + rebuild + restart |
| `apply-missing-updates.sh` | applies repo SQL updates to auth/characters/world (SHA1 + state exactly like AC) |
| `check-repo-updates.sh` | read-only check: which repo updates are not registered yet |
| `docker-compose.override.yml` | disables the auto-updater for CoA world data + log rotation |
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
| `modules/*/data/sql/db-<db>` | MODULE | pass 2 |

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