## 1.6.0 - 2026-10-10

### New
- A built-in Dark style. A new Look section in the options has a Window style button with three choices: Automatic, Blizzard and Dark. Left-click it for the next style, right-click for the previous one. Dark gives the grid, summon and soulstone windows a flat dark background with thin edges, flat buttons and square slots and icons, and restyles the alert icon, the summon button and the soulstone bars to match. It needs no other addon.
- Automatic is the default. It uses EllesmereUI's look when EllesmereUI is installed, as 1.5.0 did, and the Blizzard look otherwise, so nothing changes unless you pick a style.
- A Dark background opacity slider, 0 to 100%, sets how much of the world shows through the Dark windows. It applies as you drag, and it is grayed out unless Dark is chosen.
- Going from Blizzard to Dark happens at once. Any other switch takes a reload of the interface, so Shard Grid asks, with a Reload now button. Until you reload, the options say which style is still in use.
- `/shards style` moves to the next style, and `/shards style auto`, `/shards style blizzard` and `/shards style dark` pick one.
- The styles come from a shared Styles.lua file that ships with each of the author's addons, so they all look alike in a given style.

### Fixes
- The close X on the options window and on the soulstone tracker now works in combat. It went through the game's own panel closing, which the game refuses for an addon while you are fighting; these windows now simply hide.
- The summon window cannot close in combat, because its rows are secure buttons the game locks until combat ends. Its X now says "Can't close the summon window in combat." instead of failing with a blocked action.
- Fixed the options buttons overlapping a summon keywords or message box that had grown taller. The controls under each text box now move down with it.
- More room under the text boxes in the options.
- A minimap button collector, such as EllesmereUI's, keeps Shard Grid's minimap button where it put it instead of having it pulled back to the minimap rim.
