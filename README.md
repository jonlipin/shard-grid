# Shard Grid

**Your Soul Shards, on screen and out of your way.**

Shard Grid puts your shards where you can see them: a small bag-style grid that fills as you collect and empties as you spend. It warns you before you run dry, clears out the ones cluttering your bags, and then handles the three things shards are actually for.

- **Summons.** Requests stop scrolling past in chat. They queue up in a list, and one click summons the player, tells your group where you are and asks for clickers.
- **Soulstones.** Who has one, who cast it and how long it has left, on bars built from the game's own cooldown art.
- **Healthstones.** Handed over the moment a trade opens, or conjured on the spot if you have none.

Everything is drawn with the interface's own art and its options live in the game's own settings panel, so it looks like part of the UI rather than something bolted on.

## Getting started

1. Extract the download into your `Interface\AddOns` folder. You should end up with a `ShardGrid` folder containing `ShardGrid.toc`.
2. Log in on a Warlock. The grid appears by itself.
3. Type `/shards` to open the options, or click the minimap button.

Drag the grid where you want it, and drag the grip in its corner to set how many columns wide it is. Everything else has a sensible default, so you can stop there if you like.

## How to use it

**Watching your shards.** Filled slots are shards, dim slots are room to spare. With a soul bag equipped the grid shows its capacity and the title reads `18/24`. Shards that have spilled into your normal bags are orange, and any past the number you have chosen to keep are red. Hover the grid for the full breakdown. Each new shard is thrown into its slot and each spent one flashes out, which you can switch off with `/shards anim`.

**Never running dry.** Turn on the low shard alert and pick a threshold. A separate icon appears and pulses whenever you drop below it, so you find out before you are standing at a summoning stone with nothing to spend. Drag the icon anywhere; tick "Show alert now" if you want to place it without waiting to run low.

**Clearing the clutter.** Tick "Auto-delete extra shards" and set how many you want beyond your soul bag's capacity. Anything over that is destroyed for you, and only ever from your normal bags. The allowance sits at maximum while auto-delete is off, so switching it on never deletes anything by surprise: turn it on first, then lower the slider. Because the game only allows an addon to destroy an item during a real key press or click, extras go one at a time on your next key press, or when you click the grid.

**Summoning.** Leave "Watch chat for summon requests" on and the window fills itself as people ask. Click a name to summon that player: it targets them, casts, whispers them that it is coming and posts your location to the group with a request for two clickers. Someone who whispered from outside your group gets an Invite button first. Names clear themselves once the player arrives.

Turn on the floating summon button if you would rather work from the unit frames: target or hover a party member and click it. With nobody targeted it summons whoever has waited longest.

Both messages are yours to edit, with placeholders for the player's name, your zone, subzone, minimap zone text, coordinates and shards left. Each has a Test button, so you can check the wording before a stranger reads it.

**Soulstones.** The tracker opens itself when a stone is cast and lists who is carrying one, longest remaining first. Turn on the announcement if you want the group told when you stone someone. Only your own casts are announced, so several Warlocks will not repeat each other.

**Healthstones.** With the trade options on, opening a trade puts a Healthstone straight into it, and offers a button to conjure one if you have none. You still press Trade yourself.

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
| `/shards minimap` | Toggle the minimap button |
| `/shards cog` / `cog list` / `cog grab` | Change the options icon, or copy one off any button |
| `/shards bar grab` / `bar reset` | Copy a bar's art for the soulstone bars, or restore it |
| `/shards reset` | Restore default settings and positions |
| `/shards debug` | Print diagnostic info (handy for bug reports) |

## Notes

- No dependencies, no libraries, one file.
- Settings are saved per character.
- Made for Warlocks. On other classes the grid stays hidden unless you are carrying Soul Shards.
- Some of what this addon does, destroying an item or casting a spell, is only allowed by the game during a real key press or click. Where that matters it is explained in the options rather than failing quietly.
- Found a bug? Include the output of `/shards debug` with your report.
