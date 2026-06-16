## 0.1.3

### Detection confidence threshold
- Added a 5% minimum confidence threshold to sonarbuoys, dipping sonar, and MAD detector — contacts below this probability are suppressed entirely and no map marker is drawn
- Prevents marginal detections at long range or across the thermal layer from leaking position hints to the hunter side

## 0.1.2

### Multiplayer radio menu fix
- Fixed F10 menus not appearing for `asw_helo_2`, `asw_helo_3`, etc. in multiplayer: the group scanner was permanently marking groups as tracked even when MOOSE failed to find them (e.g. before a player occupied the slot), preventing any retry
- Added a `S_EVENT_PLAYER_ENTER_UNIT` event handler so menus are created the moment a player takes a hunter slot, avoiding F10 menu sync issues with clients who join after mission start

## 0.1.0 — Initial Release

## 0.1.1

### Configuration validation at startup
- Submarine spawn zones validated on init; invalid zone names in a table are skipped with a warning, with a hard error if none are valid
- AI waypoint zones validated on init; missing zones are skipped with a warning
- Rearm zone and rearm unit names validated on init; missing entries produce a warning (late-activated units are flagged as a possible cause)
