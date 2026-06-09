#!/usr/bin/env python3
"""
clh_merge.py - Merge CrowLogsHelper SavedVariables with WoWCombatLog.txt.

For each recorded boss pull it joins the addon's loadout snapshots (gear / trinkets
/ talents / spec per player GUID) with the damage done by each player in the combat
log over that pull's time window, and prints a per-pull report.

The join is by TIME WINDOW (pull startEpoch..endEpoch vs each log line's timestamp),
so it works even on cores that don't emit ENCOUNTER_START/END lines. Damage source
GUIDs in the log match the GUIDs UnitGUID() stored in the addon directly.

Usage:
    python clh_merge.py --sv  path/to/CrowLogsHelper.lua \
                        --log path/to/WoWCombatLog.txt \
                        [-o report.json] [--year 2026]

No third-party dependencies.
"""

import argparse
import json
import sys
import time
import calendar
from datetime import datetime

# ----------------------------------------------------------------------------
# Minimal Lua SavedVariables parser (handles the subset WoW writes).
# ----------------------------------------------------------------------------


class LuaParser:
    def __init__(self, text):
        self.s = text
        self.i = 0
        self.n = len(text)

    def error(self, msg):
        raise ValueError(f"Lua parse error at offset {self.i}: {msg}")

    def skip_ws(self):
        s, n = self.s, self.n
        while self.i < n:
            c = s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif c == "-" and self.i + 1 < n and s[self.i + 1] == "-":
                # line comment
                self.i += 2
                while self.i < n and s[self.i] != "\n":
                    self.i += 1
            else:
                break

    def parse_globals(self):
        """Parse top-level `Name = value` assignments into a dict."""
        result = {}
        self.skip_ws()
        while self.i < self.n:
            name = self.parse_identifier()
            self.skip_ws()
            if self.i >= self.n or self.s[self.i] != "=":
                break
            self.i += 1  # '='
            self.skip_ws()
            result[name] = self.parse_value()
            self.skip_ws()
        return result

    def parse_identifier(self):
        self.skip_ws()
        start = self.i
        s = self.s
        while self.i < self.n and (s[self.i].isalnum() or s[self.i] == "_"):
            self.i += 1
        if self.i == start:
            self.error("expected identifier")
        return s[start:self.i]

    def parse_value(self):
        self.skip_ws()
        c = self.s[self.i]
        if c == "{":
            return self.parse_table()
        if c == '"':
            return self.parse_string()
        if c == "[" and self.i + 1 < self.n and self.s[self.i + 1] == "[":
            return self.parse_long_string()
        return self.parse_scalar()

    def parse_table(self):
        self.i += 1  # '{'
        result = {}
        array_index = 1
        self.skip_ws()
        while self.i < self.n and self.s[self.i] != "}":
            key = None
            if self.s[self.i] == "[":
                # [key] = value
                self.i += 1
                self.skip_ws()
                if self.s[self.i] == '"':
                    key = self.parse_string()
                else:
                    key = self.parse_scalar()
                self.skip_ws()
                if self.s[self.i] != "]":
                    self.error("expected ']'")
                self.i += 1
                self.skip_ws()
                if self.s[self.i] != "=":
                    self.error("expected '=' after [key]")
                self.i += 1
                value = self.parse_value()
            else:
                # could be `name = value` or a bare array value
                save = self.i
                ident = self._try_identifier()
                self.skip_ws()
                if ident is not None and self.i < self.n and self.s[self.i] == "=":
                    self.i += 1
                    key = ident
                    value = self.parse_value()
                else:
                    self.i = save
                    key = array_index
                    array_index += 1
                    value = self.parse_value()

            result[key] = value
            self.skip_ws()
            if self.i < self.n and self.s[self.i] == ",":
                self.i += 1
                self.skip_ws()
        if self.i >= self.n:
            self.error("unterminated table")
        self.i += 1  # '}'
        return result

    def _try_identifier(self):
        self.skip_ws()
        start = self.i
        s = self.s
        if self.i < self.n and (s[self.i].isalpha() or s[self.i] == "_"):
            while self.i < self.n and (s[self.i].isalnum() or s[self.i] == "_"):
                self.i += 1
            return s[start:self.i]
        return None

    def parse_string(self):
        self.i += 1  # opening quote
        out = []
        s = self.s
        while self.i < self.n:
            c = s[self.i]
            if c == '"':
                self.i += 1
                return "".join(out)
            if c == "\\":
                self.i += 1
                e = s[self.i]
                if e == "n":
                    out.append("\n")
                elif e == "t":
                    out.append("\t")
                elif e == "r":
                    out.append("\r")
                elif e.isdigit():
                    num = e
                    self.i += 1
                    for _ in range(2):
                        if self.i < self.n and s[self.i].isdigit():
                            num += s[self.i]
                            self.i += 1
                        else:
                            break
                    out.append(chr(int(num)))
                    continue
                else:
                    out.append(e)
                self.i += 1
            else:
                out.append(c)
                self.i += 1
        self.error("unterminated string")

    def parse_long_string(self):
        self.i += 2  # '[['
        start = self.i
        end = self.s.find("]]", start)
        if end == -1:
            self.error("unterminated long string")
        val = self.s[start:end]
        self.i = end + 2
        return val

    def parse_scalar(self):
        start = self.i
        s = self.s
        while self.i < self.n and s[self.i] not in " \t\r\n,}]=":
            self.i += 1
        tok = s[start:self.i]
        if tok == "true":
            return True
        if tok == "false":
            return False
        if tok == "nil":
            return None
        try:
            if any(ch in tok for ch in ".eE") and tok.lower() not in ("inf", "-inf"):
                return float(tok)
            return int(tok)
        except ValueError:
            try:
                return float(tok)
            except ValueError:
                return tok


def parse_savedvariables(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    globals_ = LuaParser(text).parse_globals()
    db = globals_.get("CrowLogsHelperDB")
    if db is None:
        sys.exit("error: CrowLogsHelperDB not found in SavedVariables file.")
    return db


# ----------------------------------------------------------------------------
# Combat log parsing.
# ----------------------------------------------------------------------------

DAMAGE_EVENTS = {
    "SWING_DAMAGE",
    "SPELL_DAMAGE",
    "SPELL_PERIODIC_DAMAGE",
    "RANGE_DAMAGE",
    "SPELL_BUILDING_DAMAGE",
}


def split_csv(line):
    """Split a combat-log payload on commas, honoring double-quoted fields."""
    fields = []
    cur = []
    in_quote = False
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if c == '"':
            in_quote = not in_quote
        elif c == "," and not in_quote:
            fields.append("".join(cur))
            cur = []
        else:
            cur.append(c)
        i += 1
    fields.append("".join(cur))
    return fields


def parse_timestamp(stamp, year):
    """'MM/DD HH:MM:SS.mmm' -> epoch seconds (float, local time)."""
    date_part, time_part = stamp.split(" ", 1)
    month, day = (int(x) for x in date_part.split("/"))
    if "." in time_part:
        hms, ms = time_part.split(".")
        frac = int(ms) / 1000.0
    else:
        hms, frac = time_part, 0.0
    hh, mm, ss = (int(x) for x in hms.split(":"))
    epoch = time.mktime((year, month, day, hh, mm, ss, 0, 0, -1))
    return epoch + frac


# The *_DAMAGE suffix is a fixed trailing block:
#   amount, overkill, school, resisted, blocked, absorbed,
#   critical, glancing, crushing[, isOffHand]
# i.e. amount, then 5 numeric fields, then 3-4 boolean flags (each "nil" or "1").
# Advanced-logging params (and how many a core injects) sit BEFORE this block, so
# we anchor on the trailing flags instead of counting from a fixed offset. Some
# cores include isOffHand (10-field suffix), some don't (9). We try 10 then 9 and
# accept whichever has numeric middle fields + boolean trailing flags.
# Set DAMAGE_SUFFIX_LEN to force a specific length (via --suffix-len).
DAMAGE_SUFFIX_LEN = None
_FLAG_VALUES = {"nil", "1"}


def _amount_for_len(fields, suffix_len):
    if len(fields) < suffix_len:
        return None
    suffix = fields[-suffix_len:]
    flags = suffix[6:]                  # critical, glancing, crushing[, isOffHand]
    if not flags or any(f not in _FLAG_VALUES for f in flags):
        return None
    try:
        amount = int(suffix[0])         # amount
        for mid in suffix[1:6]:         # overkill, school, resisted, blocked, absorbed
            int(mid)
    except ValueError:
        return None
    return amount if amount >= 0 else None


def extract_damage_amount(fields):
    """fields = CSV split of the event payload (fields[0] == event name)."""
    lengths = (DAMAGE_SUFFIX_LEN,) if DAMAGE_SUFFIX_LEN else (10, 9)
    for suffix_len in lengths:
        amount = _amount_for_len(fields, suffix_len)
        if amount is not None:
            return amount
    return None


def parse_log(path, year):
    """
    Returns a list of damage events: dicts with keys
    epoch, source_guid, source_name, amount.
    Also returns encounter markers (for optional reporting).
    """
    events = []
    encounters = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or "  " not in line:
                continue
            stamp, payload = line.split("  ", 1)
            try:
                epoch = parse_timestamp(stamp, year)
            except (ValueError, OverflowError):
                continue
            fields = split_csv(payload)
            event = fields[0]

            if event in DAMAGE_EVENTS:
                amount = extract_damage_amount(fields)
                if amount is None or len(fields) < 9:
                    continue
                events.append({
                    "epoch": epoch,
                    "source_guid": fields[1],
                    "source_name": fields[2].strip('"'),
                    "amount": amount,
                })
            elif event == "ENCOUNTER_START" and len(fields) >= 3:
                encounters.append({
                    "epoch": epoch, "kind": "start",
                    "encounterID": _to_int(fields[1]),
                    "name": fields[2].strip('"'),
                })
            elif event == "ENCOUNTER_END" and len(fields) >= 6:
                encounters.append({
                    "epoch": epoch, "kind": "end",
                    "encounterID": _to_int(fields[1]),
                    "name": fields[2].strip('"'),
                    "success": _to_int(fields[5]),
                })
    events.sort(key=lambda e: e["epoch"])
    return events, encounters


def _to_int(s):
    try:
        return int(s)
    except (ValueError, TypeError):
        return None


def as_list(x):
    """Lua arrays are parsed as dicts keyed by 1..n; return their values in order."""
    if isinstance(x, dict):
        return [x[k] for k in sorted(x.keys(), key=lambda k: (not isinstance(k, int), k))]
    if isinstance(x, list):
        return x
    return []


# ----------------------------------------------------------------------------
# Merge.
# ----------------------------------------------------------------------------


def item_id(item_string):
    """'item:12345:0:0:...' -> 12345"""
    if not item_string:
        return None
    parts = item_string.split(":")
    if len(parts) >= 2:
        return _to_int(parts[1])
    return None


def damage_in_window(events, start, end):
    """Sum damage by source GUID for events within [start, end]."""
    totals = {}
    names = {}
    for e in events:
        if e["epoch"] < start:
            continue
        if e["epoch"] > end:
            break
        guid = e["source_guid"]
        totals[guid] = totals.get(guid, 0) + e["amount"]
        names[guid] = e["source_name"]
    return totals, names


def determine_year(db, fallback_path):
    for pull in as_list(db.get("pulls")):
        ts = pull.get("startEpoch")
        if ts:
            return datetime.fromtimestamp(ts).year
    import os
    return datetime.fromtimestamp(os.path.getmtime(fallback_path)).year


def build_report(db, events):
    loadouts = db.get("loadouts", {})
    pulls = sorted(as_list(db.get("pulls")), key=lambda p: p.get("startEpoch", 0))
    report = []

    for idx, pull in enumerate(pulls):
        start = pull.get("startEpoch")
        end = pull.get("endEpoch")
        if start is None:
            continue
        if end is None:
            # Unclosed pull: run until the next pull starts, capped at 15 min.
            nxt = pulls[idx + 1].get("startEpoch") if idx + 1 < len(pulls) else None
            end = min(nxt or (start + 900), start + 900)

        totals, log_names = damage_in_window(events, start - 1, end + 1)
        raid_damage = sum(
            v for g, v in totals.items()
            if g in pull.get("participants", {})
        ) or 1
        duration = max(1, (end - start))

        players = []
        participants = pull.get("participants", {})
        # Include every participant (even 0 damage) plus any logged player source.
        guids = set(participants.keys()) | {
            g for g in totals if g.startswith("Player-")
        }
        for guid in guids:
            hash_ = participants.get(guid)
            lo = loadouts.get(hash_) if hash_ else None
            dmg = totals.get(guid, 0)
            entry = {
                "guid": guid,
                "name": (lo or {}).get("name") or log_names.get(guid) or "?",
                "spec": (lo or {}).get("specName"),
                "specID": (lo or {}).get("specID"),
                "class": (lo or {}).get("class"),
                "ilvl": (lo or {}).get("ilvl"),
                "trinkets": [
                    item_id((lo or {}).get("gear", {}).get(13)),
                    item_id((lo or {}).get("gear", {}).get(14)),
                ] if lo else [],
                "talents": (lo or {}).get("talents", {}) if lo else {},
                "damage": dmg,
                "dps": round(dmg / duration, 1),
                "pct_of_raid": round(100.0 * dmg / raid_damage, 1),
                "loadout_known": lo is not None,
            }
            players.append(entry)

        players.sort(key=lambda p: p["damage"], reverse=True)
        report.append({
            "encounterName": pull.get("encounterName"),
            "encounterID": pull.get("encounterID"),
            "difficultyID": pull.get("difficultyID"),
            "startClock": pull.get("startClock"),
            "durationSec": round(duration),
            "success": pull.get("success"),
            "target": pull.get("target"),
            "players": players,
        })
    return report


def print_report(report):
    for pull in report:
        result = {1: "KILL", 0: "WIPE"}.get(pull.get("success"), "?")
        target = (pull.get("target") or {}).get("name") or ""
        print("=" * 78)
        print(f"{pull['startClock']}  {pull['encounterName'] or target}  "
              f"[{result}]  {pull['durationSec']}s")
        print("-" * 78)
        print(f"{'Player':<16}{'Spec':<16}{'iLvl':>5}  {'Damage':>12}"
              f"{'DPS':>10}{'%':>7}  Trinkets")
        for p in pull["players"]:
            spec = p["spec"] or ("(no loadout)" if not p["loadout_known"] else "?")
            trinkets = "/".join(str(t) for t in p["trinkets"] if t) or "-"
            print(f"{p['name']:<16}{spec:<16}{(p['ilvl'] or 0):>5}  "
                  f"{p['damage']:>12,}{p['dps']:>10,.0f}{p['pct_of_raid']:>6.1f}%  "
                  f"{trinkets}")
        print()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sv", required=True, help="Path to CrowLogsHelper.lua")
    ap.add_argument("--log", required=True, help="Path to WoWCombatLog.txt")
    ap.add_argument("-o", "--out", help="Write full report as JSON to this path")
    ap.add_argument("--year", type=int,
                    help="Year for combat-log timestamps (default: inferred)")
    ap.add_argument("--suffix-len", type=int,
                    help="Damage-event suffix length (default 10; try 9 if "
                         "your core trims isOffHand and damage looks wrong)")
    args = ap.parse_args()

    if args.suffix_len:
        global DAMAGE_SUFFIX_LEN
        DAMAGE_SUFFIX_LEN = args.suffix_len

    db = parse_savedvariables(args.sv)
    year = args.year or determine_year(db, args.log)
    events, _ = parse_log(args.log, year)
    report = build_report(db, events)

    if not report:
        print("No pulls found in SavedVariables (did you /reload or log out?).")
        return

    print_report(report)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2)
        print(f"Wrote JSON report to {args.out}")


if __name__ == "__main__":
    main()
