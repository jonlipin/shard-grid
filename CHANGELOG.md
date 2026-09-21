# Changelog

## 1.0.1 (2026-09-21)
- Fixed Blizzard nameplate errors ("attempt to compare a secret number value, execution tainted by ShardGrid"). The options no longer use the game's Settings controls or open the Settings panel from addon code. Options now always open in Shard Grid's own window, and the Options > AddOns entry is a simple page with a button that opens it.
- Removed the `/shards oldmenu` command, since there is only one options window now.

## 1.0.0 - Initial release (2026-09-21)

### Shard grid
- Bag-style grid of your Soul Shards, built from the default bag window art.
- Soul bag support: every soul bag slot is shown, filled or free, with an `in bag / capacity` count in the title.
- Shards in normal bags are shown as orange overflow slots and counted separately.
- Adjustable grid width (corner drag grip or slider), slot size and scale. The frame border stays intact at small sizes.
- Tooltip with a breakdown of shards in the soul bag, free slots, overflow and total.
- Movable, lockable, position saved per character.

### Low shard alert
- Separate movable icon that pulses when total shards fall below a configurable threshold.
- Optional alert sound with several soft chimes to choose from, plus support for a custom sound kit ID.
- Preview option for positioning the alert icon.

### Auto-delete
- Optional deletion of shards beyond soul bag capacity plus a configurable allowance.
- Only deletes shards in normal bags, never from the soul bag, and never while you hold an item on the cursor.
- Runs on your next key press or click, as required by the game for item deletion.
- Allowance stays at maximum while auto-delete is off, so enabling it never deletes shards by surprise.
- Optional pause while no soul bag is equipped, optional chat announcements, and a "Delete extras now" button.

### Interface
- Options window built from standard game controls, also reachable from Options > AddOns.
- Minimap button: left-click for options, right-click to show or hide the grid, drag to move.
- Slash commands: `/shards` and `/shardgrid` (see the README for the full list).
- `/shards debug` diagnostic output for bug reports.
