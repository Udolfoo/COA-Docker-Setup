#!/usr/bin/env python3
"""fix-config-warnings.py - remove the config noise from the worldserver log.

Symptom (docker logs -f ac-worldserver):

    > Config: Missing property CoAChallenges.Enable in config file
      /azerothcore/env/dist/etc/worldserver.conf or module config, add
      "CoAChallenges.Enable = 1" to this file ...
    > Config::LoadFile: Duplicate key name 'BeepAtStart' in config file ...

Cause 1 - "Missing property": AzerothCore loads <etc>/modules/<name>.conf only,
never the .conf.dist template. A module whose .conf was never copied from its
.conf.dist is not configured at all: every key it reads falls back to the
hardcoded code default and logs one warning per read, which is tens of thousands
of log lines per day. Every module the core ships brings its own template
(mod-coa-challenges 50 keys, mod-ethereal-bazaar 18, mod-dynamic-xp 15, ...), and
upstream adds modules over time - a config that was complete last month is not
complete after the next core update. It is not an error (the code default is
used), but it buries real errors.

Cause 2 - "Duplicate key name": the block appended to the end of
worldserver.conf by older coa-oneclick.sh runs repeats keys that the fork's
.dist already ships. AzerothCore keeps the FIRST definition and ignores the
later ones (Config.cpp: AddKey + the duplicate check), so those lines never did
anything except print a warning on every start.

What this script does (idempotent, safe to run at any time):

  0. pull the module config templates from the image (env/ref/etc/modules) into
     <etc>/modules - a module that was added by a core update is only known to
     the image, and the entrypoint copies the templates only when the container
     starts.
  1. activate every <etc>/modules/*.conf.dist that has no matching .conf. For
     keys where the log proves the value in effect differed from the .dist
     value, the value in effect is kept, so behaviour does not change.
  2. drop the duplicate keys from worldserver.conf (the first definition, the
     one that was in effect, stays).
  3. define the keys the log reported as missing (with the value the code used
     until now - so only the warning disappears), and report what is left.
  4. restart ac-worldserver, wait for "World Initialized" and check the new log
     for both message types.

Usage:

    sudo python3 fix-config-warnings.py
    sudo python3 fix-config-warnings.py --dry-run      # report only
    sudo python3 fix-config-warnings.py --no-restart   # edit, do not restart
    sudo python3 fix-config-warnings.py --wait 300     # longer wait for the world load

Options: --etc PATH --ac-dir PATH --wait SECONDS (default 60)
         coa-oneclick.sh / coa-update.sh call this script with --no-restart
         (they restart the stack themselves).

The script writes the configuration BEFORE it waits, so a start that takes
longer than --wait only means "check later" - it never blocks for minutes.
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import shlex
import shutil
import subprocess
import sys
import time

KEYR = re.compile(r'^([A-Za-z][A-Za-z0-9_.\-]*)\s*=(.*)$')
EVIDR = re.compile(r'Config:\s*Missing property (\S+) in config file .*?, add "([^"]*)" to this file')
# two ways the fork reads a config key:  sConfigMgr->GetOption<T>("Key", default)
# and the helper SetConfigValue<T>(enum, "Key", default) used by the CoA modules.
# Both are searched over the whole file, because the call can span several lines.
GETOPT = re.compile(r'GetOption\s*<\s*[^>]*>\s*\(\s*"([^"]+)"', re.S)
SETCFG = re.compile(r'SetConfigValue\s*<\s*[^>]*>\s*\(\s*[^,"()]*\s*,\s*"([^"]+)"', re.S)
# the same two calls, but capturing the default argument (used to detect where a
# module .conf.dist ships a value that differs from the hardcoded code default)
GETOPT_DEFAULT = re.compile(r'GetOption\s*<\s*[^>]*>\s*\(\s*"([^"]+)"\s*,\s*([^,)]*?)\s*[,)]', re.S)
SETCFG_DEFAULT = re.compile(
    r'SetConfigValue\s*<\s*[^>]*>\s*\(\s*[^,"()]*\s*,\s*"([^"]+)"\s*,\s*([^,)]*?)\s*[,)]', re.S)
DEFAULT_LITERAL = re.compile(r'^(?:true|false|-?\d+(?:\.\d+)?f?|"[^"]*"|\'[^\']*\')$', re.I)
# directories whose keys belong to another binary (unit tests, dbimport tool)
NOT_WORLDSERVER_DIRS = ("test", "tests", "tools", "deps", "env", "build", ".git")
DEFAULT_WAIT = 60
MARKERS = ("coa-oneclick.sh Ergaenzungen", "coa-oneclick.sh additions")
MARKER_LINE = "# coa-oneclick.sh additions / Ergaenzungen - keys this fork's .dist does not ship"
CONTAINER = "ac-worldserver"
IMAGE_NAME = "acore/ac-wotlk-worldserver:%s"
DEFAULT_IMAGE_TAG = "coa"
REF_ETC_MODULES = "/azerothcore/env/ref/etc/modules"
MISSING_BLOCK = ("# --- keys that only the code defined so far (values = the code defaults in use) ---")


def info(msg):
    print("[INFO ] %s" % msg)


def ok(msg):
    print("[ OK  ] %s" % msg)


def warn(msg):
    print("[WARN ] %s" % msg)


def step(msg):
    print("\n=== %s ===" % msg)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read().split("\n")


def write(path, lines):
    data = "\n".join(lines)
    if not data.endswith("\n"):
        data += "\n"                      # a missing final newline breaks the next append
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(data)


def cfg_keys(path):
    """[(line index, key, value)] of every uncommented 'Key = value' line."""
    out = []
    for index, line in enumerate(read(path)):
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith("["):
            continue
        match = KEYR.match(stripped)
        if match:
            out.append((index, match.group(1), match.group(2).strip()))
    return out


def norm(value):
    """true/1, false/0 and 1.0f/1.0 have to compare equal."""
    text = value.strip().strip('"').rstrip("fF")
    if text.lower() in ("true", "1"):
        return "1"
    if text.lower() in ("false", "0"):
        return "0"
    return text


def docker(args, timeout=600, cwd=None):
    """Run 'docker <args>'; return (returncode, merged stdout+stderr)."""
    try:
        proc = subprocess.run(["docker"] + args, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=timeout, cwd=cwd)
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, str(exc)
    return proc.returncode, proc.stdout.decode("utf-8", "replace")


def collect_evidence(log_path=None, skip_docker=False):
    """Which value was in effect for every key the running log reported missing?

    Source: a log file (--log) or 'docker logs ac-worldserver'. The 92k warnings
    in the current log are the proof of what the core used for each key, so the
    activated module config can be aligned to it instead of guessing.
    """
    if log_path:
        if not os.path.exists(log_path):
            warn("log file %s not found - no evidence available" % log_path)
            return {}, 0
        with open(log_path, encoding="utf-8", errors="replace") as handle:
            out = handle.read()
    elif skip_docker:
        return {}, 0
    else:
        rc, out = docker(["logs", CONTAINER])
        if rc != 0:
            warn("could not read 'docker logs %s': %s" % (CONTAINER, out.strip()[:120]))
            return {}, 0
    evidence = {}
    for match in EVIDR.finditer(out):
        suggestion = match.group(2)
        equal = suggestion.find("=")
        if equal > 0:
            evidence[suggestion[:equal].strip()] = suggestion[equal + 1:].strip()
    return evidence, len(out.splitlines())


def image_tag(ac_dir):
    """The image tag coa-oneclick.sh wrote into <ac_dir>/.env."""
    env_file = os.path.join(ac_dir, ".env")
    if os.path.exists(env_file):
        for line in read(env_file):
            if line.startswith("DOCKER_IMAGE_TAG="):
                value = line.split("=", 1)[1].strip()
                if value:
                    return value
    return DEFAULT_IMAGE_TAG


def sync_templates_from_image(ac_dir, etc, dry_run):
    """Copy env/ref/etc/modules from the image into <etc>/modules.

    The container entrypoint does that at every start, but only with "cp -n"
    (never overwriting) and only from the image of the running container. A core
    update that adds a module ships the new .conf.dist inside the image, so a
    script that only reads the host directory would not see it - and the module
    would keep logging "Missing property" for every key it reads.
    """
    image = IMAGE_NAME % image_tag(ac_dir)
    rc, out = docker(["image", "inspect", image], timeout=60)
    if rc != 0:
        warn("image %s not found - templates are taken from %s/modules only"
             % (image, etc))
        return []
    rc, listing = docker(["run", "--rm", "--entrypoint", "/bin/ls", image, REF_ETC_MODULES],
                         timeout=120)
    if rc != 0:
        warn("cannot list %s in %s: %s" % (REF_ETC_MODULES, image, listing.strip()[:120]))
        return []

    target_dir = os.path.join(etc, "modules")
    wanted = [name.strip() for name in listing.splitlines() if name.strip().endswith(".conf.dist")]
    missing = [name for name in wanted if not os.path.exists(os.path.join(target_dir, name))]
    print("      templates in %s: %d   missing in %s: %d"
          % (image, len(wanted), target_dir, len(missing)))
    if not missing:
        return []
    for name in sorted(missing):
        print("      FETCH    : %s" % name)
    if dry_run:
        return missing

    os.makedirs(target_dir, exist_ok=True)
    # tar stream into the config directory; --skip-old-files behaves like the
    # entrypoint's "cp -n" (existing files are never overwritten)
    command = ("docker run --rm --entrypoint tar %s -cf - -C /azerothcore/env/ref/etc modules "
               "| tar -xf - -C %s --skip-old-files" % (shlex.quote(image), shlex.quote(etc)))
    try:
        proc = subprocess.run(["/bin/sh", "-c", command], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=300)
    except (OSError, subprocess.SubprocessError) as exc:
        warn("extracting the module templates failed: %s" % exc)
        return []
    if proc.returncode != 0:
        warn("extracting the module templates failed (exit %d): %s"
             % (proc.returncode, proc.stdout.decode("utf-8", "replace").strip()[-200:]))
        return []

    still_missing = [name for name in missing if not os.path.exists(os.path.join(target_dir, name))]
    if still_missing:
        warn("could not fetch: %s" % ", ".join(still_missing))
    fetched = [name for name in missing if name not in still_missing]
    if fetched:
        ok("%d module config template(s) fetched from the image" % len(fetched))
    return fetched


def activate_module_configs(etc, evidence, dry_run, ac_dir=None, keep_code_defaults=False):
    """Copy every module .conf.dist without a .conf and keep the values in effect."""
    dists = sorted(glob.glob(os.path.join(etc, "modules", "*.conf.dist")))
    if not dists:
        warn("no *.conf.dist in %s/modules - nothing to activate. On a normal run the"
             % etc)
        warn("templates are fetched from the image (needs docker + the worldserver image).")
        return []
    activated, present = [], []
    # the hardcoded defaults are needed to show where a .conf.dist changes behaviour
    code_defaults = scan_code_defaults(ac_dir) if ac_dir else None
    if code_defaults is not None:
        print("      code defaults known for %d key(s) (literal defaults only)"
              % len(code_defaults))
    for dist in dists:
        target = dist[:-5]
        if os.path.exists(target):
            present.append(os.path.basename(target))
            continue
        print("      ACTIVATE : %-26s (only %s existed)"
              % (os.path.basename(target), os.path.basename(dist)))
        activated.append(target)
        if not dry_run:
            shutil.copyfile(dist, target)
            os.chmod(target, 0o644)
    if present:
        print("      loaded   : %s" % ", ".join(present))
    if not activated:
        print("      every module .conf.dist already has an active .conf")

    for target in activated:
        apply_evidence_to_conf(target, evidence, dry_run, code_defaults, keep_code_defaults)
    return activated


def apply_evidence_to_conf(target, evidence, dry_run, code_defaults=None,
                           keep_code_defaults=False):
    """Align a freshly activated config with what was in effect before.

    - a key the log reported keeps the value that was in effect (the warning
      disappears, nothing else changes),
    - a key whose .conf.dist value differs from the hardcoded code default is
      reported (activating the config would change behaviour) and, with
      --keep-code-defaults, kept at the code default as well,
    - every other key keeps the .conf.dist value, which is the upstream default.
    """
    path = target if os.path.exists(target) else target + ".dist"
    if not os.path.exists(path):
        return 0

    writes = {}       # line index -> (key, value, reason)
    reported = []
    for index, key, value in cfg_keys(path):
        if evidence and key in evidence and norm(evidence[key]) != norm(value):
            writes[index] = (key, evidence[key], "kept at the value that was in effect")
        elif code_defaults is not None and norm(value) != code_defaults.get(key):
            if key in code_defaults:
                reported.append((key, value, code_defaults[key]))
                if keep_code_defaults:
                    writes[index] = (key, code_defaults[key], "kept at the code default")

    if reported:
        print("      %s: %d key(s) where the template ships another value than the"
              % (os.path.basename(target), len(reported)))
        print("      %s  hardcoded code default - that IS the upstream default:" % "")
        for key, value, default in reported:
            mark = "-> keep %s" % default if keep_code_defaults else ""
            print("         %-44s .dist %s, code default %s  %s" % (key, value, default, mark))
    if writes:
        print("      %s: %d key(s) stay at the value they had until now:"
              % (os.path.basename(target), len(writes)))
        for key, value, reason in writes.values():
            print("         %-44s -> %s  (%s)" % (key, value, reason))
    if dry_run or not writes:
        return len(writes)

    out = []
    for index, line in enumerate(read(path)):
        if index in writes:
            key, value, reason = writes[index]
            out.append("")
            out.append("# %s - this module config did not exist before, so the key" % reason)
            out.append("# kept a different value than the one in the .conf.dist")
            out.append("%s = %s" % (key, value))
        else:
            out.append(line)
    write(path, out)
    return len(writes)


def dedupe_worldserver_conf(world_conf, dry_run):
    """A duplicate key is only reported - the first definition wins, the rest is dead."""
    lines = read(world_conf)
    occurrences = {}
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith("["):
            continue
        match = KEYR.match(stripped)
        if match:
            occurrences.setdefault(match.group(1), []).append(index)

    duplicates = {key: idx for key, idx in occurrences.items() if len(idx) > 1}
    print("      duplicate keys in worldserver.conf: %d" % len(duplicates))
    drop = set()
    for key, idx in sorted(duplicates.items()):
        print("         %-44s keep line %d, drop line(s) %s"
              % (key, idx[0] + 1, ", ".join(str(value + 1) for value in idx[1:])))
        drop.update(idx[1:])
    if drop and not dry_run:
        write(world_conf, [line for index, line in enumerate(lines) if index not in drop])

    # coa-oneclick.sh only runs its append step when it finds its own marker.
    # The German and the English variant look for different strings, so both go
    # into one line - otherwise a later run appends the whole block again.
    lines = read(world_conf)
    for index, line in enumerate(lines):
        if any(marker in line for marker in MARKERS):
            lines[index] = MARKER_LINE
    if not dry_run:
        write(world_conf, lines)
    return len(duplicates)


def switch_off(key, active_values):
    """True when the switch that gates this key is explicitly off.

    Example: CoAGameplayTest.* is only read while CoAGameplayTest.Enable = 1, so
    the keys cannot produce "Missing property" lines while it is 0.
    """
    segment = key.split(".")[0]
    for candidate in (segment + ".Enable", segment + ".Enabled"):
        value = active_values.get(candidate)
        if value is not None:
            return norm(value) == "0"
    return False


def scan_code_keys(ac_dir):
    """{key: (owner, "relative/path:line")} - owner is a module dir or 'core'."""
    code = {}
    roots = []
    core_src = os.path.join(ac_dir, "src")
    if os.path.isdir(core_src):
        roots.append((core_src, "core"))
    for mod_dir in sorted(glob.glob(os.path.join(ac_dir, "modules", "*"))):
        src = os.path.join(mod_dir, "src")
        if os.path.isdir(src):
            roots.append((src, os.path.basename(mod_dir)))
    for root_dir, owner in roots:
        for root, dirs, files in os.walk(root_dir):
            # unit tests and the dbimport tool read their own keys - they never
            # run inside the worldserver, so they must not show up as "missing"
            dirs[:] = [d for d in dirs if d not in NOT_WORLDSERVER_DIRS]
            for name in files:
                if not name.endswith((".cpp", ".h", ".inc", ".inl")):
                    continue
                path = os.path.join(root, name)
                text = "\n".join(read(path))
                for pattern in (GETOPT, SETCFG):
                    for match in pattern.finditer(text):
                        line = text.count("\n", 0, match.start()) + 1
                        code.setdefault(match.group(1),
                                        (owner, "%s:%d" % (os.path.relpath(path, ac_dir), line)))
    return code


def scan_code_defaults(ac_dir):
    """{key: default} for keys whose hardcoded default is a plain literal.

    Expressions (`MAX_ACTION_BUTTONS - 1`), constants and hex are skipped: they
    cannot be compared with a config value. What is left is exactly the set of
    keys where activating a module config could change the running behaviour
    (the code default was in effect until now).
    """
    defaults = {}
    roots = []
    core_src = os.path.join(ac_dir, "src")
    if os.path.isdir(core_src):
        roots.append(core_src)
    roots += sorted(glob.glob(os.path.join(ac_dir, "modules", "*", "src")))
    for root_dir in roots:
        for root, dirs, files in os.walk(root_dir):
            dirs[:] = [d for d in dirs if d not in NOT_WORLDSERVER_DIRS]
            for name in files:
                if not name.endswith((".cpp", ".h", ".inc", ".inl")):
                    continue
                text = "\n".join(read(os.path.join(root, name)))
                for pattern in (GETOPT_DEFAULT, SETCFG_DEFAULT):
                    for match in pattern.finditer(text):
                        raw = re.split(r"\s+#", match.group(2), maxsplit=1)[0].strip()
                        if DEFAULT_LITERAL.match(raw):
                            defaults.setdefault(match.group(1), norm(raw))
    return defaults


def defined_keys(path):
    """Keys an existing config file (or .conf.dist) defines."""
    if not os.path.exists(path):
        return set()
    return {key for _, key, _ in cfg_keys(path)}


def shared_prefix(key, keys):
    """Length of the longest common leading dot-segment run (0 = no overlap)."""
    parts = key.split(".")
    best = 0
    for other in keys:
        count = 0
        for a, b in zip(parts, other.split(".")):
            if a != b:
                break
            count += 1
        best = max(best, count)
    return best


def target_conf(ac_dir, etc, world_conf, key, owner):
    """(target, template) of the config file that should define this key.

    A key the code reads literally is written to the config of its owner (the
    module that reads it, or worldserver.conf for the core). A key the code
    builds at runtime (Acore::StringFormat("EtherealBazaar.Tokens.{}.Min", ...))
    has no owner, so the config that already defines the closest key wins -
    which is also how a module with several .conf.dist files is resolved
    (mod-ascension-compat: coa_bugreport.conf vs mod_ascension_compat.conf).
    """
    if owner == "core":
        return world_conf, None
    candidates = []
    if owner:
        for dist in sorted(glob.glob(os.path.join(ac_dir, "modules", owner, "conf", "*.conf.dist"))):
            candidates.append((os.path.join(etc, "modules", os.path.basename(dist)[:-5]), dist))
        if not candidates:
            return None, None
    else:
        candidates.append((world_conf, None))
        for dist in sorted(glob.glob(os.path.join(etc, "modules", "*.conf.dist"))):
            candidates.append((dist[:-5], dist))

    best, best_score, best_dist = None, 0, None
    for target, dist in candidates:
        source = target if os.path.exists(target) else (dist or target)
        score = shared_prefix(key, defined_keys(source))
        if best is None or score > best_score:
            best, best_score, best_dist = target, score, dist
    if best_score == 0 and not (owner and len(candidates) == 1):
        # no overlap with what any config already defines: too risky to guess
        return None, None
    return best, best_dist


def activate_from_dist(target, dist, evidence, dry_run, code_defaults=None,
                       keep_code_defaults=False):
    """Create <target> from its template and keep the values that were in effect."""
    if os.path.exists(target):
        return True
    if not dist or not os.path.exists(dist):
        return False
    print("      ACTIVATE : %-26s (from %s)"
          % (os.path.basename(target), os.path.relpath(dist)))
    if dry_run:
        return True
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copyfile(dist, target)
    os.chmod(target, 0o644)
    apply_evidence_to_conf(target, evidence, dry_run, code_defaults, keep_code_defaults)
    return True


def write_missing_keys(ac_dir, etc, world_conf, evidence, dry_run, keep_code_defaults=False):
    """Define the keys the log complains about, with the value that is in effect.

    The log line carries the value the code used ("... add \"KEY = VALUE\" to this
    file"), so writing it changes nothing except that the warning disappears.
    A key read by exactly one module goes into that module's config; a core key
    goes into one marked block at the end of worldserver.conf (the fork's
    worldserver.conf.dist is never loaded, so there is no duplicate).
    """
    if not evidence:
        return 0
    code = scan_code_keys(ac_dir)
    code_defaults = scan_code_defaults(ac_dir)
    targets = {}
    unfixable = []
    for key in sorted(evidence):
        owner = code.get(key, (None, None))[0]
        target, dist = target_conf(ac_dir, etc, world_conf, key, owner)
        if target is None:
            unfixable.append((key, "no config of this fork defines a related key"))
            continue
        if not activate_from_dist(target, dist, evidence, dry_run, code_defaults,
                                  keep_code_defaults):
            unfixable.append((key, "template %s is not available" % (dist or target)))
            continue
        targets.setdefault(target, []).append((key, evidence[key]))

    written = 0
    for path, pairs in sorted(targets.items()):
        existing = {key for _, key, _ in cfg_keys(path)} if os.path.exists(path) else set()
        todo = [(key, value) for key, value in pairs if key not in existing]
        if not todo:
            continue
        for key, value in todo:
            print("      DEFINE   : %-44s %s  (%s)" % (key, value, os.path.basename(path)))
        if dry_run:
            written += len(todo)
            continue
        lines = read(path) if os.path.exists(path) else []
        while lines and not lines[-1].strip():
            lines.pop()
        lines.append("")
        if path == world_conf:
            lines.append(MISSING_BLOCK)
        lines.append("# added by fix-config-warnings.py: the key logged 'Config: Missing property',")
        lines.append("# the value is the one the code used until now (no behaviour change)")
        for key, value in todo:
            lines.append("%s = %s" % (key, value))
        write(path, lines)
        written += len(todo)

    for key, reason in unfixable:
        warn("%s stays undefined (%s)" % (key, reason))
    return written


def undefined_module_keys(ac_dir, etc, world_conf):
    """Every config key the module code reads, that no active config defines."""
    active = set()
    active_values = {}
    candidates = [world_conf, world_conf + ".dist",
                  os.path.join(etc, "authserver.conf")]
    candidates += sorted(glob.glob(os.path.join(etc, "modules", "*.conf")))
    # the .conf.dist files count as well: this script activates every one of
    # them, so their keys are defined once it has run
    candidates += sorted(glob.glob(os.path.join(etc, "modules", "*.conf.dist")))
    for path in candidates:
        if os.path.exists(path):
            for _, key, value in cfg_keys(path):
                active.add(key)
                active_values.setdefault(key, value)

    code_keys = {key: at for key, (_, at) in scan_code_keys(ac_dir).items()}
    undefined = sorted(key for key in code_keys if key not in active)
    silent = [key for key in undefined if switch_off(key, active_values)]
    return code_keys, undefined, silent


def fix_ownership(paths):
    """The container runs as uid/gid 1000 - a config owned by root is not writable."""
    if not hasattr(os, "geteuid") or os.geteuid() != 0:
        return 0
    count = 0
    for path in paths:
        try:
            os.chown(path, 1000, 1000)
            count += 1
        except OSError as exc:
            warn("chown 1000:1000 %s failed: %s" % (path, exc))
    return count


def container_state():
    """State of the worldserver container (docker inspect)."""
    rc, out = docker(["inspect", "-f", "{{.State.Status}}", CONTAINER], timeout=30)
    return out.strip() or ("unknown" if rc != 0 else "missing")


def container_restarts():
    """How often the worldserver container was restarted (0 when unknown)."""
    rc, out = docker(["inspect", "-f", "{{.RestartCount}}", CONTAINER], timeout=30)
    try:
        return int(out.strip())
    except ValueError:
        return 0


def restart_and_verify(ac_dir, wait_seconds):
    """Restart the worldserver and prove that both message types are gone.

    The wait for "World Initialized" is deliberately short and shows progress:
    the config changes are already written, so a worldserver that simply needs
    longer to load its world must not block the script. What counts is the new
    log - it is checked even when the load is still running.
    """
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
    info("restarting %s ..." % CONTAINER)
    rc, out = docker(["compose", "restart", CONTAINER], cwd=ac_dir)
    if rc != 0:
        warn("'docker compose restart %s' returned %d: %s"
             % (CONTAINER, rc, out.strip()[:200]))

    info("waiting for the worldserver: max. %ds (progress every 15s, Ctrl-C is safe - "
         "the config is already written)" % wait_seconds)
    ready = False
    waited = 0
    last_lines = ""
    while waited < wait_seconds:
        _, last_lines = docker(["logs", "--since", stamp, "--tail", "30", CONTAINER], timeout=60)
        if "World Initialized" in last_lines:
            ready = True
            break
        if waited % 15 == 0:
            state = container_state()
            tail = [l for l in last_lines.splitlines() if l.strip()]
            print("      ... %ss (state=%s) last: %s"
                  % (waited, state, tail[-1][-90:] if tail else "(no new output yet)"))
        time.sleep(3)
        waited += 3

    if ready:
        ok("worldserver is up ('World Initialized' after %ds)" % waited)
    else:
        state = container_state()
        restarts = container_restarts()
        tail = [l for l in last_lines.splitlines() if l.strip()]
        warn("the worldserver is still loading after %ds (state=%s, restarts=%d) - the config"
             % (wait_seconds, state, restarts))
        warn("changes are already applied; this is only the check: docker logs -f %s" % CONTAINER)
        if state in ("exited", "dead") or restarts > 2:
            warn("state '%s' with %d restarts means it did NOT come up - last lines:"
                 % (state, restarts))
            _, crash = docker(["logs", "--tail", "20", CONTAINER], timeout=60)
            for line in crash.splitlines()[-20:]:
                print("      %s" % line)
            warn("the config it just got is the new part - if it does not start, send the lines above")
            return 1
        if tail:
            print("      last line: %s" % tail[-1][-120:])

    _, new_log = docker(["logs", "--since", stamp, CONTAINER])
    _, whole_log = docker(["logs", CONTAINER])
    clean = re.sub(r"\x1b\[[0-9;]*m", "", new_log)
    every = re.sub(r"\x1b\[[0-9;]*m", "", whole_log)
    missing_hits = clean.count("Missing property")
    duplicate_hits = clean.count("Duplicate key name")
    old_hits = sum(every.count(msg) for msg in ("Missing property", "Duplicate key name"))

    print()
    print("missing-property lines in the whole log: %d" % old_hits)
    print("missing-property lines in the new log  : %d" % missing_hits)
    print("duplicate-key lines in the new log     : %d" % duplicate_hits)
    print()
    configs = [line.lstrip("> ").strip() for line in clean.splitlines()
               if re.search(r">\s+\S+\.conf\s*$", line)]
    if configs:
        print("module configs the worldserver uses:")
        for name in configs:
            print("      %s" % name)

    print()
    if missing_hits == 0 and duplicate_hits == 0:
        if ready:
            ok("no config warnings in the new log")
        else:
            ok("no config warnings in the new log so far (the world is still loading)")
        info("the old lines stay until the container log rotates (logging max-size/max-file)")
        return 0
    warn("the new log still reports config warnings - please send:")
    warn("  docker logs --since '%s' %s 2>&1 | grep -e 'Missing property' "
         "-e 'Duplicate key name' | head -20" % (stamp, CONTAINER))
    return 1


def main():
    parser = argparse.ArgumentParser(
        description="Remove 'Config: Missing property' / 'Duplicate key name' from the worldserver log.")
    parser.add_argument("--ac-dir", default="/opt/azerothcore", help="deployment directory")
    parser.add_argument("--etc", default=None, help="default: <ac-dir>/env/dist/etc")
    parser.add_argument("--wait", type=int, default=DEFAULT_WAIT,
                        help="seconds to wait for 'World Initialized' (default %d). The config is "
                             "written BEFORE the wait, so the script does not block on a worldserver "
                             "that needs longer to load - it reports it and checks the new log anyway."
                             % DEFAULT_WAIT)
    parser.add_argument("--log", default=None, help="use this log file as evidence instead of 'docker logs'")
    parser.add_argument("--dry-run", action="store_true", help="report only, change nothing")
    parser.add_argument("--no-restart", action="store_true", help="edit the configs, do not restart")
    parser.add_argument("--keep-code-defaults", action="store_true",
                        help="when a module config is activated, keep the hardcoded code default for "
                             "keys where the .conf.dist ships a different value (default: use the "
                             ".conf.dist value of the fork). Both cases are reported either way.")
    args = parser.parse_args()

    etc = args.etc or os.path.join(args.ac_dir, "env", "dist", "etc")
    world_conf = os.path.join(etc, "worldserver.conf")
    if not os.path.exists(world_conf):
        warn("no config at %s (wrong --ac-dir / --etc?)" % world_conf)
        return 1
    if args.dry_run:
        info("DRY-RUN: nothing will be changed")

    step("1/2  Config files")
    has_docker = shutil.which("docker") is not None
    if not has_docker and not args.log:
        warn("docker not found - the log cannot be read, so only the .dist values are used")
    if has_docker:
        sync_templates_from_image(args.ac_dir, etc, args.dry_run)
    else:
        warn("docker not found - module templates are not fetched from the image")
    evidence, log_lines = collect_evidence(args.log, skip_docker=not has_docker)
    print("      evidence source               : %s"
          % (args.log or ("docker logs %s" % CONTAINER if has_docker else "none")))
    print("      log lines scanned             : %d" % log_lines)
    print("      distinct keys reported missing: %d" % len(evidence))

    activated = activate_module_configs(etc, evidence, args.dry_run, args.ac_dir,
                                        args.keep_code_defaults)
    if activated:
        ok("%d module config(s) activated" % len(activated))
    written = write_missing_keys(args.ac_dir, etc, world_conf, evidence, args.dry_run,
                                 args.keep_code_defaults)
    if written:
        ok("%d key(s) that logged 'Missing property' are defined now" % written)
    dedupe_worldserver_conf(world_conf, args.dry_run)

    code_keys, undefined, silent = undefined_module_keys(args.ac_dir, etc, world_conf)
    loud = [key for key in undefined if key not in silent]
    print("      config keys read by module code: %d   undefined: %d (%d behind a switch that is off)"
          % (len(code_keys), len(undefined), len(silent)))
    for key in loud:
        print("         %-44s %s" % (key, code_keys[key]))
    for key in silent:
        print("         %-44s %s   (switch off - stays silent)" % (key, code_keys[key]))
    if loud:
        warn("those keys log 'Missing property' as soon as their code path runs - the")
        warn("matching module .conf.dist has to define them.")
    elif silent:
        info("%d key(s) are only read behind a switch that is off "
             "(e.g. CoAGameplayTest.Enable = 0) and cannot write log lines" % len(silent))

    if args.dry_run:
        info("DRY-RUN finished - no file was changed")
        return 0

    changed = fix_ownership([world_conf] + sorted(glob.glob(os.path.join(etc, "modules", "*.conf"))))
    if changed:
        ok("%d config file(s) now owned by 1000:1000 (the container user)" % changed)

    if args.no_restart:
        warn("--no-restart: the worldserver keeps running with the old config")
        return 0
    step("2/2  Restart + verification")
    if not has_docker:
        warn("docker not found - the restart and the verification were skipped")
        return 0
    return restart_and_verify(args.ac_dir, args.wait)


if __name__ == "__main__":
    sys.exit(main())

