# CrowLogsHelper

Snapshots every raid member's **gear / trinkets / talents / spec** on each boss pull,
so you can cross-reference it with `WoWCombatLog.txt` and see *who was running what* per
pull alongside their damage. Built for **WoW 7.3.5 (Legion)** private servers, PvE raid.

It has two parts:

1. **The addon** (`CrowLogsHelper/`) — drops into `Interface\AddOns\`. Records pulls into
   its SavedVariables file.
2. **The merger** (`tools/clh_merge.py`) — joins that SavedVariables file with
   `WoWCombatLog.txt` into a per-pull report.

---

## How it works (and one important limitation)

WoW addons **cannot write files in real time.** The only thing an addon can persist is its
**SavedVariables**, which the game serializes to
`WTF\Account\<account>\SavedVariables\CrowLogsHelper.lua` **only when you `/reload` or log
out** — not during the raid. So CrowLogsHelper accumulates pull records in memory and they
land in that `.lua` file when you reload/logout. That file is what you feed to the merger.

**Coverage model — everyone installs, the raid leader harvests:**

- On each boss pull, every player's addon snapshots *itself* (instant, reliable) and
  **broadcasts a compact loadout** over the raid addon channel. It also re-broadcasts
  automatically whenever you change gear, talents, or spec.
- The **raid leader's** copy aggregates everyone into its SavedVariables, and **falls back
  to inspecting** any raid member who isn't running the addon (the Inspect API is
  async/range-limited, so this is best-effort backfill).
- Result: only the raid leader needs to hand over their `CrowLogsHelper.lua`, but coverage
  is near-complete as long as most people have the addon.

Capture is **boss-pulls only** (driven by `ENCOUNTER_START`), with a fallback that opens a
pull when you enter combat against a boss-classified target, plus a manual `/clh pull`.

---

## Setup

1. Copy the `CrowLogsHelper/` folder into
   `World of Warcraft\Interface\AddOns\CrowLogsHelper\`. Have the raiders install it too
   (the raid leader's file is the one you collect).
2. Before pulling, enable combat logging each session:
   ```
   /combatlog
   /console advancedCombatLogging 1
   ```
   This writes `World of Warcraft\Logs\WoWCombatLog.txt`.
3. Raid normally.
4. **After the session, `/reload` or log out** so SavedVariables flushes to disk.

### In-game commands (`/clh`)
| Command | Effect |
|---|---|
| `/clh status` | Show your spec/ilvl, how many loadouts/pulls are stored, and whether you're the leader. |
| `/clh pull` | Manually open a pull (use if the server doesn't fire `ENCOUNTER_START`). |
| `/clh end` | Manually close the current pull. |
| `/clh clear` | Wipe stored pulls and loadouts. |

---

## Generating the report

```
python tools/clh_merge.py \
  --sv  "...\WTF\Account\<ACCOUNT>\SavedVariables\CrowLogsHelper.lua" \
  --log "...\World of Warcraft\Logs\WoWCombatLog.txt" \
  -o report.json
```

Output: a per-pull table (boss, result, duration, and each player's spec / ilvl / trinkets
/ damage / DPS / % of raid), plus a full `report.json` with talent IDs per tier and gear
item strings for further analysis. No third-party Python packages required (Python 3.8+).

### How the join works
Each pull stores `startEpoch`/`endEpoch`. The merger attributes every damage event whose
timestamp falls in that window to its `sourceGUID`, then looks that GUID up in the pull's
participants → loadout. GUIDs from the combat log match the addon's `UnitGUID` values
directly, and the time-window join works even if the server never emits `ENCOUNTER_START`
lines.

### Troubleshooting
- **Damage numbers look wrong / tiny:** some cores trim the `isOffHand` field from damage
  events. Re-run with `--suffix-len 9`.
- **Wrong dates:** the combat log has no year; pass `--year 2026` if inference is off.
- **Trinkets show as numbers:** those are item IDs (slots 13/14). Look them up on a 7.3.5
  item database, or extend the script with an ID→name map.
- **`(no loadout)` for a player:** they didn't have the addon and couldn't be inspected
  (out of range). They still appear with their damage.

---

## Files
```
CrowLogsHelper/
  CrowLogsHelper.toc   manifest (Interface 70300, SavedVariables)
  Capture.lua          build self/inspect loadout snapshot + dedup hash
  Storage.lua          SavedVariables schema: loadout pool + pull records
  Comm.lua             chunked addon-message broadcast + reassembly
  Inspect.lua          throttled inspect queue (leader backfill)
  Core.lua             events, pull lifecycle, /clh slash command
tools/
  clh_merge.py         SavedVariables + WoWCombatLog.txt -> report
```
