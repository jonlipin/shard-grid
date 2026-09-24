# Changelog

## 1.2.0 (2026-09-23)

### New

**Summon requests**
- A summon request window. Shard Grid watches party, raid, instance chat and whispers for requests such as "123", "summon", "sum" or "summ", and lists who asked, with their class, oldest first.
- Click a name to target that player and cast Ritual of Summoning. Right-click casts at them without changing your target.
- The player being summoned gets a whisper telling them it is coming, and your party or raid gets a message naming them, your location, a request for two helpers on the portal, and how many shards are left.
- Players leave the list automatically when they arrive or leave the group. Rows have a remove button, and there is a Clear all button.
- Someone who whispers from outside your group gets an Invite button on their row.
- The window pops up on a request and can be minimized to a title bar.
- The request keywords are editable in the options.
- An "Add test request" button, and `/shards summons test`, add a fake entry so you can position the window. Test entries cast and send nothing.

**Summon button**
- An optional floating summon button. Target or hover a party or raid member and click it. With nobody targeted it summons whoever has been waiting longest in the request list.
- Both messages are sent for any Ritual of Summoning you cast, including from your own action bar, so either flow announces correctly. Repeats within five seconds are ignored.

**Messages**
- The party or raid message and the whisper can both be edited in the options, with placeholders for the player's name, your zone, subzone, minimap zone text, coordinates and the shards you will have left.
- Each has a Test button. The whisper test whispers you; the group test previews in your own chat window only.

**Soulstone tracker**
- A window listing everyone in your group carrying a soulstone, the time left, a countdown bar that turns red in the last minute, and who cast it when the game reports it.
- It opens by itself when a soulstone is cast, can be hidden while you are not in a group, and toggles with `/shards stones`.
- The soulstone bars are built from the client's own cooldown bar art, with its exact layout: the bar, its background, the moving pip, and a rounded icon with the matching frame and drop shadow, tinted purple. Without that art the interface's standard bar is used instead, and `/shards bar grab` copies any piece from a bar the game draws itself.
- The name of whoever holds the soulstone sits on the bar with the timer, and who cast it sits above it on the right.
- Soulstones are sorted with the most time remaining first.
- New option: tell your party or raid when you soulstone someone. Only stones you cast are announced.

**Healthstones**
- Optional: when a trade window opens and you have a Healthstone, it is placed into the trade for you. By default only for players in your group. You still confirm the trade.
- Optional Create Healthstone button on the trade window. When a trade opens and you have no Healthstone, a button appears to cast it for you, and goes away once the stone is made.

**Grid**
- "Show empty slots" fills the grid out with empty bag slots so it keeps the shape of a bag, with a "Minimum rows" setting so the window stops changing size.
- "Empty slots first" reverses the order, so free slots sit at the top.
- Shards outside your soul bag are orange, and those past the number you asked to keep are red, so the ones about to be deleted stand apart from the ones merely taking up bag space. They are moved next to the empty slots, and they are tinted even with no soul bag equipped, where nothing was tinted before.
- A shard flying into the grid arrives its own colour and takes on the orange or red during the second half of its flight, so you watch it go wrong rather than simply appear wrong.
- The count in the title bar is centered.
- Shards are tossed into the grid when you gain one: a purple star of light bursts somewhere in the middle of the screen, in a different spot each time, and the shard is thrown out of it at a readable size, trailing purple light as it flies, lobbing up and back down into its slot over about a second under gravity, rising quickly, slowing to a stop at the top and gathering pace as it falls, each throw arcing a little higher or lower and running a little faster or slower than the last, growing as it goes and tumbling in the direction it travels. A spent shard bursts with the same purple star and flashes out of its slot. A small click sounds as each one settles, with several landing together sharing one. All of it can be turned off, with the "Animate shards" option, its own sound option, or `/shards anim`.

**Options**
- The options are the game's own page at Esc > Options > AddOns > Shard Grid. The cog, the minimap button, right-clicking the grid and `/shards` all open it there.
- Two columns in a scrolling page, so nothing is squashed to fit.
- The message and keyword boxes can be dragged taller by the bar under them, and the controls below move down to make room. Heights are remembered.
- The cog can use any of the interface's own settings icons: `/shards cog` steps through the ones your client has, `/shards cog list` shows them, and `/shards cog grab` copies the art from any button you point at.

### Fixes
- Fixed "Interface action failed because of an AddOn" followed by auto-delete switching itself off. The game allows one item deletion per key press or click, so extras are now removed one stack at a time.
- Fixed the cog, the grid's resize grip and the summon window's minimize button being invisible. They were being covered by their own window's border art.
- Fixed editing a message box saving the default text into your settings, which stopped later improvements to that default from ever reaching you.
- Fixed the options not reopening after you closed the panel.
- Fixed the last row of options being cut off at the bottom of the page.
- Fixed the mouse wheel changing whichever slider was under the cursor instead of scrolling the page.
- Fixed one label not moving when a text box above it was resized.
- Fixed the close and minimize buttons hanging over the corner of the summon window. They were the game's default size, larger than these title bars.
- Removed the addon's use of the combat log, which this client refuses to let addons read. It was only a second source for who cast a soulstone.
- Fixed the grid, and the shard animation with it, lagging behind a shard actually arriving. It was waiting on the game's batched bag update rather than the immediate one.
- Fixed the soulstone tracker coming up empty after a reload. Buffs already running raise no event, so the list is now rescanned after you enter the world and every few seconds after that.
- Anything else the client refuses is now named in chat once and listed by `/shards debug`, and the client's warning popup is dismissed. The key press watcher used for auto-delete switches itself off permanently if it is refused.

### Notes
- Deleting items is only allowed during a real key press or click, so extras over your limit are removed on your next key press, or when you click the grid, the alert icon or the "Delete extras now" button. This can be turned off.
- The summon list uses secure buttons, which the game locks during combat. A banner covers the list while you are in combat, and requests that arrive then appear when it ends.
- Shards are only marked as over the limit while auto-delete is on, since that is the only time a limit applies.

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
