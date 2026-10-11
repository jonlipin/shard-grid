## 1.6.1 - 2026-10-11

### Fixes
- Auto-delete fills your soul bag before it deletes anything. Before, it could delete shards from your other bags while the soul bag still had empty slots. Now each key press or click moves one loose shard into an empty soul bag slot, and only what still doesn't fit is deleted. "Delete extras now" does the same.
- Auto-delete works for players who play with a controller or click their abilities with the mouse. The game only allows a delete during a real button press, and Shard Grid could only see keyboard presses, so a controller player's presses never deleted anything. Using an action bar button (with a key, a mouse click or a controller button), casting, using an equipped item, jumping or interacting now count too, in combat as well.
- Clicking, turning or running with the mouse in the game world can't delete: the game refuses an addon's delete from those. Shard Grid doesn't try them.
- If the game refuses a delete from one of those inputs, only that input stops being used, in combat or out of it, and it is remembered, so the game's "Interface action failed" message shows at most once for it. Key presses and clicks are never affected. `/shards debug` lists any refused input.
- A shard is never picked up while a spell is waiting for a target, so it can't become the spell's target.

### New
- The options explain how auto-delete works: what is deleted, what sets it off and what doesn't, in one list under the Overflow shards controls. The auto-delete and key press tooltips say more too, including that turning auto-delete on leaves "Extra shards to keep" at its maximum until you lower it.
- The auto-delete status line says when loose shards are going into the soul bag first.
