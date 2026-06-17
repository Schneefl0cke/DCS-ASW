## 0.1.2

### Sonarbuoy battery improvements
- Added a 50% battery warning message to the hunter coalition when a deployed buoy reaches half charge, showing remaining time
- Fixed smoke overlap bug: red smoke is now delayed until the current orange smoke has burned out (~5 min), so the two never overlap

### Inventory status on slot takeover
- When a player joins a hunter group that was previously occupied, the current inventory is automatically displayed (buoys, torpedoes, depth charges, dipping sonar state) so they know what the previous player left behind

### Detection confidence threshold
- Added a 5% minimum confidence threshold to sonarbuoys, dipping sonar, and MAD detector — contacts below this probability are suppressed entirely and no map marker is drawn
- Prevents marginal detections at long range or across the thermal layer from leaking position hints to the hunter side

### Multiplayer radio menu fix
- Fixed F10 menus not appearing for `asw_helo_2`, `asw_helo_3`, etc. in multiplayer: the group scanner was permanently marking groups as tracked even when MOOSE failed to find them (e.g. before a player occupied the slot), preventing any retry
- Added a `S_EVENT_PLAYER_ENTER_UNIT` event handler so menus are created the moment a player takes a hunter slot, avoiding F10 menu sync issues with clients who join after mission start

## 0.1.1

### Configuration validation at startup
- Submarine spawn zones validated on init; invalid zone names in a table are skipped with a warning, with a hard error if none are valid
- AI waypoint zones validated on init; missing zones are skipped with a warning
- Rearm zone and rearm unit names validated on init; missing entries produce a warning (late-activated units are flagged as a possible cause)

## 0.1.0 — Initial Release
