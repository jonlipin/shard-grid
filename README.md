# Shard Grid

**See your Soul Shards at a glance, and get on with spending them.**

Shard Grid is a Warlock addon built around one number you are always checking: how many shards you have. It shows them as a bag-style grid on your screen, warns you before you run dry, clears out the ones spilling into your bags, and then helps with everything you spend them on.

- **Summons** without the chat scrollback. Requests are collected in a list, one click summons and tells the group where you are.
- **Soulstones** you can actually keep track of: who has one, from whom, and how long it lasts.
- **Healthstones** handed over as soon as a trade opens, or created on the spot if you have none.

It is built from the game's own interface art and its options live in the game's own settings panel, so it looks like part of the default UI rather than something bolted on.

## Features

### Shard grid
- Every Soul Shard you carry is shown as a slot in a compact, movable grid that matches the default bag window.
- **Soul bag aware:** with a soul bag equipped, the grid shows every slot in it. Filled slots hold a shard, empty slots show how much room you have left. The title reads like `18/24`.
- **Over the limit:** shards beyond your auto-delete limit keep the orange tint even with no soul bag, and are moved next to the free slots.
- **Overflow highlighting:** shards that spilled into your normal bags are added to the end of the grid in **orange** and counted separately (`18/24 +3`), so you can tell at a glance when you are wasting bag space.
- **Bag-like:** empty bag slots fill out the grid so it keeps a steady shape, with a minimum number of rows, and an option to put the free slots first.
- **Resizable:** drag the corner grip to set how many columns wide the grid is, or use sliders for width, slot size and overall scale. The frame border stays intact at any size.
- **Animated:** a purple star of light bursts in the middle of the screen and a new shard is thrown out of it, lobbing up and back down into its slot while it tumbles, grows and trails purple light. A spent one flashes out. Can be turned off.
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
- The game only allows item deletion during a real key press or click, so extras are removed one stack per key press (keys still work normally) or click on the grid. A "Delete extras now" button is included too.
- Optional chat message each time shards are removed.

### Summon requests
- Watches party, raid, instance chat and whispers for summon requests such as "123", "summon" or "sum", and lists who asked, with their class, oldest first. The keyword list is editable.
- The window pops up when a request arrives and can be minimized to a small title bar.
- **Click a name to summon:** targets the player and casts Ritual of Summoning, whispers them that the summon is coming (with your zone and location), and tells your party or raid who is being summoned, where you are, that you need two helpers on the portal, and how many shards are left.
- Someone who whispers from outside your group gets an Invite button on their row.
- Both messages can be edited and tested from the options, with placeholders for the player's name, your zone, subzone, minimap zone text, coordinates and shards left.
- Players are removed automatically once they arrive or leave the group.
- A floating summon button can be placed anywhere: target or hover a party or raid member and click it. With nobody targeted it summons whoever has been waiting longest in the request list. Either way the same messages are sent.
- Because it uses secure buttons, the window only updates out of combat. While you are in combat a banner covers the list and blocks clicks, and requests made during combat show up when combat ends.

### Soulstone tracker
- Lists everyone in your group carrying a soulstone, how long it has left and who cast it, on bars built from the client's own cooldown bar art: an icon, the holder's name and the timer on a purple bar with a moving pip, and who cast it above on the right. The bar turns red in the last minute, and the longest remaining is listed first.
- Optionally tells your party or raid when you soulstone someone.
- Pops up when a soulstone is cast, and can be hidden while you are not in a group.

### Healthstones
- Optional: when a trade window opens and you have a Healthstone, it is placed in the trade for you (by default only for players in your group). You still confirm the trade yourself.
- If you have none, an optional Create Healthstone button appears on the trade window, and disappears once the stone is made.

### Looks and feels like the default UI
- Options live in the game's own menu at **Esc > Options > AddOns > Shard Grid**, built from its own checkboxes, sliders and buttons. The cog on the grid, right-clicking the grid, the minimap button and `/shards` all open them there.
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
| `/shards summons` | Open or close the summon request window |
| `/shards summons test` | Add a fake request to preview the window |
| `/shards stones` | Open or close the soulstone tracker |
| `/shards minimap` | Toggle the minimap button |
| `/shards cog` | Step through the settings icons your client has |
| `/shards cog list` | List them, marking the one in use |
| `/shards cog grab` | Copy the icon from any button you point at |
| `/shards reset` | Restore default settings and positions |
| `/shards debug` | Print diagnostic info (handy for bug reports) |

## Notes
- No dependencies, no libraries, one file.
- Made for Warlocks. On other classes the grid stays hidden unless you are carrying Soul Shards.
- Found a bug? Include the output of `/shards debug` with your report.
