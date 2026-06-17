## 0.2.0

### Ship support (ShipCommander + ShipSonar)
- New `ShipCommander` class discovers all coalition groups whose name contains the configured prefix (default `asw_ship`) at mission start; groups with more than one unit are skipped with a warning
- Coalition-wide F10 menus (`ASW Ships → [Ship Name]`) so any BLUE player or Game Master can issue orders to any ship
- Speed control: increase/decrease by 5 kt, set absolute (5/10/15/20 kt), stop; implemented via `Controller:setTask` waypoint pushed every 5 s so the ship keeps moving
- Heading control: turn left/right 30°, set any of 8 compass headings; zig-zag AI behavior weaves ±20° around the player-set heading (45 s period, toggle via AI Behavior menu)
- Depth charges: drop a single charge or a pattern (5 charges, 10 s interval) at the ship's current position; set depth 30/50/100/150/200 m
- New `ShipSonar` class attached to each ship:
  - **Passive mode** (default): continuous bearing-only detection, same model as sonarbuoys, bearing lines drawn above 5% confidence
  - **Active mode**: rotating sweep triangle on F10 map (30° cone, 60 s/revolution); when a contact is found the sweep locks on and oscillates ±15° to track it; switches back to circle scan after 15 s without a return; 15-minute battery (drains while active, recharges in passive); enemy coalition gets a sonar ping warning each sweep tick
  - Range ring drawn on F10 map: blue (passive, 12 km) or orange (active, 20 km), moves with the ship

### Sensor range rings
- Sonarbuoys now draw a detection-range ring (semi-transparent blue) on deploy; ring is removed when the buoy is picked up, removed, or battery-depleted
- Dipping sonar draws a range ring (teal) while the sonar head is in the water (state = active); ring moves with the helicopter and is removed on raise or cable break

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
