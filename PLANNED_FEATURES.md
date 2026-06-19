# Planned Features

## High Priority

- **Diesel submarine battery system** — Diesel subs must snorkel periodically to recharge. Snorkelling forces near-surface depth with high noise factor, creating a detection window the hunter side can exploit. Core tactical loop for diesel vs SSN asymmetry.

## Submarine Sensors & Countermeasures

- **MOSS decoy (Mobile Submarine Simulator)** — Fires a torpedo-shaped object that travels on a set course mimicking the submarine's acoustic signature. Sonarbuoys, dipping sonar, and ASW torpedoes home on the MOSS instead of the real sub. Much more effective than a static noise maker; limited supply (1–2), launch requires shallow depth.
- **Mine laying** — Sub drops a contact mine at its current position; any ship coming within ~200 m triggers detonation. Mines marked on the sub coalition's F10 map only. Limited supply, no rearming; enables area-denial and chokepoint ambush tactics.
- **Active sonar ping** — Single hull-sonar ping returns exact range and bearing to all contacts within ~5 km. Enemy coalition immediately receives a bearing back to the sub (they hear the ping). Last-resort precision tool when passive sonar returns insufficient contact data.
- **Bathythermograph (BT) probe** — Deployable probe that measures temperature vs. depth and reports the actual thermal layer depth. Only meaningful when thermal layer depth is randomised at mission start (config range). Costs time to deploy and recover; finding the layer is a significant tactical advantage.

## Submarine Damage

- **Damage system** — Nearby depth charge detonations deal incremental hull damage (percentage). Damage thresholds: light flooding reduces max speed; critical flooding forces emergency surface. Adds real consequences to being caught — currently a near-miss has no lasting effect.

## Submarine Improvements

- **Submarine surfacing** — Sub can surface, exposing a real DCS model and using a higher surface speed. Surfaced subs are radar-visible and acoustically loud.
- **Shallow-depth vulnerability** — At periscope depth (≤30m), the sub is detectable by surface radar. Hunters automatically receive a position fix when the sub is shallow, rewarding disciplined depth management.
- **"Go silent" quick command** — Human commander gets an all-stop / silent running shortcut rather than only speed deltas.
- **Add WW2 diesel submarine class** — Pre-existing diesel type already exists; needs battery mechanic and period-appropriate performance limits.

## Submarine Passive Sonar Improvements

- **Depth-dependent passive sonar sensitivity** — A submarine's passive sonar effectiveness should vary with depth. Shallow depths expose the sonar array to more surface noise (waves, shipping traffic), reducing sensitivity. Detection probability and range should factor in the sub's current depth to reward tactically chosen listening depths. (Thermal layer already implemented separately.)

## Physics Improvements

- **Depth-dependent kill radius** — Underwater explosions at greater ambient pressure produce more lethal shock waves. Kill radius should scale with detonation depth: `effectiveRadius = baseRadius × (1 + depth / 400 × 0.5)` (e.g. 80m → 100m at 200m → 120m at 400m). Applies primarily to depth charges where the hunter explicitly sets detonation depth; could also apply to ASW torpedoes for consistency. Rewards correct depth setting and gives submarines a meaningful reason to dive deep beyond just sonar avoidance.

## Hunter Improvements

- **Dipping sonar blocked near surface ships** — Prevent lowering the sonar cable when a surface ship (friendly or enemy) is within a minimum radius (e.g. 200m). Tangling or collision risk. Show a warning message with the offending ship's name and distance so the pilot knows to reposition.
- **Depth charge spacing in seconds** — Replace the current metre-based spacing options with a time-based interval (e.g. 1s, 2s, 3s, 5s between charges). More intuitive for the pilot since actual spread depends on aircraft speed anyway; seconds let the player reason about pattern size relative to their current groundspeed.
- **Active sonobuoy variant (DICASS)** — Premium buoy type that gives bearing and range (full fix) but immediately alerts the submarine coalition with the ping location. Tactical trade-off: spend a limited resource for a precision fix at the cost of warning the target.
- **Track correlation display** — When two bearing lines from different buoys intersect, mark the crossing point on the F10 map. Either automatic (when two recent lines overlap) or a manual "mark intersection" command for the hunter side.
- Show line with arrow on F-10 map when ready to deply Torpedos for HEading information, including range.

## AI Commander Improvements

- **Depth charge follow-up noise makers** — During depth charge evasion, if charges keep falling close, re-deploy noise makers similar to the torpedo re-detection logic in `updateEvade`.
- **Avoid shallow waters** - The AI Commander should try to avoid to run the submarine aground.

## Multiplayer / Scale

- **Multiple submarines** — Detection and AI infrastructure already supports multiple subs via `detectableObjects`. Config and human commander menu need extending for more than one submarine.

## Ships (Separate Project Phase)

- Ships have fundamentally different weapon systems (ASROCs, deck guns, depth charge racks) and will be implemented as a standalone manager class.
- Ship Anti-Torpedo