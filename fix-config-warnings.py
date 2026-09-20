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

Options: --etc PATH --ac-dir PATH --wait SECONDS
         coa-oneclick.sh / coa-update.sh call this script with --no-restart
         (they restart the stack themselves).
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
GETOPT = re.compile(r'GetOption\s*(?:<\s*[^>]*>)?\s*\(\s*"([^"]+)"\s*,\s*([^,\)]*)')
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


def activate_module_configs(etc, evidence, dry_run):
    """Copy every module .conf.dist without a .conf and keep the values in effect."""
    dists = sorted(glob.glob(os.path.join(etc, "modules", "*.conf.dist")))
    if not dists:
        warn("no *.conf.dist in %s/modules - nothing to activate. On a normal run the"
             % etc)
        warn("templates are fetched from the image (needs docker + the worldserver image).")
        return []
    activated, present = [], []
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
        apply_evidence_to_conf(target, evidence, dry_run)
    return activated


def apply_evidence_to_conf(target, evidence, dry_run):
    """Keep the value that was in effect for keys whose .dist default differs."""
    if not evidence:
        return 0
    path = target if os.path.exists(target) else target + ".dist"
    edits = [(index, key, value, evidence[key]) for index, key, value in cfg_keys(path)
             if key in evidence and norm(evidence[key]) != norm(value)]
    if not edits:
        return 0
    print("      %s: %d key(s) differ, keeping the value in effect:"
          % (os.path.basename(target), len(edits)))
    for _, key, dist_value, effective in edits:
        print("         %-44s .dist %s -> kept %s" % (key, dist_value, effective))
    if dry_run:
        return len(edits)
    by_index = {index: (key, dist_value, effective)
                for index, key, dist_value, effective in edits}
    out = []
    for index, line in enumerate(read(path)):
        if index in by_index:
            key, dist_value, effective = by_index[index]
            out.append("")
            out.append("# kept at the value that was in effect before this module config")
            out.append("# existed (the hardcoded code default). This fork's .dist "
                       "default is: %s" % dist_value)
            out.append("%s = %s" % (key, effective))
        else:
            out.append(line)
    write(path, out)
    return len(edits)


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
        for root, _, files in os.walk(root_dir):
            for name in files:
                if not name.endswith((".cpp", ".h", ".inc", ".inl")):
                    continue
                path = os.path.join(root, name)
                for number, line in enumerate(read(path), 1):
                    for match in GETOPT.finditer(line):
                        code.setdefault(match.group(1),
                                        (owner, "%s:%d" % (os.path.relpath(path, ac_dir), number)))
    return code


def module_conf_for(ac_dir, module):
    """Name of the active module conf, when the module has exactly one."""
    dists = sorted(glob.glob(os.path.join(ac_dir, "modules", module, "conf", "*.conf.dist")))
    if len(dists) != 1:
        return None
    return os.path.basename(dists[0])[:-5]          # drop ".dist"


def ensure_module_conf(ac_dir, etc, module, conf, dry_run, evidence):
    """Activate <etc>/modules/<conf> from the module's own template when missing.

    Needed here because a key can be written into a module config that does not
    exist yet (e.g. when the docker-based template step could not run): starting
    from the module's .conf.dist keeps all the other keys defined - with the
    values that were in effect before, exactly like the activation step.
    """
    target = os.path.join(etc, "modules", conf)
    if os.path.exists(target):
        return target
    dist = os.path.join(ac_dir, "modules", module, "conf", conf + ".dist")
    if not os.path.exists(dist):
        return None
    print("      ACTIVATE : %-26s (from modules/%s/conf)" % (conf, module))
    if dry_run:
        return target
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copyfile(dist, target)
    os.chmod(target, 0o644)
    apply_evidence_to_conf(target, evidence, dry_run)
    return target


def write_missing_keys(ac_dir, etc, world_conf, evidence, dry_run):
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
    targets = {}
    unfixable = []
    for key in sorted(evidence):
        owner = code.get(key, (None, None))[0]
        if owner is None:
            unfixable.append((key, "the code builds the key at runtime"))
            continue
        if owner == "core":
            targets.setdefault(world_conf, []).append((key, evidence[key]))
            continue
        conf = module_conf_for(ac_dir, owner)
        if not conf:
            unfixable.append((key, "owner %s has no unique .conf.dist" % owner))
            continue
        target = ensure_module_conf(ac_dir, etc, owner, conf, dry_run, evidence)
        if target is None:
            unfixable.append((key, "no template modules/%s/conf/%s.dist" % (owner, conf)))
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


def restart_and_verify(ac_dir, wait_seconds):
    """Restart the worldserver and prove that both message types are gone."""
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
    info("restarting %s ..." % CONTAINER)
    rc, out = docker(["compose", "restart", CONTAINER], cwd=ac_dir)
    if rc != 0:
        warn("'docker compose restart %s' returned %d: %s"
             % (CONTAINER, rc, out.strip()[:200]))

    info("waiting for the worldserver (max. %ds) ..." % wait_seconds)
    ready = False
    deadline = time.time() + wait_seconds
    while time.time() < deadline:
        _, tail = docker(["logs", "--tail", "300", CONTAINER], timeout=60)
        if "World Initialized" in tail:
            ready = True
            break
        time.sleep(5)
    if ready:
        ok("worldserver is up ('World Initialized')")
    else:
        warn("the start was not confirmed within %ds - check: docker logs -f %s"
             % (wait_seconds, CONTAINER))

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
    print("module configs the worldserver uses:")
    for line in clean.splitlines():
        if re.search(r">\s+\S+\.conf\s*$", line):
            print("      %s" % line.lstrip("> ").strip())

    print()
    if ready and missing_hits == 0 and duplicate_hits == 0:
        ok("no config warnings in the new log")
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
    parser.add_argument("--wait", type=int, default=420, help="seconds to wait for 'World Initialized'")
    parser.add_argument("--log", default=None, help="use this log file as evidence instead of 'docker logs'")
    parser.add_argument("--dry-run", action="store_true", help="report only, change nothing")
    parser.add_argument("--no-restart", action="store_true", help="edit the configs, do not restart")
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

    activated = activate_module_configs(etc, evidence, args.dry_run)
    if activated:
        ok("%d module config(s) activated" % len(activated))
    written = write_missing_keys(args.ac_dir, etc, world_conf, evidence, args.dry_run)
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

