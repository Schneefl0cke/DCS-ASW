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
    type            = "diesel",                     -- "diesel", "ssn", or "custom"
    name            = "Kursk",                      -- Display name
    spawnZone       = "Submarine_initial_position",  -- Trigger zone name
    startDepth      = 60,                           -- Starting depth in meters
    startSpeed      = 8,                            -- Starting speed in m/s
    startHeading    = 270,                          -- Starting heading in degrees
    randomizeSpawn  = false,                        -- Randomize position within zone?

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
-- ASW hunter aircraft groups must contain this prefix in their group name.

local HUNTER_CONFIG = {
    prefix          = "_asw_hunter",                -- Group name prefix
    rearmZone       = "ASW_Hunter_Rearming",        -- Trigger zone for rearming (static)
    rearmUnit       = nil,                          -- Carrier unit name (e.g. "CVN-74"), overrides rearmZone
    rearmRadius     = 500,                          -- Meters around rearmUnit
    maxBuoys        = 4,                            -- Sonarbuoys per hunter
    maxTorpedoes    = 1,                            -- ASW torpedoes per hunter
    maxAltitude     = 50,                           -- Max AGL for deploy/recover/launch (meters)
    maxSpeed        = 60,                           -- Max speed for deploy/recover/launch (m/s)
    recoveryRange   = 10,                           -- Max distance to recover a buoy (meters)
    detectInterval  = 5,                            -- Seconds between sonarbuoy detection cycles
}

-- =============================================================================
-- 6. SOUND CONFIGURATION
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

-- ===== Create Submarine =====
local submarine
if SUB_CONFIG.type == "diesel" then
    submarine = VirtualSubmarine:newDieselFromZone(
        SUB_CONFIG.name, SUB_CONFIG.spawnZone,
        SUB_CONFIG.startDepth, SUB_CONFIG.startSpeed, SUB_CONFIG.startHeading,
        SUB_COALITION, THERMAL_LAYER_DEPTH, SUB_CONFIG.randomizeSpawn)
elseif SUB_CONFIG.type == "ssn" then
    submarine = VirtualSubmarine:newSSNFromZone(
        SUB_CONFIG.name, SUB_CONFIG.spawnZone,
        SUB_CONFIG.startDepth, SUB_CONFIG.startSpeed, SUB_CONFIG.startHeading,
        SUB_COALITION, THERMAL_LAYER_DEPTH, SUB_CONFIG.randomizeSpawn)
elseif SUB_CONFIG.type == "custom" then
    submarine = VirtualSubmarine:newFromZone(
        SUB_CONFIG.name, SUB_CONFIG.spawnZone,
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

-- ===== Ordnance Manager (ASW Hunters) =====
local ordnanceManager = OrdnanceManager:new({
    ownerCoalition  = ASW_COALITION,
    submarines      = detectableObjects,
    hunterPrefix    = HUNTER_CONFIG.prefix,
    rearmZone       = HUNTER_CONFIG.rearmZone,
    rearmUnit       = HUNTER_CONFIG.rearmUnit,
    rearmRadius     = HUNTER_CONFIG.rearmRadius,
    maxBuoys        = HUNTER_CONFIG.maxBuoys,
    maxTorpedoes    = HUNTER_CONFIG.maxTorpedoes,
    maxAltitude     = HUNTER_CONFIG.maxAltitude,
    maxSpeed        = HUNTER_CONFIG.maxSpeed,
    recoveryRange   = HUNTER_CONFIG.recoveryRange,
    thermalLayerDepth = THERMAL_LAYER_DEPTH,
    detectInterval  = HUNTER_CONFIG.detectInterval,
})

-- ===== Commanders =====
local humanCommander, aiCommander

if COMMANDER_MODE == "human" or COMMANDER_MODE == "both" then
    humanCommander = HumanSubmarineCommander:new(
        SUB_COALITION, {submarine}, ASW_COALITION,
        ordnanceManager.buoys, detectableObjects)
end

if COMMANDER_MODE == "ai" or COMMANDER_MODE == "both" then
    aiCommander = AISubmarineCommander:new(submarine, {
        waypointZones    = AI_CONFIG.waypointZones,
        patrolSpeed      = AI_CONFIG.patrolSpeed,
        patrolDepth      = AI_CONFIG.patrolDepth,
        attackRange      = AI_CONFIG.attackRange,
        evasionBuoyRange = AI_CONFIG.evasionBuoyRange,
        evasionDuration  = AI_CONFIG.evasionDuration,
        profile          = AI_CONFIG.profile,
        targetCoalition  = ASW_COALITION,
        buoys            = ordnanceManager.buoys,
        torpedoes        = ordnanceManager.torpedoes,
        detectableObjects = detectableObjects,
        dippingSonars    = ordnanceManager:getDippingSonars(),
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