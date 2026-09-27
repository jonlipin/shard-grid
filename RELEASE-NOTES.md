## 1.4.1 - 2026-09-27

### Fixes
- Fixed a name staying in the summon list after the player took the summon. The list cleared a name by asking whether that player was in range, and this client is entitled to withhold that answer from an addon, in which case nothing ever cleared. A summoned name now also clears once the player turns up nearby, and in any case once the two minute offer has run out. Names you have not summoned yet are left alone, so somebody standing next to you still keeps their place in the queue.
