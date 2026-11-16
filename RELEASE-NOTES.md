## 1.10.0 - 2026-11-16

### New
- **No alerts in rested zones.** A new option under Low shard alert. While you are resting in an inn or a city, the low shard, Soulstone ready and No Healthstone icons stay hidden. They come back when you leave, and the low shard sound plays then if you are still short.

### Fixes
- **The soul bag stays closed at vendors, bankers and auctioneers too.** "Keep the soul bag closed" now also covers the bank, the auction house, the guild bank and trades, and bag addons that open the bags one at a time when those windows open.
- **The Soulstone alert works in a fight.** In combat the game keeps item cooldowns from addons, and the alert took that to mean "not ready", so the icon vanished as a fight began and came back when it ended. It now goes by the last cooldown it saw and by the stones it saw you use, so the icon stays up in combat: click it to make a stone, and again to use it. Using a stone with an enemy targeted no longer fails either: it goes on a friendly target right away, otherwise the game asks who to put it on. And if the cooldown runs out in the middle of a fight, the icon that appears can be clicked (the button is put in place unseen as combat starts, when the cooldown has under 15 minutes left).
