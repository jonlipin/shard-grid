## 1.9.0 - 2026-11-15

### New
- **Resize the Summons and Soulstones windows.** Each has a grip in its bottom-right corner, like the grid's. Drag it to make the whole window bigger or smaller, from 60% to 200%; the top-left corner stays where it is. The "Summon window size" and "Soulstone window size" sliders in /shards do the same. Lock position hides the grips. The summon window can't be resized in combat.
- **Keep the soul bag closed.** A new option under Display. When all your bags open at once (the open-all-bags key, or a shop, mailbox or bank opening them), the soul bag stays shut, since the grid already shows what is in it. Click the bag itself to look inside, and the key still closes your bags on the second press. Works with separate bags, not the combined bag window.

### Fixes
- **No error when the options are opened in combat.** The game refuses to open its options panel for an addon during a fight, which showed up as a blocked action in error catchers. In combat Shard Grid now opens its own options window instead.
- **The Soulstones window stays open when you open it yourself.** With "Hide while not in a group" on, opening it with /shards stones while solo hid it again within seconds. It now stays until you close it.
