## 1.4.2 - 2026-10-01

### Fixes
- Fixed soulstones vanishing from the tracker in combat and coming back afterwards. This client withholds aura readings from addons while you are fighting, and the tracker took being refused a reading as the stone being gone. A soulstone expires at a fixed moment, so the tracker now keeps the last reading it got and counts it down on its own, through combat and anything else that closes the auras to it. A stone genuinely removed is still forgotten, as soon as the auras can be read again.
- A stone no longer looks newly cast when combat ends, so the announcement does not repeat itself.
