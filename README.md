# Shard Grid

**Everything you do with Soul Shards, in one small window.**

Shards are the one resource a Warlock is always counting, and the game gives you nothing to count them with. Shard Grid puts them on screen as a bag-style grid that fills as you collect and empties as you spend, tells you before you run dry, and quietly clears out the ones cluttering your bags.

Then it handles what the shards are actually for.

- **Summons.** Requests stop scrolling past in chat and queue up in a list instead. One click summons the player, whispers them, and tells your group where you are and that you need clickers.
- **Soulstones.** Who is carrying one, who cast it and how long is left, on bars built from the game's own cooldown art. One button reports the lot to your raid.
- **Healthstones.** Passed over the moment a trade window opens, or conjured on the spot when you have none to give.

It is drawn with the interface's own art and its options live in the game's own settings panel, so it looks like part of the UI rather than something bolted onto it. No dependencies, no libraries, one file.

## Getting started

1. Extract the download into your `Interface\AddOns` folder. You should end up with a `ShardGrid` folder containing `ShardGrid.toc`.
2. Log in on a Warlock. The grid appears by itself.
3. Type `/shards` for the options, or click the minimap button.

Drag the grid where you want it, and drag the grip in its corner to set how many columns wide it is. Everything else has a sensible default, so you can stop there if you like.

## How to use it

**Reading the grid.** Filled slots are shards, dim slots are room to spare, and the title counts them. With a soul bag the title reads `9/14`, and shards sitting in your ordinary bags are added on the end in orange, with any past the number you have chosen to keep in red. Shards stay packed together, so the slot that empties when you spend one is always the one against the free space. Hover the grid for the full breakdown.

**Not running dry.** Turn on the low shard alert and pick a threshold. A separate icon appears and pulses whenever you drop below it, so you find out at the bank rather than at a summoning stone. Drag it wherever you want, and tick "Show alert now" to place it without waiting to run low.

**Clearing the clutter.** Tick "Auto-delete extra shards" and say how many you want beyond your soul bag's capacity. Anything over that is destroyed, and only ever from your ordinary bags. The allowance sits at its maximum while auto-delete is off, so switching it on never deletes anything by surprise: turn it on first, then bring the slider down. The game only lets an addon destroy an item during a real key press or click, so extras go one at a time as you play, or when you click the grid.

**Summoning.** Leave "Watch chat for summon requests" on and the window fills itself as people ask. Click a name to summon that player: it targets them, casts, whispers them that it is on the way, and posts your location to the group with a request for two clickers. Anyone who whispered from outside your group gets an Invite button first, and names clear themselves once the player arrives.

If you would rather work from the unit frames, turn on the floating summon button: target or hover a party member and click it. With nobody targeted it summons whoever has waited longest.

Both messages are yours to edit, with placeholders for the player's name, your zone, subzone, minimap zone text, coordinates and shards left. Each has a Test button, so you can read the wording before a stranger does.

**Soulstones.** The tracker opens itself when a stone is cast and lists everyone carrying one, longest remaining first. The speech bubble at its top left reports the whole list to raid or party chat, names, casters and times, which is the quickest way to answer "who has stones?". Turn on the announcement if you would rather the group were told as you stone each person; only your own casts are announced, so several Warlocks will not repeat each other.

**Healthstones.** With the trade options on, opening a trade drops a Healthstone straight into it, and offers a button to conjure one when you have none. You still press Trade yourself.

## Commands

`/shards` (or `/shardgrid`) opens the options. Also:

| Command | What it does |
| --- | --- |
| `/shards width N` | Grid width in columns |
| `/shards size N` | Slot size |
| `/shards scale N` | Overall scale (0.5 to 2) |
| `/shards anim` | Turn the shard animations on or off |
| `/shards alert N` / `alert on` / `alert off` | Low shard alert threshold, or switch it |
| `/shards sound ID` | Use a custom sound kit ID for the alert |
| `/shards lock` / `unlock` | Lock or unlock the grid and alert icon |
| `/shards show` / `hide` | Show or hide the grid |
| `/shards summons` | Open or close the summon request window |
| `/shards summons test` | Add a fake request to preview the window |
| `/shards stones` | Open or close the soulstone tracker |
| `/shards stones report` | Post the soulstone list to raid or party chat |
| `/shards minimap` | Toggle the minimap button |
| `/shards cog` / `cog list` / `cog grab` | Change the options icon, or copy one off any button |
| `/shards bar grab` / `bar reset` | Copy a bar's art for the soulstone bars, or restore it |
| `/shards reset` | Restore default settings and positions |
| `/shards debug` | Print diagnostic info (handy for bug reports) |

## Notes

- Settings are saved per character.
- Made for Warlocks. On other classes the grid stays hidden unless you are carrying Soul Shards.
- Some of what this addon does, destroying an item or casting a spell, is only allowed by the game during a real key press or click, and the summon list is locked while you are in combat. Where that matters it is explained in the options rather than failing quietly.
- Found a bug? Include the output of `/shards debug` with your report.
