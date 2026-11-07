## 1.7.0 - 2026-11-07

### New
- **Soulstone ready alert.** A purple icon pulses while a Soulstone in your bags is off cooldown, so it isn't left unused. It goes away when you use the stone and comes back when the cooldown ends. Turn it off with "Alert when my Soulstone is ready to use" in the Soulstone tracker options.
- **No Healthstone alert.** A green icon pulses while there is no Healthstone in your bags, once you know Create Healthstone. Turn it off with "Alert when I have no Healthstone" in the Healthstones options.
- Both new icons work like the low shard alert: drag them where you want, they use the alert icon size, and they take the Dark and EllesmereUI looks.
- **Asking for clickers when nobody helps.** If you are still channeling Ritual of Summoning 15 seconds after starting it, Shard Grid asks in /say for people to click the portal, once per summon. Inside an instance it goes at once. Outside one, the game only lets addons use /say during a key press or click, so it goes on your next key press, or when you click the small "Ask for clickers in /say" button that pops up. Options: "Ask in /say when nobody helps" and "Ask after (seconds)", 5 to 60.
- **"Also say it in /say"**: posts the party / raid summon message in /say as well. Off by default.

### Changes
- The whisper and the party / raid message now go out however you start a summon: a name in the list, the floating summon button, or Ritual of Summoning cast from your spellbook, action bar, a macro or a click-casting addon.
- "Show alert now" stays on after you close the options, so you can place the alert icons with the options out of the way. Untick it when they are placed; a reload turns it off too.
- `/shards debug` has new lines: "last summon cast", "summon help asked", "soulstone ready" and "healthstone".

### Fixes
- A Ritual of Summoning cast outside the summon list could send nothing when the game hid the target's name from addons. Shard Grid now checks for that first, and uses your current target instead when they are in your group.
