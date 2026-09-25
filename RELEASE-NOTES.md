## 1.4.0 (2026-09-24)

### New
- A report button on the soulstone window, the speech bubble at its top left, posts the current assignments to raid or party chat: who is carrying a stone, who cast it and how long is left. Also at `/shards stones report`.

### Fixes
- Fixed a soul bag equipped in the reagent slot being invisible, along with every shard in it. The addon read only the four ordinary bag slots, and this client puts a soul bag in the reagent slot beside them.
- Fixed a spent shard emptying a slot in the middle of the grid. The grid mirrored the soul bag slot for slot, so it inherited the gaps the game left behind. Shards are now kept together with the free slots after them, so the slot that empties is always the one against the empty space.
- American spelling throughout.
