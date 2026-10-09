## 1.4.4 - 2026-10-08

### Fixes
- Fixed the Create Healthstone button on the trade window doing nothing when clicked. The button only listened for the mouse button coming back up, and with the game's default "cast on key down" setting the cast happens on the press, so the click never reached it. It now listens for both, like the summon button.
- The button now casts Create Healthstone by its spell ID rather than its name, so ranked names such as "Create Healthstone (Minor)" cannot be misread.
- `/shards debug` now shows which Create Healthstone spell the button uses.
