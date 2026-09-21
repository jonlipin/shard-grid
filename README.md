# Shard Grid

**See your Soul Shards at a glance. Never run out, and never drown in them, again.**

Shard Grid is a lightweight Warlock addon that shows your Soul Shards as a small bag-style grid on your screen. It is built from the game's own bag window art, so it looks like it belongs in the default UI.

## Features

### Shard grid
- Every Soul Shard you carry is shown as a slot in a compact, movable grid that matches the default bag window.
- **Soul bag aware:** with a soul bag equipped, the grid shows every slot in it. Filled slots hold a shard, empty slots show how much room you have left. The title reads like `18/24`.
- **Overflow highlighting:** shards that spilled into your normal bags are added to the end of the grid in **orange** and counted separately (`18/24 +3`), so you can tell at a glance when you are wasting bag space.
- **Resizable:** drag the corner grip to set how many columns wide the grid is, or use sliders for width, slot size and overall scale. The frame border stays intact at any size.
- Hover for a full breakdown: in soul bag, free slots, overflow, total.

### Low shard alert
- A separate, movable icon that appears and pulses when your total shards drop below a threshold you choose.
- Optional sound with a selection of softer, "magical" chimes to pick from (or any sound kit ID via `/shards sound ID`).
- "Show alert now" option so you can position it without having to run out of shards first.

### Auto-delete extra shards (optional, off by default)
- Set how many shards you want to keep beyond your soul bag's capacity. Anything over that limit is destroyed for you. With no soul bag, that number is simply your total shard limit.
- Only shards in your **normal bags** are ever deleted. Shards inside a soul bag are never touched, and the addon never interferes with an item you are holding on your cursor.
- **Safe by default:** while auto-delete is off, the allowance is parked at its maximum, so ticking the box never deletes anything by surprise. Turn it on, then lower the slider to the limit you want.
- Optional "pause while no soul bag is equipped" for when you are swapping bags.
- The game only allows item deletion during a real key press or click, so extras are removed on your next key press (keys still work normally) or when you click the grid. A "Delete extras now" button is included too.
- Optional chat message each time shards are removed.

### Looks and feels like the default UI
- Options live in the game's own menu: **Esc > Options > AddOns > Shard Grid**, using standard checkboxes, sliders and dropdowns.
- Minimap button: left-click for options, right-click to show or hide the grid, drag to move it. Can be hidden.
- Settings are saved per character.

## Commands
`/shards` (or `/shardgrid`) opens the options. Also:

| Command | What it does |
| --- | --- |
| `/shards width N` | Grid width in columns |
| `/shards size N` | Slot size |
| `/shards scale N` | Overall scale (0.5 to 2) |
| `/shards alert N` / `alert on` / `alert off` | Low shard alert threshold / toggle |
| `/shards sound ID` | Use a custom sound kit ID for the alert |
| `/shards lock` / `unlock` | Lock or unlock the grid and alert icon |
| `/shards show` / `hide` | Show or hide the grid |
| `/shards minimap` | Toggle the minimap button |
| `/shards oldmenu` | Use a standalone options window instead of the game's Options page |
| `/shards reset` | Restore default settings and positions |
| `/shards debug` | Print diagnostic info (handy for bug reports) |

## Notes
- No dependencies, no libraries, a single small file.
- Made for Warlocks. On other classes the grid stays hidden unless you are carrying Soul Shards.
- Found a bug? Include the output of `/shards debug` with your report.
