# Planned Features

## High Priority

- **Diesel submarine battery system** — Diesel subs must snorkel periodically to recharge. Snorkelling forces near-surface depth with high noise factor, creating a detection window the hunter side can exploit. Core tactical loop for diesel vs SSN asymmetry.

## Submarine Improvements

- **Submarine surfacing** — Sub can surface, exposing a real DCS model and using a higher surface speed. Surfaced subs are radar-visible and acoustically loud.
- **Shallow-depth vulnerability** — At periscope depth (≤30m), the sub is detectable by surface radar. Hunters automatically receive a position fix when the sub is shallow, rewarding disciplined depth management.
- **"Go silent" quick command** — Human commander gets an all-stop / silent running shortcut rather than only speed deltas.
- **Add WW2 diesel submarine class** — Pre-existing diesel type already exists; needs battery mechanic and period-appropriate performance limits.

## Physics Improvements

- **Depth-dependent kill radius** — Underwater explosions at greater ambient pressure produce more lethal shock waves. Kill radius should scale with detonation depth: `effectiveRadius = baseRadius × (1 + depth / 400 × 0.5)` (e.g. 80m → 100m at 200m → 120m at 400m). Applies primarily to depth charges where the hunter explicitly sets detonation depth; could also apply to ASW torpedoes for consistency. Rewards correct depth setting and gives submarines a meaningful reason to dive deep beyond just sonar avoidance.

## Hunter Improvements

- **Active sonobuoy variant (DICASS)** — Premium buoy type that gives bearing and range (full fix) but immediately alerts the submarine coalition with the ping location. Tactical trade-off: spend a limited resource for a precision fix at the cost of warning the target.
- **Track correlation display** — When two bearing lines from different buoys intersect, mark the crossing point on the F10 map. Either automatic (when two recent lines overlap) or a manual "mark intersection" command for the hunter side.

## AI Commander Improvements

- **Depth charge follow-up noise makers** — During depth charge evasion, if charges keep falling close, re-deploy noise makers similar to the torpedo re-detection logic in `updateEvade`.

## Multiplayer / Scale

- **Multiple submarines** — Detection and AI infrastructure already supports multiple subs via `detectableObjects`. Config and human commander menu need extending for more than one submarine.

## Ships (Separate Project Phase)

- **ASDIC / listening stations on ships** — Ships with specific unit names get passive sonar. Recommend putting them in separate groups for menu management.
- Ships have fundamentally different weapon systems (ASROCs, deck guns, depth charge racks) and will be implemented as a standalone manager class.
