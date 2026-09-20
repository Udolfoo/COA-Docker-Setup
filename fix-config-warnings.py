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
of log lines per day. It is not an error (the code default is used), but it
buries real errors.

Cause 2 - "Duplicate key name": the block appended to the end of
worldserver.conf by older coa-oneclick.sh runs repeats keys that the fork's
.dist already ships. AzerothCore keeps the FIRST definition and ignores the
later ones (Config.cpp: AddKey + the duplicate check), so those lines never did
anything except print a warning on every start.

What this script does (idempotent, safe to run at any time):

  1. activate every <etc>/modules/*.conf.dist that has no matching .conf. For
     keys where the log proves the value in effect differed from the .dist
     value, the value in effect is kept, so behaviour does not change.
  2. drop the duplicate keys from worldserver.conf (the first definition, the
     one that was in effect, stays).
  3. report config keys read by the module code that are still undefined, so a
     future module update cannot reintroduce the noise unnoticed.
  4. restart ac-worldserver, wait for "World Initialized" and check the new log
     for both message types.

Usage:

    sudo python3 fix-config-warnings.py
    sudo python3 fix-config-warnings.py --dry-run      # report only
    sudo python3 fix-config-warnings.py --no-restart   # edit, do not restart

Options: --etc PATH --ac-dir PATH --wait SECONDS
"""
from __future__ import annotations

import argparse
import glob
import os
import re
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


def activate_module_configs(etc, evidence, dry_run):
    """Copy every module .conf.dist without a .conf and keep the values in effect."""
    activated, present = [], []
    for dist in sorted(glob.glob(os.path.join(etc, "modules", "*.conf.dist"))):
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
        path = target if os.path.exists(target) else target + ".dist"
        edits = [(index, key, value, evidence[key]) for index, key, value in cfg_keys(path)
                 if key in evidence and norm(evidence[key]) != norm(value)]
        if not edits:
            continue
        print("      %s: %d key(s) differ, keeping the value in effect:"
              % (os.path.basename(target), len(edits)))
        for _, key, dist_value, effective in edits:
            print("         %-44s .dist %s -> kept %s" % (key, dist_value, effective))
        if dry_run:
            continue
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
    return activated


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


def undefined_module_keys(ac_dir, etc, world_conf):
    """Every config key the module code reads, that no active config defines."""
    active = set()
    candidates = [world_conf, world_conf + ".dist",
                  os.path.join(etc, "authserver.conf")]
    candidates += sorted(glob.glob(os.path.join(etc, "modules", "*.conf")))
    # the .conf.dist files count as well: this script activates every one of
    # them, so their keys are defined once it has run
    candidates += sorted(glob.glob(os.path.join(etc, "modules", "*.conf.dist")))
    for path in candidates:
        if os.path.exists(path):
            active.update(key for _, key, _ in cfg_keys(path))

    code_keys = {}
    for mod_dir in sorted(glob.glob(os.path.join(ac_dir, "modules", "*"))):
        for root, _, files in os.walk(mod_dir):
            for name in files:
                if not name.endswith((".cpp", ".h", ".inc", ".inl")):
                    continue
                path = os.path.join(root, name)
                for number, line in enumerate(read(path), 1):
                    for match in GETOPT.finditer(line):
                        code_keys.setdefault(match.group(1),
                                             "%s:%d" % (os.path.relpath(path, ac_dir), number))
    return code_keys, sorted(key for key in code_keys if key not in active)


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
    evidence, log_lines = collect_evidence(args.log, skip_docker=not has_docker)
    print("      evidence source               : %s"
          % (args.log or ("docker logs %s" % CONTAINER if has_docker else "none")))
    print("      log lines scanned             : %d" % log_lines)
    print("      distinct keys reported missing: %d" % len(evidence))

    activated = activate_module_configs(etc, evidence, args.dry_run)
    if activated:
        ok("%d module config(s) activated" % len(activated))
    dedupe_worldserver_conf(world_conf, args.dry_run)

    code_keys, undefined = undefined_module_keys(args.ac_dir, etc, world_conf)
    print("      config keys read by module code: %d   still undefined: %d"
          % (len(code_keys), len(undefined)))
    for key in undefined:
        print("         %-44s %s" % (key, code_keys[key]))
    if undefined:
        warn("those keys log 'Missing property' as soon as their code path runs - the")
        warn("matching module .conf.dist has to define them. Keys behind a switch that is")
        warn("off (e.g. CoAGameplayTest.* while CoAGameplayTest.Enable = 0) stay silent.")

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

