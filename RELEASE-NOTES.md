## 1.4.3 - 2026-10-06

### Fixes
- Fixed the summon button doing nothing when the player you targeted was in another zone. Before casting, the button asked the game whether you could assist that player, and the game cannot answer that for a party member it has not loaded, which is anyone outside your zone. The button now only checks that the player is not an enemy, which holds wherever they are.
- Fixed the summon button saying there was nobody to summon while a party member in another zone was targeted. It now goes by whether they are in your group, which the game knows wherever they are.
- With nobody targeted, the button finds the longest waiting player by their place in your group rather than by name, so it is not thrown by names with a surname.
