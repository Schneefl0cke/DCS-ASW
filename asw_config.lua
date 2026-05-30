-- =============================================================================
-- ASW MISSION CONFIGURATION
-- =============================================================================
-- Edit the settings below to configure your ASW mission.
-- Set the Debug user flag to 1 in the Mission Editor for debug messages.
-- =============================================================================

local debug = trigger.misc.getUserFlag("Debug")

local function debugMessage(message, duration)
    if debug == 1 then
        duration = duration or 10
        trigger.action.outText(message, duration, false)
        env.info(message, false)
    end
end

-- =============================================================================
-- 1. COALITION SETUP
-- =============================================================================
-- Which coalition owns the submarine, and which runs ASW operations?

local SUB_COALITION = coalition.side.RED
local ASW_COALITION = coalition.side.BLUE

-- =============================================================================
-- 2. ENVIRONMENT
-- =============================================================================
-- The thermal layer is the key tactical element. Submarines below this depth
-- are much harder to detect by sonarbuoys and torpedoes above it (and vice versa).

local THERMAL_LAYER_DEPTH = 90  -- meters

-- =============================================================================
-- 3. SUBMARINE CONFIGURATION
-- =============================================================================
-- Choose submarine type: "diesel", "ssn", or "custom"
-- Spawn zone must exist as a trigger zone in the Mission Editor.

local SUB_CONFIG = {
    type            = "ssn",                     -- "diesel", "ssn", or "custom"
    name            = "Red Dragon",                      -- Display name
    spawnZone       = {"spawn_1", "spawn_2", "spawn_3"},  -- Trigger zone name (e.g. "Submarine_initial_position"), or a table of names for a random pick: {"zone_a", "zone_b", "zone_c"}
    startDepth      = 20,                           -- Starting depth in meters
    startSpeed      = 2,                            -- Starting speed in m/s
    startHeading    = 120,                          -- Starting heading in degrees
    randomizeSpawn  = true,                        -- Randomize position within zone?

    -- Custom type only (ignored for diesel/ssn):
    noiseFactor     = 1.0,
    maxSpeed        = 15,
    maxDepth        = 300,
}

-- =============================================================================
-- 4. SUBMARINE COMMANDER
-- =============================================================================
-- "human"  = F10 coalition menu control
-- "ai"     = Autonomous AI patrol and attack
-- "both"   = Both human menu and AI (AI takes priority)

local COMMANDER_MODE = "human"

-- AI Commander settings (only used when mode is "ai" or "both"):
local AI_CONFIG = {
    waypointZones   = {"patrol_1", "patrol_2", "patrol_3", "patrol_4"},
    randomPatrol    = true,     -- true = random order, false = sequential loop
    enableAttack    = true,     -- false = patrol only, never attack or fire torpedoes
    patrolSpeed     = 5,        -- m/s while patrolling
    patrolDepth     = 80,       -- meters while patrolling
    attackRange     = 12000,    -- meters to engage detected ships
    evasionBuoyRange = 7000,   -- distance to buoy that triggers evasion
    evasionDuration = 180,      -- seconds to evade before resuming patrol
    profile         = "cautious", -- "aggressive" or "cautious"
}

-- =============================================================================
-- 5. ASW HUNTER CONFIGURATION
-- =============================================================================
-- Helicopter hunters: dipping sonar + buoy recovery + torpedo.
-- Group names must contain the prefix defined below.

local HELO_CONFIG = {
    prefix          = "_asw_helo",                  -- Group name prefix for helicopters
    rearmZone       = "ASW_Hunter_Rearming",        -- Trigger zone for rearming (static); checked alongside rearmUnits
    rearmUnits      = {"Achilles", "Ariadne", "Andromeda", "Invincible"},                           -- Carrier unit names (e.g. {"CVN-74", "CVN-75"}); checked alongside rearmZone
    rearmRadius     = 500,                          -- Meters around each rearmUnit
    maxBuoys        = 4,                            -- Sonarbuoys per hunter
    maxTorpedoes    = 2,                            -- ASW torpedoes per hunter
    maxDepthCharges = 4,                            -- Depth charges per hunter
    maxAltitude     = 50,                           -- Max AGL for buoy/torpedo deploy (meters)
    maxSpeed        = 60,                           -- Max speed for buoy/torpedo deploy (m/s)
    dcMaxAltitude   = 150,                          -- Max AGL for depth charge drop (meters)
    dcMaxSpeed      = 80,                           -- Max speed for depth charge drop (m/s)
    recoveryRange   = 10,                           -- Max distance to recover a buoy (meters)
    detectInterval  = 5,                            -- Seconds between sonarbuoy detection cycles
}

-- Fixed-wing hunters: buoy deployment + torpedo. No dipping sonar, no buoy recovery.
-- Group names must contain the prefix defined below.

local PLANE_CONFIG = {
    prefix          = "_asw_plane",                 -- Group name prefix for fixed-wing
    rearmZone       = "ASW_Hunter_Rearming",        -- Trigger zone for rearming; checked alongside rearmUnits
    rearmUnits      = {},                           -- Carrier unit names (e.g. {"CVN-74", "CVN-75"}); checked alongside rearmZone
    rearmRadius     = 500,                          -- Meters around each rearmUnit
    maxBuoys        = 8,                            -- Planes carry more buoys
    maxTorpedoes    = 2,
    maxDepthCharges = 16,                           -- Depth charges per hunter
    maxAltitude     = 200,                          -- Max AGL for buoy/torpedo deploy (meters)
    maxSpeed        = 120,                          -- Max speed for buoy/torpedo deploy (m/s)
    dcMaxAltitude   = 500,                          -- Max AGL for depth charge drop (meters)
    dcMaxSpeed      = 200,                          -- Max speed for depth charge drop (m/s)
    detectInterval  = 5,
    madConfig       = {
        detectionRange  = 500,   -- Horizontal detection radius at optimal altitude (meters)
        maxSearchDepth  = 200,   -- Deepest available search depth setting (meters)
        maxAltitude     = 150,   -- Max AGL for MAD operation (meters)
        drainBase       = 0.2,   -- Charge drain %/sec at minimum depth
        drainPerMeter   = 0.002, -- Additional drain %/sec per meter of search depth
        rechargeRate    = 0.25,  -- Charge recovery %/sec when inactive
    },
}

-- =============================================================================
-- 6. SONARBUOY SUPPLY
-- =============================================================================
-- lifetime:   battery life per buoy in seconds. nil = unlimited (no expiry).
-- globalPool: extra buoys available at rearm, shared across all hunters.
--             When the pool hits 0, hunters must recover buoys to get more.

local BUOY_CONFIG = {
    lifetime   = 1800,  -- 30 minutes per battery charge
    globalPool = 10,    -- reserve buoys at the carrier/base
}

-- =============================================================================
-- 7. SOUND CONFIGURATION
-- =============================================================================
-- Set duration to the actual length of each sound file in seconds.
-- Set to nil to disable a sound.

local SOUND_CONFIG = {
    sonar_ping      = { file = "sounds/sonar_ping.ogg",       duration = 2,   priority = SoundScheduler.PRIORITY.NORMAL },
    sonar_extend    = { file = "sounds/sonar_extend.ogg",     duration = 3,   priority = SoundScheduler.PRIORITY.LOW },
    sonar_retrieve  = { file = "sounds/sonar_retrieve.ogg",   duration = 3,   priority = SoundScheduler.PRIORITY.LOW },
    sonar_splash    = { file = "sounds/sonar_splash.ogg",     duration = 2,   priority = SoundScheduler.PRIORITY.NORMAL },
    sonar_cable_break = { file = "sounds/sonar_cable_break.ogg", duration = 2, priority = SoundScheduler.PRIORITY.HIGH },
    torpedo_launch  = { file = "sounds/torpedo_launch.ogg",    duration = 3,   priority = SoundScheduler.PRIORITY.CRITICAL },
    torpedo_homing  = { file = "sounds/torpedo_homing.ogg",    duration = 2,   priority = SoundScheduler.PRIORITY.HIGH },
    buoy_splash     = { file = "sounds/buoy_splash.ogg",       duration = 2,   priority = SoundScheduler.PRIORITY.NORMAL },
    recover_splash  = { file = "sounds/recover_splash.ogg",    duration = 2,   priority = SoundScheduler.PRIORITY.NORMAL },
    noisemaker_loop = { file = "sounds/noisemaker_active.ogg",  duration = 3,   priority = SoundScheduler.PRIORITY.LOW },
    warning_torpedo = { file = "sounds/warning_torpedo.ogg",   duration = 3,   priority = SoundScheduler.PRIORITY.ALERT },
    warning_sonar   = { file = "sounds/warning_sonar.ogg",     duration = 2,   priority = SoundScheduler.PRIORITY.ALERT },
    mad_buzz        = { file = "sounds/buzz.ogg",              duration = 3,   priority = SoundScheduler.PRIORITY.LOW },
}

-- =============================================================================
-- END OF CONFIGURATION — do not edit below unless you know what you're doing
-- =============================================================================

-- ===== Sound Scheduler =====
local soundScheduler = SoundScheduler:new()
for name, cfg in pairs(SOUND_CONFIG) do
    if cfg then
        soundScheduler:register(name, cfg.file, cfg.duration, cfg.priority)
    end
end

-- Make scheduler globally accessible for other modules
ASW_SOUND = soundScheduler

-- Shared depth-charge detonation log — DepthCharge writes here, AI reads it
ASW_DC_DETONATIONS = {}

-- ===== Create Submarine =====
-- Resolve spawn zone: if spawnZone is a table, pick one at random from
-- only the zones that actually exist in the mission. Warns about missing zones.
local function resolveSpawnZone(cfg)
    if type(cfg.spawnZone) == "table" and #cfg.spawnZone > 0 then
        local valid = {}
        for _, name in ipairs(cfg.spawnZone) do
            if trigger.misc.getZone(name) then
                valid[#valid + 1] = name
            else
                trigger.action.outText("ASW WARNING: spawn zone '" .. name .. "' not found in mission — skipped.", 15)
                env.info("ASW WARNING: spawn zone '" .. name .. "' not found in mission — skipped.", false)
            end
        end
        if #valid == 0 then
            trigger.action.outText("ASW ERROR: No valid spawn zones found! Check spawnZone names in asw_config.lua.", 30)
            return nil
        end
        local chosen = valid[math.random(#valid)]
        debugMessage("ASW: submarine spawn zone randomly chosen: " .. chosen)
        return chosen
    end
    return cfg.spawnZone
end

local spawnZone = resolveSpawnZone(SUB_CONFIG)
local submarine
if SUB_CONFIG.type == "diesel" then
    submarine = VirtualSubmarine:newDieselFromZone(
        SUB_CONFIG.name, spawnZone,
        SUB_CONFIG.startDepth, SUB_CONFIG.startSpeed, SUB_CONFIG.startHeading,
        SUB_COALITION, THERMAL_LAYER_DEPTH, SUB_CONFIG.randomizeSpawn)
elseif SUB_CONFIG.type == "ssn" then
    submarine = VirtualSubmarine:newSSNFromZone(
        SUB_CONFIG.name, spawnZone,
        SUB_CONFIG.startDepth, SUB_CONFIG.startSpeed, SUB_CONFIG.startHeading,
        SUB_COALITION, THERMAL_LAYER_DEPTH, SUB_CONFIG.randomizeSpawn)
elseif SUB_CONFIG.type == "custom" then
    submarine = VirtualSubmarine:newFromZone(
        SUB_CONFIG.name, spawnZone,
        SUB_CONFIG.startDepth, SUB_CONFIG.startSpeed, SUB_CONFIG.startHeading,
        SUB_CONFIG.noiseFactor, SUB_CONFIG.maxSpeed, SUB_CONFIG.maxDepth,
        SUB_COALITION, THERMAL_LAYER_DEPTH, SUB_CONFIG.randomizeSpawn)
end

if not submarine then
    trigger.action.outText("ASW ERROR: Failed to create submarine! Check spawn zone.", 30)
    return
end

-- Shared detectable objects table (submarines + noise makers for buoy detection)
local detectableObjects = {submarine}

-- ===== ASW Hunter Managers =====
-- Shared pools — both managers write here; AI/human commanders read from here.
local sharedBuoys         = {}
local sharedTorpedoes     = {}
local sharedDippingSonars = {}
-- Shared buoy supply: both managers draw from the same reserve when rearming.
local globalBuoyPool      = { count = BUOY_CONFIG.globalPool }

local heloManager = HelicopterHunterManager:new({
    ownerCoalition    = ASW_COALITION,
    submarines        = detectableObjects,
    hunterPrefix      = HELO_CONFIG.prefix,
    rearmZone         = HELO_CONFIG.rearmZone,
    rearmUnits        = HELO_CONFIG.rearmUnits,
    rearmRadius       = HELO_CONFIG.rearmRadius,
    maxBuoys          = HELO_CONFIG.maxBuoys,
    maxTorpedoes      = HELO_CONFIG.maxTorpedoes,
    maxDepthCharges   = HELO_CONFIG.maxDepthCharges,
    maxAltitude       = HELO_CONFIG.maxAltitude,
    maxSpeed          = HELO_CONFIG.maxSpeed,
    dcMaxAltitude     = HELO_CONFIG.dcMaxAltitude,
    dcMaxSpeed        = HELO_CONFIG.dcMaxSpeed,
    recoveryRange     = HELO_CONFIG.recoveryRange,
    thermalLayerDepth = THERMAL_LAYER_DEPTH,
    detectInterval    = HELO_CONFIG.detectInterval,
    buoys             = sharedBuoys,
    torpedoes         = sharedTorpedoes,
    dippingSonars     = sharedDippingSonars,
    globalBuoyPool    = globalBuoyPool,
    buoyLifetime      = BUOY_CONFIG.lifetime,
})

local planeManager = PlaneHunterManager:new({
    ownerCoalition    = ASW_COALITION,
    submarines        = detectableObjects,
    hunterPrefix      = PLANE_CONFIG.prefix,
    rearmZone         = PLANE_CONFIG.rearmZone,
    rearmUnits        = PLANE_CONFIG.rearmUnits,
    rearmRadius       = PLANE_CONFIG.rearmRadius,
    maxBuoys          = PLANE_CONFIG.maxBuoys,
    maxTorpedoes      = PLANE_CONFIG.maxTorpedoes,
    maxDepthCharges   = PLANE_CONFIG.maxDepthCharges,
    dcMaxAltitude     = PLANE_CONFIG.dcMaxAltitude,
    dcMaxSpeed        = PLANE_CONFIG.dcMaxSpeed,
    thermalLayerDepth = THERMAL_LAYER_DEPTH,
    detectInterval    = PLANE_CONFIG.detectInterval,
    buoys             = sharedBuoys,
    torpedoes         = sharedTorpedoes,
    madConfig         = PLANE_CONFIG.madConfig,
    globalBuoyPool    = globalBuoyPool,
    buoyLifetime      = BUOY_CONFIG.lifetime,
})

-- Single detection loop covering all buoys from both manager types
heloManager:startDetectionLoop()

-- ===== Commanders =====
local humanCommander, aiCommander

if COMMANDER_MODE == "human" or COMMANDER_MODE == "both" then
    humanCommander = HumanSubmarineCommander:new(
        SUB_COALITION, {submarine}, ASW_COALITION,
        sharedBuoys, detectableObjects)
end

if COMMANDER_MODE == "ai" or COMMANDER_MODE == "both" then
    aiCommander = AISubmarineCommander:new(submarine, {
        waypointZones    = AI_CONFIG.waypointZones,
        randomPatrol     = AI_CONFIG.randomPatrol,
        enableAttack     = AI_CONFIG.enableAttack,
        patrolSpeed      = AI_CONFIG.patrolSpeed,
        patrolDepth      = AI_CONFIG.patrolDepth,
        attackRange      = AI_CONFIG.attackRange,
        evasionBuoyRange = AI_CONFIG.evasionBuoyRange,
        evasionDuration  = AI_CONFIG.evasionDuration,
        profile          = AI_CONFIG.profile,
        targetCoalition  = ASW_COALITION,
        buoys            = sharedBuoys,
        torpedoes        = sharedTorpedoes,
        detectableObjects = detectableObjects,
        dippingSonars    = sharedDippingSonars,
    })
end

-- ===== Submarine Update Loop =====
local function submarineUpdateLoop()
    if submarine and submarine:isAlive() then
        submarine:update()
    end
    timer.scheduleFunction(function()
        submarineUpdateLoop()
    end, nil, timer.getTime() + 1)
end

submarineUpdateLoop()

-- ===== Mission Started =====
local modeName = COMMANDER_MODE == "both" and "Human + AI" or
                 COMMANDER_MODE == "ai" and "AI" or "Human"
trigger.action.outText("ASW Mission started. Submarine: " .. SUB_CONFIG.name
    .. " (" .. SUB_CONFIG.type .. ") | Commander: " .. modeName, 15)
debugMessage("ASW framework initialized.", 10)