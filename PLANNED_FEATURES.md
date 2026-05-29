# Planned Features

## High Priority

- **Sonobuoy lifetime** — Buoys currently live forever. Add a configurable battery life (e.g. 30–180 min) with auto-removal on expiry. Forces continuous replanting and makes the submarine's evasion window meaningful.
- **Diesel submarine battery system** — Diesel subs must snorkel periodically to recharge. Snorkelling forces near-surface depth with high noise factor, creating a detection window the hunter side can exploit. Core tactical loop for diesel vs SSN asymmetry.
- **Depth charge awareness for AI** — The AI submarine commander has no reaction to nearby depth charge detonations. A loud nearby explosion should trigger an evasion response.

## Submarine Improvements

- **Submarine surfacing** — Sub can surface, exposing a real DCS model and using a higher surface speed. Surfaced subs are radar-visible and acoustically loud.
- **Shallow-depth vulnerability** — At periscope depth (≤30m), the sub is detectable by surface radar. Hunters automatically receive a position fix when the sub is shallow, rewarding disciplined depth management.
- **"Go silent" quick command** — Human commander gets an all-stop / silent running shortcut rather than only speed deltas.
- **Add WW2 diesel submarine class** — Pre-existing diesel type already exists; needs battery mechanic and period-appropriate performance limits.

## Hunter Improvements

- **Active sonobuoy variant (DICASS)** — Premium buoy type that gives bearing and range (full fix) but immediately alerts the submarine coalition with the ping location. Tactical trade-off: spend a limited resource for a precision fix at the cost of warning the target.
- **Track correlation display** — When two bearing lines from different buoys intersect, mark the crossing point on the F10 map. Either automatic (when two recent lines overlap) or a manual "mark intersection" command for the hunter side.

## AI Commander Improvements

- **Proactive noise maker use** — Before a sprint-and-dive manoeuvre, the AI should pre-deploy a noise maker to confuse passive listeners, not only react to incoming torpedoes.
- **Depth charge evasion** — React to nearby depth charge detonations with an evasion response (random heading change, depth change, possible noise maker).

## Multiplayer / Scale

- **Multiple submarines** — Detection and AI infrastructure already supports multiple subs via `detectableObjects`. Config and human commander menu need extending for more than one submarine.

## Ships (Separate Project Phase)

- **ASDIC / listening stations on ships** — Ships with specific unit names get passive sonar. Recommend putting them in separate groups for menu management.
- Ships have fundamentally different weapon systems (ASROCs, deck guns, depth charge racks) and will be implemented as a standalone manager class.
