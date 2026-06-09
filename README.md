# CrowLogsHelper

A **WoW 7.3.5 (Legion)** raid addon that snapshots every raid member's **spec / talents /
gear / trinkets** on each boss pull. Upload its SavedVariables to [CrowLogs](https://github.com/ivkoneli/CrowLogs)
and your logs show *who was running what* on every pull — frozen per fight, even after
people re-gear or respec.

## How it works

- On each boss pull (`ENCOUNTER_START`, with a combat fallback), every player's addon
  snapshots itself and **broadcasts a compact loadout** over the raid addon channel — and
  re-broadcasts automatically whenever you change gear, talents, or spec.
- The **raid leader or any assist** aggregates everyone into their SavedVariables and
  **inspects** any raider not running the addon (best-effort backfill). Only one
  collector's file needs uploading; coverage is near-complete as long as most people have it.
- **Combat logging turns on automatically** in raid instances — no manual `/combatlog`
  before pulls. (Toggle with `/clh autolog`.)

WoW addons can't write files live: data is held in memory and flushed to
`WTF\Account\<account>\SavedVariables\CrowLogsHelper.lua` only on **`/reload` or logout**.
That file is what you upload to [CrowLogs](https://github.com/ivkoneli/CrowLogs).

## Coverage window (`/clh show` or the minimap button)

- **Roster** — everyone in the group: has the addon? / snapshot Full · Partial · None /
  source / age, with a coverage summary and a **Refresh + inspect** button to fill gaps.
  Flags raiders on an **outdated** addon version.
- **Pulls** — recorded encounters with per-participant coverage.

## Setup

1. Copy the `CrowLogsHelper/` folder into `World of Warcraft\Interface\AddOns\`. Have
   raiders install it too.
2. Raid normally — logging auto-enables in the instance.
3. After the session, **`/reload` or log out** to flush SavedVariables, then upload
   `CrowLogsHelper.lua` to [CrowLogs](https://github.com/ivkoneli/CrowLogs).

### Commands (`/clh`)
| Command | Effect |
|---|---|
| `/clh show` | Open the coverage window. |
| `/clh status` | Spec/ilvl, stored loadouts/pulls, leader + logging state. |
| `/clh autolog` | Toggle auto combat-logging in raids. |
| `/clh log` | Toggle combat logging right now. |
| `/clh pull` / `/clh end` | Manually open / close a pull. |
| `/clh clear` | Wipe stored pulls and loadouts. |

## Files
```
CrowLogsHelper/
  CrowLogsHelper.toc   manifest (Interface 70300, SavedVariables)
  Capture.lua          build self/inspect loadout snapshot + dedup hash
  Storage.lua          SavedVariables schema: loadout pool + pull records
  Comm.lua             chunked addon-message broadcast + reassembly (+ version)
  Inspect.lua          throttled inspect queue (leader/assist backfill)
  Coverage.lua         roster/pull coverage status + refresh action
  UI.lua               coverage window + minimap button
  Core.lua             events, pull lifecycle, /clh slash command
```
