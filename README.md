# DCS Anti-Submarine Warfare (ASW) Scripting Framework

<img width="600" height="400" alt="asw_heli" src="https://github.com/user-attachments/assets/e97c8133-57a6-45a9-a73d-92d15850604c" />
<img width="1500" height="844" alt="SSN" src="https://github.com/user-attachments/assets/5c33f5c4-91d0-4faf-8323-30a6598840c4" />

A two-sided ASW game system for DCS World using MOOSE framework. One side operates a virtual submarine (human or AI controlled), the other side hunts it with ASW aircraft equipped with sonarbuoys and torpedoes.

## Requirements

- DCS World
- MOOSE framework loaded before these scripts - https://github.com/FlightControl-Master/MOOSE
- User flag `Debug` set to `1` for debug messages (optional)

## Script Load Order

### Quick setup (recommended)

Copy both files from the `release/` folder into your mission folder. In the DCS Mission Editor, create two **DO ONCE** triggers and load them in this order:

| # | File | Notes |
|---|---|---|
| 1 | `asw.lua` | All framework classes — do not edit |
| 2 | `asw_config.lua` | Your mission configuration — edit this |

That's it. No other scripts needed.

### Manual load order (development / source)

If loading individual source files, use this order in the DCS Mission Editor (DO ONCE triggers):

1. `submarine.lua`
2. `sonarbuoy.lua`
3. `noiseMaker.lua`
4. `anti_submarine_torpedo.lua`
5. `submarineTorpedo.lua`
6. `dippingSonar.lua`
7. `depthCharge.lua`
8. `madDetector.lua`
9. `soundScheduler.lua`
10. `ordnanceManager.lua`
11. `helicopterHunterManager.lua`
12. `planeHunterManager.lua`
13. `humanSubmarineCommander.lua`
14. `aiSubmarineCommander.lua`
15. `asw_config.lua`

## Mission Editor Setup

### Required Trigger Zones

| Zone Name | Purpose |
|---|---|
| `spawn_1`, `spawn_2`, `spawn_3`, ... | Submarine spawn zones. Configure one name or a table of names in `asw_config.lua` — one is chosen at random each mission start for replayability. |
| `ASW_Hunter_Rearming` | Circle zone where ASW aircraft land/hover to rearm. Used alongside `rearmUnits` — both are checked. |
| `patrol_1`, `patrol_2`, ... | Patrol waypoints for AI submarine commander (only needed if using AI) |

### Required Groups

- Helicopter ASW groups must have **`_asw_helo`** in their group name (configurable via `HELO_CONFIG.prefix`).
- Fixed-wing ASW groups must have **`_asw_plane`** in their group name (configurable via `PLANE_CONFIG.prefix`).
- Each group should be a single aircraft. Single-player is possible, but not recommended; a second player as copilot for the helicopters improves the experience significantly.

### Coalition Setup

- **RED**: Submarine side (default)
- **BLUE**: ASW hunter side (default)

Both are configurable in `asw_config.lua`.

## Sound Setup

This framework supports mission sound cues through `soundScheduler.lua` and `asw_config.lua`.

1. Add sound files to the mission folder, for example:
   - `sounds/sonar_ping.ogg`
   - `sounds/torpedo_launch.ogg`
   - `sounds/warning_torpedo.ogg`
2. In `asw_config.lua`, edit the `SOUND_CONFIG` table to point each event to the correct file and duration.
   - Use the relative path exactly as in the mission folder, for example `sounds/torpedo_launch.ogg`.
   - Set `duration` to the real length of the sound file in seconds.
   - Set a config entry to `nil` to disable that sound.
3. Make sure `soundScheduler.lua` is loaded before `asw_config.lua` in the mission load order.

The sound scheduler registers these sound names:

| Name | Trigger |
|---|---|
| `sonar_ping` | Each dipping sonar ping |
| `sonar_extend` | Dipping sonar lowering |
| `sonar_retrieve` | Dipping sonar raised |
| `sonar_splash` | Dipping sonar hits water |
| `sonar_cable_break` | Cable breaks (speed/altitude exceeded) |
| `torpedo_launch` | ASW torpedo launched |
| `torpedo_homing` | Torpedo acquires contact |
| `buoy_splash` | Sonarbuoy deployed |
| `recover_splash` | Sonarbuoy recovered |
| `noisemaker_loop` | Noise maker active (looping) |
| `warning_torpedo` | Submarine side warned of ASW torpedo / depth charges |
| `warning_sonar` | Submarine side warned of active sonar ping |
| `mad_buzz` | Audible tone played to the pilot while MAD is actively scanning (every 2s) |

---

## Submarine Types

| Type | Noise Factor | Max Speed | Max Depth | Torpedoes | Noise Makers | Sonar Range | Thermal Penalty |
|---|---|---|---|---|---|---|---|
| Default (custom) | 1.0 | 15 m/s | 300m | 6 | 4 | 15 km | 0.3x |
| Diesel | 0.5 | 10 m/s (~20 kts) | 250m | 6 | 4 | 15 km | 0.3x |
| SSN | 0.8 | 18 m/s (~35 kts) | 500m | 10 | 6 | 20 km | 0.5x |

### Submarine Physics

- **Turn rate**: 2°/s — heading changes are gradual, not instant
- **Acceleration**: 1 m/s² — speed ramps up/down over time
- **Depth rate**: Linked to speed — `max(0.5, speed × 0.4)` m/s. Faster subs change depth quicker; minimum 0.5 m/s at rest

---

## The Thermal Layer

A configurable depth (default 90m) that divides the water column:

- **Above**: Sonarbuoys detect submarines normally
- **Below**: Detection probability is severely reduced (0.2x multiplier for buoys)
- **Cross-layer penalty**: ASW torpedoes and dipping sonar are penalized when on the opposite side of the layer from the target (0.2x)
- Submarine passive sonar is also affected: diesel gets 0.3x range, SSN gets 0.5x range when below the layer

The thermal layer is the core tactical element. Submarines want to stay below it; hunters need to set correct torpedo search depths and dipping sonar cable depths to match.

---

## F10 Map Display

### Torpedo Trails
Both submarine torpedoes and ASW torpedoes draw a **red line trail** on the F10 map, visible to all coalitions. A red text label shows the torpedo's status (name, heading, battery, depth, SEARCHING/HOMING). The trail is cleared on impact and replaced with an impact marker.

### Torpedo Launch Positions
A **green circle with text** marks every torpedo launch position, visible to all. Labels distinguish "Submarine Torpedo Launch" from "ASW Torpedo Launch".

### Submarine Position
The submarine's own coalition sees a **blue trail** (last 3 segments) with a **heading arrow**. Status text (depth, heading, speed, targets) is displayed as coalition text messages rather than map markers.

### Torpedo Range Ring
A **green circle** centered on the submarine shows the maximum straight-line torpedo reach (speed × battery life ≈ 6.2 km). A label at the ring's north edge shows the range in km and current torpedo count (`2/6`). The ring updates every 5 seconds with the position markers and is removed when the submarine is sunk.

### Sonarbuoy Position
Sonarbuoys are shown as a **small blue circle** with the buoy name, visible to all coalitions. When the battery depletes, the circle and label turn **gray** with a `[DEAD]` suffix.

### Sonarbuoy Contact
A **yellow bearing line** is drawn from the buoy outward to max detection range, labelled with bearing and confidence. Passive buoys give **bearing only** — the submarine is somewhere along that line. Cross two or more bearing lines from different buoys to triangulate a position fix. Lines auto-expire after 30 seconds.

### Submarine Sunk
When destroyed, a **red circle with text** is placed at the sunk position, visible to all coalitions.

---

## ASW Hunter Side (BLUE)

Hunters are split into two types with separate group name prefixes:

| Type | Prefix | Buoys | Torpedo | Dipping Sonar | Buoy Recovery |
|---|---|---|---|---|---|
| Helicopter | `_asw_helo` | Yes | Yes | Yes | Yes |
| Fixed-wing | `_asw_plane` | Yes | Yes | No | No |

### F10 Menu: ASW Operations

#### Sonarbuoys (both types)

| Command | Description |
|---|---|
| **Prepare to Launch Buoy** | Enter launch mode. HUD shows altitude/speed readiness. |
| **Launch Buoy!** | Deploy a sonarbuoy at current position. |
| **Prepare to Recover Buoy** | *(Helicopters only)* Enter recovery mode. HUD shows nearest buoy (active or dead) and its battery state. |
| **Recover Buoy!** | *(Helicopters only)* Pick up nearest buoy within 10m. Active buoys return with battery preserved; dead buoys go to expired inventory. |

- Helicopters carry **4 buoys** by default; fixed-wing carry **8** (configurable per type)
- A **global reserve pool** (default 10) is shared across all hunters. Hunters draw from it when rearming. Once empty, buoys must be recovered to continue operations.
- Buoys detect submarines every 5 seconds using a probability-based model
- Detection probability depends on: submarine noise (speed × noise factor), distance, depth, and thermal layer
- On detection, a **yellow bearing line** is drawn from the buoy outward (30 second duration). Bearing has ±0–30° error scaled by confidence. No range or depth — passive buoys hear direction only.
- Triangulate by cross-referencing bearing lines from two or more buoys
- Buoy position is marked with a blue circle **visible to both coalitions** — the submarine side can see where buoys are deployed
- The submarine coalition receives a **warning message** when a buoy is deployed

#### Sonarbuoy Battery

Buoys have a configurable battery life (default **30 minutes**). When the battery runs out:

- The buoy **stops detecting** but stays physically on the water
- The F10 map marker turns **gray** with a `[DEAD]` label
- The smoke switches from **orange** to **red**
- The buoy can still be recovered by a helicopter

Recovered buoys go into one of two inventory slots:

| Recovery type | Destination | Can redeploy? |
|---|---|---|
| Active buoy (battery remaining) | `savedBuoys` inventory | Yes — immediately, battery resumes where it left off |
| Depleted buoy (dead) | `expiredCount` inventory | No — must rearm first; rearming replaces battery |

Rearming at the rearm zone/carrier:
1. All expired buoys on board are **revived to full battery** (free — rearming replaces batteries)
2. The global reserve pool tops up the hunter's rack up to `maxBuoys`
3. If the pool is empty, only recovered/revived buoys refill the rack — a warning is shown

#### Torpedo (ASW)

| Command | Description |
|---|---|
| **Set Search Depth** | Choose torpedo run depth: 0m, 50m, 100m, 150m, 200m, 250m, 300m, 400m, or 500m |
| **Prepare to Launch Torpedo** | Enter launch mode. HUD shows heading + depth setting. |
| **Launch Torpedo!** | Fire torpedo on player's current heading. Same flight parameter requirements as buoys. |

- Each hunter carries **2 torpedoes** by default (configurable)
- Speed: 30 knots (15.43 m/s)
- Turn rate: 3°/s
- Sonar range: 1.5 km (checked every second)
- Kill radius: 150m horizontal + 50m depth tolerance
- Battery: 300 seconds (5 minutes)
- **Thermal layer aware**: detection penalty only applies when torpedo and target are on opposite sides of the layer. Setting the correct search depth matters!
- If the torpedo acquires a target then loses it, it turns back toward the last known position
- If the torpedo hits a **noise maker** instead of a real sub, it destroys the decoy and announces it
- The submarine coalition receives a **warning** when an ASW torpedo is launched
- Torpedo trail is **visible to all coalitions** on the F10 map as a red line

#### Dipping Sonar

| Command | Description |
|---|---|
| **Extend Cable** | Increase cable length: +10m, +25m, +50m, or +100m |
| **Retract Cable** | Decrease cable length: -10m, -25m, -50m, or -100m |
| **Lower Sonar** | Deploy the dipping sonar at the current cable target depth |
| **Stop Sonar** | Halt cable movement and hold current depth |
| **Raise Sonar** | Retrieve the dipping sonar back into the aircraft |

Dipping sonar specifications:
- Active sonar with **8 km detection range** and **0.25 scale factor** (more effective than passive buoys)
- Cable depth: 0–100m (adjustable in increments, can be changed while active; default 100m)
- Lower/raise rate: 5 m/s
- Pings every **3 seconds** while active
- **Speed limit**: cable breaks above 15 m/s. Warnings start at 5 m/s
- **Altitude limit**: cable breaks above 100m AGL. Warnings start at 50m AGL
- If the cable breaks, the sonar is lost until the aircraft returns to the rearm zone/carrier
- Contact markers appear on the F10 map for 30 seconds (same as buoys)
- **Active sonar alert**: the submarine coalition receives the sonar's exact position with each ping ("ACTIVE SONAR PING DETECTED!")
- The thermal layer affects detection: sonar above the layer has 0.2x penalty against subs below it. Lower the cable below the thermal layer (90m default) for full effectiveness
- Detection formula is the same as buoys but with 0.25 scale factor instead of 0.15
- Sonar is repaired when rearming at the rearm zone or carrier

#### Depth Charges *(helicopters and planes)*

Area-effect weapon. No homing — requires a positional fix first. Drops a pattern of charges along the aircraft's current heading; each sinks to the set depth and detonates. Charges that spawn over land are discarded silently.

| Command | Description |
|---|---|
| **Set Detonation Depth** | 25m, 50m, 100m, 150m, 200m, 300m |
| **Set Count** | 1, 2, 4, 6, or 8 charges per drop |
| **Set Spacing** | 100m, 200m, 400m, or 600m between charges |
| **Prepare to Drop** | Enter drop mode. HUD shows heading, pattern, and flight params. |
| **Drop!** | Release the pattern along current heading. |

Depth charge specifications:
- Sink rate: **3 m/s** (50m depth → ~17s, 200m → ~67s)
- Kill radius: **80m** (3D distance from detonation point)
- Pattern extends **forward** from the drop point along the aircraft's heading
- Charges over land are discarded with a log message — no explosion
- Drop altitude/speed limits are more relaxed than buoys (configured separately per hunter type)
- Helicopter default: **4 charges** | Alt < 150m AGL | Speed < ~155 kt
- Fixed-wing default: **16 charges** | Alt < 500m AGL | Speed < ~389 kt
- Submarine coalition receives **"Depth charges in the water!"** warning (uses torpedo warning sound)
- Restocked at rearm zone

#### MAD Detector *(fixed-wing only)*

Magnetic Anomaly Detector — senses distortions in Earth's magnetic field caused by a submarine's steel hull. Close-range precision tool: use sonobuoys to cue the area first, then overfly for a MAD confirmation before torpedo delivery.

| Command | Description |
|---|---|
| **Activate MAD** | Start scanning. Charge begins draining. |
| **Deactivate MAD** | Stop scanning. Charge begins recharging. |
| **Set Search Depth** | Choose sensitivity/depth: 50m, 100m, 150m, 200m. Deeper = faster drain. |
| **MAD Status** | Show state, charge %, drain rate, and time remaining. |

MAD specifications:
- Detection range: **500m horizontal** at 50m AGL, scales down with altitude (inverse cube law)
- Operating altitude: max **150m AGL** — above this the signal is too weak
- Does **not detect noise makers** — ferrous steel hulls only
- Detects subs shallower than the configured search depth (probability drops off toward that limit)
- Contact markers shown in **orange** on the F10 map (30 second duration), visible to ASW coalition only
- Contact shows horizontal position only — **depth is unknown** from MAD
- **Charge system**: represents continuous power draw and sensor heating
  - Drains while active; recharges while inactive
  - Drain rate: `0.2 + searchDepth × 0.002` %/sec (e.g. 0.4%/s at 100m → ~250s of use)
  - Recharge: 0.25%/sec → ~400s for full recharge from empty
  - Auto-deactivates at 0% charge; fully recharged at rearm zone
- Submarine side receives a vague warning when swept

#### General

| Command | Description |
|---|---|
| **Cancel** | Cancel current prepare operation |
| **Status** | Show buoy inventory (fresh/saved/expired), deployed counts (active/dead), torpedo inventory, MAD state, global pool size, current state |
| **Rearm** | Revive expired buoys, top up from global pool, restock torpedoes, repair dipping sonar, recharge MAD. Must be near a `rearmUnit` carrier **or** inside the `rearmZone` — both are valid. |

---

## Submarine Side (RED)

### F10 Menu: Submarine Command

Available as coalition menu for the submarine's coalition.

#### Navigation

| Command | Description |
|---|---|
| **Change Heading** | Adjust heading: ±5°, ±10°, ±25°, ±50°, ±90° (applied to target heading) |
| **Set Heading** | Set absolute heading: N, NE, E, SE, S, SW, W, NW |
| **Change Speed** | Adjust speed: ±1, ±2, ±5, ±10 m/s (applied to target speed) |
| **Set Speed** | Jump to an absolute speed preset — Stop, Silent, 25%, 50%, 75%, Full Speed (rounded to whole m/s, computed from `maxSpeed`) |
| **Change Depth** | Adjust depth: ±10m, ±25m, ±50m, ±100m |
| **Dive (max depth)** | Go to maximum operating depth (inside Change Depth) |
| **Periscope Depth** | Rise to 20m — inside Change Depth (required for torpedo launch) |
| **Level (hold depth)** | Hold current depth — inside Change Depth |
| **Set Depth** | Jump to an absolute depth preset — see below |

The status display shows both current and target values: `Hdg: 270° -> 315° | Spd: 3.5 -> 8 m/s`

**Set Depth presets** (computed at mission start from the configured thermal layer and submarine type):

| Entry | Depth |
|---|---|
| Periscope | 20m (fixed) |
| Above Layer | `thermalLayerDepth − 10` (e.g. 80m if layer is 90m) |
| Below Layer | `thermalLayerDepth + 10` (e.g. 100m if layer is 90m) |
| Fixed steps | 150m, 200m, 250m … up to `maxDepth` in 50m increments |
| Max (if needed) | `maxDepth` added as a labelled entry when it doesn't fall on a 50m step |

Steps that would duplicate an Above/Below Layer entry are skipped automatically.

#### Torpedoes (Anti-Ship)

| Command | Description |
|---|---|
| **Fire Torpedo!** | Launch torpedo on submarine's current heading. Must be at periscope depth (< 30m). |
| **Torpedo Status** | Show remaining count, active torpedoes, depth readiness. |

Submarine torpedo specifications:
- Speed: 40 knots (20.58 m/s)
- Turn rate: 3°/s
- Sonar: ±30° forward cone, 10 km range, probability-based detection
- Kill radius: 50m
- Arming delay: 5 seconds
- Battery: 300 seconds (5 minutes)
- Explosion power: 5000 (destroys DCS ship units)
- Targets any enemy coalition ship
- If contact is lost, turns back toward last known position
- Torpedo trail is **visible to all coalitions** as a red line
- If launched within range of a sonarbuoy, the buoy instantly marks the **exact launch position** with 100% confidence

#### Noise Makers (Decoys)

| Command | Description |
|---|---|
| **Deploy Noise Maker** | Deploy at current position with activation delay: 60s, 120s, 180s, or 240s |
| **Noise Maker Status** | Show remaining count, standby/active counts |

Noise maker specifications:
- Deployed at submarine's current position and depth
- Activates after the chosen delay (sub can move away before activation)
- Drifts slowly (~6 kts) in a random direction to simulate a moving submarine
- Noise factor: 2.0 (very loud — high detection probability by buoys)
- Battery: 10 minutes of active noise
- **Buoys cannot distinguish noise makers from real submarines** — contacts look identical
- ASW torpedoes can home on and destroy noise makers (announced as "hit a decoy")
- Marker visible to submarine coalition only (shows STANDBY countdown or ACTIVE timer)

### Passive Sonar

The submarine automatically scans for enemy surface ships every 30 seconds:

- Detection range: 15 km (diesel) / 20 km (SSN)
- Below thermal layer: range reduced to 30% (diesel) / 50% (SSN)
- Probability-based: 90% at close range, dropping with distance
- Contact markers show estimated position with uncertainty (bearing error up to ±20°, range error up to ±20%)
- Markers show ship name, estimated heading, and confidence percentage
- One marker per detected ship, updated in place each scan (removed when ship leaves detection range)
- Visible to submarine coalition only

---

## AI Submarine Commander

An automated commander that replaces or supplements the human submarine controller.

### Setup

Set `COMMANDER_MODE` in `asw_config.lua`:

```lua
COMMANDER_MODE = "human"    -- F10 menu only
COMMANDER_MODE = "ai"       -- AI control only
COMMANDER_MODE = "both"     -- Human menu + AI (AI takes priority)
```

Configure AI behavior in the `AI_CONFIG` table:

```lua
local AI_CONFIG = {
    waypointZones   = {"patrol_1", "patrol_2", "patrol_3", "patrol_4"},
    randomPatrol    = true,         -- true = random order, false = sequential loop
    enableAttack    = true,         -- false = patrol only, never attack or fire torpedoes
    patrolSpeed     = 5,
    patrolDepth     = 80,
    attackRange     = 12000,
    evasionBuoyRange = 7000,
    evasionDuration = 180,
    profile         = "cautious",   -- or "aggressive"
}
```

### Profiles

| Setting | Aggressive | Cautious |
|---|---|---|
| Attack range | 15 km | 10 km |
| Approach speed | 8 m/s | 4 m/s |
| Torpedo firing range | 8 km | 5 km |
| Evasion speed | 3 m/s | 1 m/s |
| Evasion duration | 2 min | 4 min |
| Go silent chance | 30% | 70% |

### Behavior State Machine

**PATROL** → **ATTACK** → **EVADE** → **PATROL**

- **PATROL**: Visits waypoint zones in random order (default) or sequentially in the order defined (`randomPatrol = false`), looping back to the first zone on completion. Uses passive sonar to scan for enemy ships. Moves at configured patrol speed and depth. If `enableAttack = false`, detected ships are ignored and the sub stays in patrol.
- **ATTACK**: Ship detected within attack range → turns toward target, rises to periscope depth, approaches, fires 2-torpedo salvo, then pre-deploys a noise maker (30s delay) to mask the retreat, dives deep, and evades to a random waypoint.
- **EVADE (buoy trigger)**: Sonarbuoy deployed within 7 km → dives to max depth, heads away from buoy (±90° randomized cone), reduces speed. Conserves noise makers for higher-priority threats.
- **EVADE (depth charge trigger)**: Depth charge detonates within 1.5 km → sharp random heading change (±90–150°), dives to or below the thermal layer, sprints away briefly, deploys noise maker (30s delay aggressive / 60s cautious). Has a 20-second cooldown so a full charge pattern only triggers one reaction. Interrupts buoy/sonar evasion but not torpedo evasion.
- **EVADE (dipping sonar trigger)**: Active dipping sonar detected within 10 km → dives to max depth, heads away from helicopter (±90° randomized cone), deploys noise maker with 60s delay to confuse the active sonar. Higher priority than passive buoys.
- **EVADE (torpedo trigger — highest priority)**: ASW torpedo detected within 10 km → immediately deploys noise maker, random depth change (deep or 100m shallower), goes silent or crawls based on profile, random heading. Re-deploys noise makers if torpedo persists. Resets evasion timer.

---

## Detection Model

All sonar detection uses a probability-based model. **Passive sonobuoys give bearing only** (no range, no depth) — cross-referencing two or more bearing lines is required to fix a position. Active sensors (dipping sonar, ASW torpedoes) give full position estimates.

### Buoy Detection Formula

```
effectiveNoise = submarine.speed × submarine.noiseFactor
depthPenalty = max(0.1, 1 - depth/500)
thermalPenalty = 1.0 (above layer) or 0.2 (below layer)
distanceFactor = 1 - distance/maxRange
probability = effectiveNoise × depthPenalty × thermalPenalty × distanceFactor × 0.15
```

### ASW Torpedo Detection Formula

```
effectiveNoise = submarine.speed × submarine.noiseFactor
depthPenalty = max(0.1, 1 - depth/500)
thermalPenalty = 1.0 (same side of layer) or 0.2 (opposite sides)
distanceFactor = 1 - distance/1500
probability = effectiveNoise × depthPenalty × thermalPenalty × distanceFactor × 0.15
```

- Thermal penalty applies when torpedo and target are on **opposite sides** of the thermal layer

### Dipping Sonar Detection Formula

```
effectiveNoise = submarine.speed × submarine.noiseFactor
depthPenalty = max(0.1, 1 - depth/500)
thermalPenalty = 1.0 (both on same side of layer) or 0.2 (sonar above, sub below)
distanceFactor = 1 - distance/8000
probability = effectiveNoise × depthPenalty × thermalPenalty × distanceFactor × 0.25
```

- Same model as buoys but with **0.25** scale factor (vs 0.15), **8 km** range, and **3 second** ping interval
- Thermal penalty is based on cable depth vs sub depth relative to thermal layer — lowering the cable below the layer removes the penalty
- Position estimated with bearing error (±30°) and range error (±25%), depth error (±30%), all scaled by confidence

### Common Detection Properties

- Probability clamped to [0, 0.95]
- A stationary or very slow sub (effectiveNoise < 0.1) is undetectable
- **Sonobuoys**: bearing only (±0–30° error scaled by confidence). No range, no depth.
- **Dipping sonar**: full position estimate with bearing error (±30°), range error (±25%), depth error (±30%), all scaled by confidence

### Submarine Torpedo Ship Detection

```
probability = 0.8 × distanceFactor
```

- Forward cone only (±30° from heading)
- Ships are real DCS units — position is known exactly on detection

### Submarine Passive Sonar

```
probability = 0.9 × distanceFactor
```

- 360° detection
- Effective range reduced when sub is below thermal layer
- Position estimated with bearing error (±20°) and range error (±20%)

---

## Configuration Reference

All values are configurable in the `asw_config.lua` configuration tables:

```lua
-- 1. Coalitions
SUB_COALITION = coalition.side.RED
ASW_COALITION = coalition.side.BLUE

-- 2. Environment
THERMAL_LAYER_DEPTH = 90

-- 3. Submarine
SUB_CONFIG = {
    type            = "diesel",                     -- "diesel", "ssn", or "custom"
    name            = "Kursk",
    spawnZone       = {"spawn_1", "spawn_2", "spawn_3"},  -- or a single string: "Submarine_initial_position"
    startDepth      = 60,
    startSpeed      = 8,
    startHeading    = 270,
    randomizeSpawn  = false,
    -- Custom type only:
    noiseFactor     = 1.0,
    maxSpeed        = 15,
    maxDepth        = 300,
}

-- 4. Commander
COMMANDER_MODE = "human"        -- "human", "ai", or "both"
AI_CONFIG = {
    waypointZones   = {"patrol_1", "patrol_2", "patrol_3", "patrol_4"},
    randomPatrol    = true,     -- true = random order, false = sequential loop
    enableAttack    = true,     -- false = patrol only, never attack or fire torpedoes
    patrolSpeed     = 5,
    patrolDepth     = 80,
    attackRange     = 12000,
    evasionBuoyRange = 7000,
    evasionDuration = 180,
    profile         = "cautious",
}

-- 5. ASW Hunters
HELO_CONFIG = {
    prefix          = "_asw_helo",      -- group name prefix for helicopters
    rearmZone       = "ASW_Hunter_Rearming",
    rearmUnits      = {},               -- carrier unit names (e.g. {"CVN-74", "CVN-75"}); checked alongside rearmZone
    rearmRadius     = 500,
    maxBuoys        = 4,
    maxTorpedoes    = 2,
    maxDepthCharges = 4,
    maxAltitude     = 50,               -- max AGL for buoy/torpedo deploy (meters)
    maxSpeed        = 60,               -- max speed for buoy/torpedo deploy (m/s)
    dcMaxAltitude   = 150,              -- max AGL for depth charge drop (meters)
    dcMaxSpeed      = 80,               -- max speed for depth charge drop (m/s)
    recoveryRange   = 10,
    detectInterval  = 5,
}

PLANE_CONFIG = {
    prefix          = "_asw_plane",     -- group name prefix for fixed-wing
    rearmZone       = "ASW_Hunter_Rearming",
    rearmUnits      = {},
    rearmRadius     = 500,
    maxBuoys        = 8,
    maxTorpedoes    = 2,
    maxDepthCharges = 16,
    maxAltitude     = 200,              -- max AGL for buoy/torpedo deploy (meters)
    maxSpeed        = 120,              -- max speed for buoy/torpedo deploy (m/s)
    dcMaxAltitude   = 500,              -- max AGL for depth charge drop (meters)
    dcMaxSpeed      = 200,              -- max speed for depth charge drop (m/s)
    detectInterval  = 5,
    madConfig       = {
        detectionRange  = 500,   -- horizontal detection radius at optimal altitude (meters)
        maxSearchDepth  = 200,   -- deepest available search depth setting (meters)
        maxAltitude     = 150,   -- max AGL for MAD operation (meters)
        drainBase       = 0.2,   -- charge drain %/sec at minimum depth
        drainPerMeter   = 0.002, -- additional drain %/sec per meter of search depth
        rechargeRate    = 0.25,  -- charge recovery %/sec when inactive
    },
}

-- 6. Sonarbuoy supply
BUOY_CONFIG = {
    lifetime   = 1800,  -- battery life per buoy in seconds (nil = unlimited)
    globalPool = 10,    -- reserve buoys at the carrier, shared across all hunters
}
```

---

## File Overview

| File | Class | Purpose |
|---|---|---|
| `submarine.lua` | `VirtualSubmarine` | Virtual submarine entity with movement, turning, depth, thermal layer, passive sonar |
| `sonarbuoy.lua` | `Sonarbuoy` | Deployable acoustic sensor with probabilistic detection |
| `noiseMaker.lua` | `NoiseMaker` | Submarine decoy that mimics sub noise signature |
| `anti_submarine_torpedo.lua` | `AntiSubmarineTorpedo` | Player-launched ASW torpedo with active homing sonar |
| `submarineTorpedo.lua` | `SubmarineTorpedo` | Submarine-launched anti-ship torpedo with cone sonar |
| `dippingSonar.lua` | `DippingSonar` | Active dipping sonar deployed from hovering helicopter |
| `depthCharge.lua` | `DepthCharge` | Single depth charge: land-check on spawn, sinks to set depth, 80m kill radius |
| `madDetector.lua` | `MADDetector` | Magnetic Anomaly Detector for fixed-wing; charge-limited, altitude-dependent |
| `soundScheduler.lua` | `SoundScheduler` | Priority-based sound playback scheduler per group |
| `ordnanceManager.lua` | `OrdnanceManager` | Base class: buoy deploy, torpedo launch, inventory, rearm, F10 menus |
| `helicopterHunterManager.lua` | `HelicopterHunterManager` | Extends base with dipping sonar and buoy recovery |
| `planeHunterManager.lua` | `PlaneHunterManager` | Extends base with fixed-wing altitude/speed limits; no dipping sonar |
| `humanSubmarineCommander.lua` | `HumanSubmarineCommander` | F10 menus for human submarine control |
| `aiSubmarineCommander.lua` | `AISubmarineCommander` | Autonomous submarine AI with patrol/attack/evade states |
| `asw_config.lua` | — | Main entry point, configuration, wiring |
