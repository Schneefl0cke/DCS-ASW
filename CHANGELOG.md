## 0.1.0 — Initial Release

## 0.1.1

### Configuration validation at startup
- Submarine spawn zones validated on init; invalid zone names in a table are skipped with a warning, with a hard error if none are valid
- AI waypoint zones validated on init; missing zones are skipped with a warning
- Rearm zone and rearm unit names validated on init; missing entries produce a warning (late-activated units are flagged as a possible cause)
