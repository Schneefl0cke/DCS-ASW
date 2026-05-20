SoundScheduler = {}
SoundScheduler.__index = SoundScheduler

-- Priority levels (for reference, higher = more important)
SoundScheduler.PRIORITY = {
    LOW       = 1,   -- ambient loops (noise maker)
    NORMAL    = 2,   -- routine events (sonar ping, buoy deploy)
    HIGH      = 3,   -- tactical events (torpedo homing)
    CRITICAL  = 4,   -- launches (torpedo launch)
    ALERT     = 5,   -- warnings (torpedo in water)
}

-- Constructor
-- Creates a scheduler that manages sound playback per group,
-- preventing overlap and respecting priority.
function SoundScheduler:new()
    local obj = {
        sounds   = {},      -- name -> {file, duration, priority}
        channels = {},      -- groupName -> {currentSound, priority, endTime, scheduleId}
        loops    = {},      -- groupName -> {soundName -> {active, scheduleId}}
    }
    setmetatable(obj, SoundScheduler)
    return obj
end

-- Register a sound
-- name: unique identifier (e.g. "sonar_ping")
-- soundFile: filename inside the miz (e.g. "sonar_ping.ogg")
-- duration: length of the sound in seconds (must be known)
-- priority: number (use SoundScheduler.PRIORITY constants)
function SoundScheduler:register(name, soundFile, duration, priority)
    self.sounds[name] = {
        file     = "l10n/DEFAULT/" .. soundFile,
        duration = duration,
        priority = priority or SoundScheduler.PRIORITY.NORMAL,
    }
end

-- Play a sound once to a specific group
-- Returns true if the sound was played, false if blocked by higher priority
function SoundScheduler:playOnce(groupName, soundName)
    local sound = self.sounds[soundName]
    if not sound then return false end

    local dcsGroup = Group.getByName(groupName)
    if not dcsGroup or not dcsGroup:isExist() then return false end

    local now = timer.getTime()
    local ch = self.channels[groupName]

    -- Check if channel is busy
    if ch and ch.endTime > now then
        if sound.priority <= ch.priority then
            return false
        end
        -- Higher priority: interrupt current sound's end callback
        if ch.scheduleId then
            timer.removeFunction(ch.scheduleId)
        end
    end

    -- Play the sound
    trigger.action.outSoundForGroup(dcsGroup:getID(), sound.file)

    -- Track when it ends
    local endTime = now + sound.duration
    local scheduleId = timer.scheduleFunction(function()
        local c = self.channels[groupName]
        if c and c.endTime <= timer.getTime() then
            c.currentSound = nil
            c.priority = 0
            c.scheduleId = nil
        end
    end, nil, endTime)

    self.channels[groupName] = {
        currentSound = soundName,
        priority     = sound.priority,
        endTime      = endTime,
        scheduleId   = scheduleId,
    }

    return true
end

-- Start looping a sound to a group
-- interval: seconds of silence between repeats (default 0 = back-to-back)
function SoundScheduler:startLoop(groupName, soundName, interval)
    local sound = self.sounds[soundName]
    if not sound then return end

    -- Stop any existing loop of the same sound
    self:stopLoop(groupName, soundName)

    if not self.loops[groupName] then
        self.loops[groupName] = {}
    end

    local loopState = { active = true, scheduleId = nil }
    self.loops[groupName][soundName] = loopState

    local function tick()
        if not loopState.active then return end

        local dcsGroup = Group.getByName(groupName)
        if not dcsGroup or not dcsGroup:isExist() then
            loopState.active = false
            return
        end

        local played = self:playOnce(groupName, soundName)

        -- If played, wait duration + interval before next play
        -- If blocked by higher priority, retry in 1 second
        local nextTime
        if played then
            nextTime = timer.getTime() + sound.duration + (interval or 0)
        else
            nextTime = timer.getTime() + 1
        end

        loopState.scheduleId = timer.scheduleFunction(function()
            tick()
        end, nil, nextTime)
    end

    tick()
end

-- Stop a specific loop for a group
function SoundScheduler:stopLoop(groupName, soundName)
    if not self.loops[groupName] then return end
    local loopState = self.loops[groupName][soundName]
    if not loopState then return end

    loopState.active = false
    if loopState.scheduleId then
        timer.removeFunction(loopState.scheduleId)
        loopState.scheduleId = nil
    end
    self.loops[groupName][soundName] = nil
end

-- Stop all sounds and loops for a group
function SoundScheduler:stopAll(groupName)
    -- Stop all loops
    if self.loops[groupName] then
        for soundName, _ in pairs(self.loops[groupName]) do
            self:stopLoop(groupName, soundName)
        end
        self.loops[groupName] = nil
    end

    -- Clear channel
    local ch = self.channels[groupName]
    if ch then
        if ch.scheduleId then
            timer.removeFunction(ch.scheduleId)
        end
        self.channels[groupName] = nil
    end
end

-- Check if a group currently has a sound playing
function SoundScheduler:isPlaying(groupName)
    local ch = self.channels[groupName]
    return ch ~= nil and ch.endTime > timer.getTime()
end

-- Check if a specific loop is active for a group
function SoundScheduler:isLooping(groupName, soundName)
    if not self.loops[groupName] then return false end
    local loopState = self.loops[groupName][soundName]
    return loopState ~= nil and loopState.active
end

-- Play a sound once to an entire coalition (fire-and-forget, no channel tracking)
-- coalitionId: coalition.side.RED, coalition.side.BLUE, or -1 for all
function SoundScheduler:playForCoalition(coalitionId, soundName)
    local sound = self.sounds[soundName]
    if not sound then return false end
    trigger.action.outSoundForCoalition(coalitionId, sound.file)
    return true
end
