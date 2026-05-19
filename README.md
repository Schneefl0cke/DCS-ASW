# DCS Anti-Submarine Warfare (ASW) Scripting Framework

A two-sided ASW game system for DCS World using MOOSE framework. One side operates a virtual submarine (human or AI controlled), the other side hunts it with ASW aircraft equipped with sonarbuoys and torpedoes.

## Requirements

- DCS World
- MOOSE framework loaded before these scripts
- User flag `Debug` set to `1` for debug messages (optional)

## Script Load Order

Load scripts in this order in the DCS Mission Editor (DO ONCE triggers):

1. `submarine.lua`
2. `sonarbuoy.lua`
3. `noiseMaker.lua`
4. `anti_submarine_torpedo.lua`
5. `submarineTorpedo.lua`
6. `dippingSonar.lua`
7. `ordnanceManager.lua`
8. `humanSubmarineCommander.lua`
9. `aiSubmarineCommander.lua`
10. `asw.lua`

## Mission Editor Setup

### Required Trigger Zones

| Zone Name | Purpose |
|---|---|
| `Submarine_initial_position` | Spawn location for the submarine |
| `ASW_Hunter_Rearming` | Circle zone where ASW aircraft land/hover to rearm (static fallback, not needed if using `rearmUnit`) |
| `buoy_debug` | Debug sonarbuoy position (can be removed for production) |
| `patrol_1`, `patrol_2`, ... | Patrol waypoints for AI submarine commander (only needed if using AI) |

### Required Groups

- ASW hunter aircraft groups must have **`_asw_hunter`** in their group name (configurable via `hunterPrefix`). Each group should be a single aircraft (helicopter recommended).

### Coalition Setup

- **RED**: Submarine side (default)
- **BLUE**: ASW hunter side (default)

Both are configurable in `asw.lua`.

---

## Submarine Types

| Type | Noise Factor | Max Speed | Max Depth | Torpedoes | Noise Makers | Sonar Range | Thermal Penalty |
|---|---|---|---|---|---|---|---|
| Default | 1.0 | 15 m/s | 300m | 6 | 4 | 15 km | 0.3x |
| Diesel | 0.5 | 10 m/s (~20 kts) | 250m | 6 | 4 | 15 km | 0.3x |
| SSN | 0.8 | 18 m/s (~35 kts) | 500m | 10 | 6 | 20 km | 0.5x |

Create submarines using:
```lua
VirtualSubmarine:newDieselFromZone("Name", "ZoneName", depth, speed, heading, coalition, thermalLayerDepth, randomize)
VirtualSubmarine:newSSNFromZone("Name", "ZoneName", depth, speed, heading, coalition, thermalLayerDepth, randomize)
```

---

## The Thermal Layer

A configurable depth (default 90m) that divides the water column:

- **Above**: Sonarbuoys detect submarines normally
- **Below**: Detection probability is severely reduced (0.2x multiplier for buoys)
- Submarine passive sonar is also affected: diesel gets 0.3x range, SSN gets 0.5x range when below the layer

The thermal layer is the core tactical element. Submarines want to stay below it; hunters need to account for it when choosing buoy deployment strategy.

---

## ASW Hunter Side (BLUE)

### F10 Menu: ASW Operations

Available under the group radio menu for any aircraft group with `_asw_hunter` in its name.

#### Sonarbuoys

| Command | Description |
|---|---|
| **Prepare to Launch Buoy** | Enter launch mode. HUD shows altitude/speed readiness. |
| **Launch Buoy!** | Deploy a sonarbuoy at current position. Requires: Alt < 50m AGL, Speed < 60 m/s. |
| **Prepare to Recover Buoy** | Enter recovery mode. HUD shows nearest buoy distance. |
| **Recover Buoy!** | Pick up nearest buoy within 200m. Returns it to inventory. |

- Each hunter carries **4 buoys** (configurable)
- Buoys detect submarines every 5 seconds using a probability-based model
- Detection probability depends on: submarine noise (speed × noise factor), distance, depth, and thermal layer
- Contact markers appear on the F10 map for 30 seconds with estimated position, depth, and confidence percentage
- Buoy position markers are **visible to both coalitions** — the submarine side can see where buoys are deployed
- The submarine coalition receives a **warning message** when a buoy is deployed

#### Torpedo (ASW)

| Command | Description |
|---|---|
| **Set Search Depth** | Choose torpedo run depth: 0m, 100m, 200m, 300m, 400m, or 500m |
| **Prepare to Launch Torpedo** | Enter launch mode. HUD shows heading + depth setting. |
| **Launch Torpedo!** | Fire torpedo on player's current heading. Same flight parameter requirements as buoys. |

- Each hunter carries **1 torpedo** (configurable)
- Speed: 30 knots (15.43 m/s)
- Turn rate: 3°/s
- Sonar range: 1.5 km (same detection formula as buoys, checked every second)
- Kill radius: 150m horizontal + 50m depth tolerance
- Battery: 180 seconds (3 minutes)
- If the torpedo acquires a target then loses it, it turns back toward the last known position
- If the torpedo hits a **noise maker** instead of a real sub, it destroys the decoy and announces it
- The submarine coalition receives a **warning** when an ASW torpedo is launched
- Torpedo marker is **visible to all coalitions** on the F10 map

#### Dipping Sonar

| Command | Description |
|---|---|
| **Set Cable Depth** | Choose sonar depth: 10m, 30m, 50m, 70m, or 100m |
| **Lower Sonar** | Deploy the dipping sonar at the set cable depth |
| **Raise Sonar** | Retrieve the dipping sonar back into the aircraft |

Dipping sonar specifications:
- Active sonar with **8 km detection range** and **0.25 scale factor** (more effective than passive buoys)
- Cable depth: 0–100m (adjustable via presets, can be changed while active)
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

#### General

| Command | Description |
|---|---|
| **Cancel** | Cancel current prepare operation |
| **Status** | Show buoy/torpedo inventory, active counts, current state |
| **Rearm** | Restock buoys and torpedoes. Must be near the rearm zone or carrier. |

---

## Submarine Side (RED)

### F10 Menu: Submarine Command

Available as coalition menu for the submarine's coalition.

#### Navigation

| Command | Description |
|---|---|
| **Change Heading** | Adjust heading: ±5°, ±10°, ±20° |
| **Change Speed** | Adjust speed: ±1, ±2, ±5 m/s |
| **Change Depth** | Adjust depth: ±5m, ±10m, ±20m |
| **Dive (max depth)** | Go to maximum operating depth |
| **Periscope Depth** | Rise to 20m (required for torpedo launch) |
| **Level (hold depth)** | Hold current depth |

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
- Torpedo marker is **visible to all coalitions**
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

Create patrol waypoint trigger zones in the Mission Editor (`patrol_1`, `patrol_2`, etc.), then uncomment the AI commander block in `asw.lua`:

```lua
local aiCommander = AISubmarineCommander:new(ghostSub, {
    waypointZones = {"patrol_1", "patrol_2", "patrol_3", "patrol_4"},
    patrolSpeed = 5,
    patrolDepth = 80,
    attackRange = 12000,
    evasionBuoyRange = 7000,
    evasionDuration = 180,
    profile = "cautious",  -- or "aggressive"
    targetCoalition = ASW_COALITION,
    buoys = ordnanceManager.buoys,
    torpedoes = ordnanceManager.torpedoes,
    detectableObjects = submarines,
    dippingSonars = ordnanceManager:getDippingSonars(),
})
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

- **PATROL**: Follows randomly shuffled waypoint zones. Uses passive sonar to scan for enemy ships. Moves at configured patrol speed and depth.
- **ATTACK**: Ship detected within attack range → turns toward target, rises to periscope depth, approaches, fires 2-torpedo salvo, then immediately dives deep and evades to a random waypoint.
- **EVADE (buoy trigger)**: Sonarbuoy deployed within 7 km → dives to max depth, heads away from buoy (±90° randomized cone), reduces speed. Conserves noise makers for torpedo threats.
- **EVADE (dipping sonar trigger)**: Active dipping sonar detected within 10 km → dives to max depth, heads away from helicopter (±90° randomized cone), deploys noise maker with 60s delay to confuse the active sonar. Higher priority than passive buoys.
- **EVADE (torpedo trigger — highest priority)**: ASW torpedo detected within 10 km → immediately deploys noise maker, random depth change (deep or 100m shallower), goes silent or crawls based on profile, random heading. Re-deploys noise makers if torpedo persists. Resets evasion timer.

---

## Detection Model

All sonar detection (buoys, ASW torpedoes, submarine passive sonar) uses a probability-based model:

### Buoy / ASW Torpedo Detection Formula

```
effectiveNoise = submarine.speed × submarine.noiseFactor
depthPenalty = max(0.1, 1 - depth/500)
thermalPenalty = 1.0 (above layer) or 0.2 (below layer)
distanceFactor = 1 - distance/maxRange
probability = effectiveNoise × depthPenalty × thermalPenalty × distanceFactor × 0.15
```

- Clamped to [0, 0.95]
- A stationary or very slow sub (effectiveNoise < 0.1) is undetectable
- On successful detection, position is estimated with bearing error (±30°) and range error (±25%), both scaled by confidence

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

All values are configurable in `asw.lua`:

```lua
-- Coalitions
SUB_COALITION = coalition.side.RED
ASW_COALITION = coalition.side.BLUE

-- Environment
THERMAL_LAYER_DEPTH = 90        -- meters

-- Hunter aircraft
HUNTER_PREFIX = "_asw_hunter"   -- group name must contain this
HUNTER_REARM_ZONE = "ASW_Hunter_Rearming"
HUNTER_REARM_UNIT = nil          -- set to carrier unit name (e.g. "CVN-74") for moving rearm point
HUNTER_REARM_RADIUS = 500        -- meters around rearmUnit
HUNTER_MAX_BUOYS = 4
HUNTER_MAX_TORPEDOES = 1
HUNTER_MAX_ALTITUDE = 50        -- meters AGL for deploy/launch
HUNTER_MAX_SPEED = 60           -- m/s for deploy/launch
HUNTER_RECOVERY_RANGE = 200     -- meters to recover buoy
BUOY_DETECT_INTERVAL = 5        -- seconds between buoy scans
```

---

## File Overview

| File | Class | Purpose |
|---|---|---|
| `submarine.lua` | `VirtualSubmarine` | Virtual submarine entity with movement, depth, thermal layer, passive sonar |
| `sonarbuoy.lua` | `Sonarbuoy` | Deployable acoustic sensor with probabilistic detection |
| `noiseMaker.lua` | `NoiseMaker` | Submarine decoy that mimics sub noise signature |
| `anti_submarine_torpedo.lua` | `AntiSubmarineTorpedo` | Player-launched ASW torpedo with active homing sonar |
| `submarineTorpedo.lua` | `SubmarineTorpedo` | Submarine-launched anti-ship torpedo with cone sonar |
| `dippingSonar.lua` | `DippingSonar` | Active dipping sonar deployed from hovering helicopter |
| `ordnanceManager.lua` | `OrdnanceManager` | Manages hunter group menus, inventory, buoy/torpedo/sonar operations |
| `humanSubmarineCommander.lua` | `HumanSubmarineCommander` | F10 menus for human submarine control |
| `aiSubmarineCommander.lua` | `AISubmarineCommander` | Autonomous submarine AI with patrol/attack/evade states |
| `asw.lua` | — | Main entry point, configuration, wiring |
