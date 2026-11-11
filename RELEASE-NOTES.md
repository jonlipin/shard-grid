## 1.8.2 - 2026-11-11

### New
- **One Healthstone per player every couple of minutes.** Shard Grid remembers who took a Healthstone in a trade. If the same player opens a trade again within the limit, no stone is placed and chat tells you why; drag one in yourself to give it anyway. The limit is 2 minutes by default, and the new "One stone per player every" slider under Healthstones sets it from no limit up to 10 minutes. Cancelled trades don't count.
- **A Healthstone made during a trade goes into it.** With a trade open and no stone, making one (with the button on the trade window, the alert or the spell) now places it in the trade as soon as it reaches your bags. Before, only a stone you already had when the trade opened was offered.

### Fixes
- **The Soulstone button uses a stone made in combat.** The game doesn't let the button change during a fight, so after making a stone in combat the second click tried to make another. It now uses the stone if you have one and makes one if you don't, in or out of combat. (In combat the game may show one red error line on that second click; the stone is still used.)
- **No more "blocked" message when the summon is also posted in /say.** Outside an instance the game only allows /say on a click or a key press. With "also post in /say" on, a summon cast from your action bar, the floating button or a click-casting addon was refused. The line now goes out on your next key press or a click on the small button that appears, and at once inside an instance or when you click a name in the summon list.
- **The "nobody is helping" reminder works.** Ritual of Summoning starts as an ordinary cast before it becomes a channel, and Shard Grid took the cast for the summon being over, so the reminder was cancelled three seconds into every summon. The cast now counts.
- The Master Soulstone is recognized by the Soulstone alert.
- If something is on your cursor when a trade opens, the Healthstone is placed on the next bag change instead of not at all.
- /shards debug shows why a Healthstone was not placed in the last trade.
