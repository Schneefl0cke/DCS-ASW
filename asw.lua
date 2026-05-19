local debug = trigger.misc.getUserFlag("Debug")

local function debugMessage(message, duration)
    if debug == 1 then
        duration = duration or 10
        trigger.action.outText(message, duration, false)
        env.info(message, false)
    end
end

-- ===== COALITION CONFIGURATION =====
local SUB_COALITION = coalition.side.RED   -- Submarine owner
local ASW_COALITION = coalition.side.BLUE  -- ASW forces (sonarbuoys, hunters)

-- ===== ENVIRONMENT =====
local THERMAL_LAYER_DEPTH = 90  -- Depth in meters. Subs below this are much harder to detect

-- ===== ASW HUNTER CONFIG =====
local HUNTER_PREFIX = "_asw_hunter"          -- Group name prefix for ASW hunter aircraft
local HUNTER_REARM_ZONE = "ASW_Hunter_Rearming"  -- Trigger zone for rearming (static fallback)
local HUNTER_REARM_UNIT = nil                     -- Set to carrier unit name for moving rearm (e.g. "CVN-74")
local HUNTER_REARM_RADIUS = 500                   -- Meters around rearmUnit
local HUNTER_MAX_BUOYS = 4                   -- Max buoys per hunter group
local HUNTER_MAX_ALTITUDE = 50               -- Max AGL in meters for deploy/recover
local HUNTER_MAX_SPEED = 60                  -- Max speed in m/s for deploy/recover
local HUNTER_RECOVERY_RANGE = 200            -- Max distance in meters to recover a buoy
local BUOY_DETECT_INTERVAL = 5               -- Seconds between detection cycles
local HUNTER_MAX_TORPEDOES = 1                -- Max torpedoes per hunter group

-- ===== SUBMARINES =====
local ghostSub = VirtualSubmarine:newDieselFromZone("Kursk", "Submarine_initial_position", 60, 8, 270, SUB_COALITION, THERMAL_LAYER_DEPTH, false)

-- ===== SONARBUOYS =====
local submarines = {ghostSub}
local debugBuoy = Sonarbuoy:newFromZone("Buoy-Debug", "buoy_debug", ASW_COALITION, nil, THERMAL_LAYER_DEPTH)

-- ===== ORDNANCE MANAGER =====
local ordnanceManager = OrdnanceManager:new({
    ownerCoalition = ASW_COALITION,
    submarines = submarines,
    hunterPrefix = HUNTER_PREFIX,
    rearmZone = HUNTER_REARM_ZONE,
    rearmUnit = HUNTER_REARM_UNIT,
    rearmRadius = HUNTER_REARM_RADIUS,
    maxBuoys = HUNTER_MAX_BUOYS,
    maxTorpedoes = HUNTER_MAX_TORPEDOES,
    maxAltitude = HUNTER_MAX_ALTITUDE,
    maxSpeed = HUNTER_MAX_SPEED,
    recoveryRange = HUNTER_RECOVERY_RANGE,
    thermalLayerDepth = THERMAL_LAYER_DEPTH,
    detectInterval = BUOY_DETECT_INTERVAL
})

-- ===== COMMANDERS =====
-- Human Commander: F10 menu for submarine coalition
-- Pass the shared 'submarines' table so deployed noise makers get added to it for buoy detection
local humanCommander = HumanSubmarineCommander:new(SUB_COALITION, {ghostSub}, ASW_COALITION, ordnanceManager.buoys, submarines)

-- AI Commander: uncomment to use instead of (or alongside) human commander
-- local aiCommander = AISubmarineCommander:new(ghostSub, {
--     waypointZones = {"patrol_1", "patrol_2", "patrol_3", "patrol_4"},
--     patrolSpeed = 5,
--     patrolDepth = 80,
--     attackRange = 12000,
--     evasionBuoyRange = 7000,
--     evasionDuration = 180,
--     profile = "cautious",  -- "aggressive" or "cautious"
--     targetCoalition = ASW_COALITION,
--     buoys = ordnanceManager.buoys,
--     torpedoes = ordnanceManager.torpedoes,
--     detectableObjects = submarines,
--     dippingSonars = ordnanceManager:getDippingSonars(),
-- })

function SubmarineActionLoop()
    if ghostSub then
        ghostSub:update()
        local data = ghostSub:getTelemetry()
        debugMessage(string.format("%s current position -> X: %.0f, Z: %.0f", data.name, data.x, data.z), 1)
    else
        debugMessage("Ghost submarine not initialized!", 10)
    end

    timer.scheduleFunction(function()
        SubmarineActionLoop() 
    end, nil, timer.getTime() + 1)
end

-- Debug buoy detection loop (separate from manager)
function DebugBuoyLoop()
    if debugBuoy and debugBuoy:isActive() then
        debugBuoy:detect(submarines)
    end

    timer.scheduleFunction(function()
        DebugBuoyLoop()
    end, nil, timer.getTime() + BUOY_DETECT_INTERVAL)
end

SubmarineActionLoop()
DebugBuoyLoop()

-- Spawn debug torpedo in trigger zone after 5 seconds
timer.scheduleFunction(function()
    local zone = trigger.misc.getZone("ASW_TORPEDO_DEBUG")
    if zone then
        local torpedo = AntiSubmarineTorpedo:new(
            "Debug-ASW-Torpedo",
            zone.point.x,
            zone.point.z,
            0,                      -- Initial heading (north)
            80,                     -- Search depth (meters)
            ASW_COALITION,          -- Owner coalition (BLUE)
            submarines,             -- Target submarines (RED)
            THERMAL_LAYER_DEPTH     -- Thermal layer depth
        )
        ordnanceManager.torpedoes[#ordnanceManager.torpedoes + 1] = torpedo
        debugMessage("Debug ASW torpedo spawned in zone ASW_TORPEDO_DEBUG at 80m depth", 10)
    else
        debugMessage("WARNING: Trigger zone 'ASW_TORPEDO_DEBUG' not found!", 10)
    end
end, nil, timer.getTime() + 5)

debugMessage("ASW testlab started.", 10)