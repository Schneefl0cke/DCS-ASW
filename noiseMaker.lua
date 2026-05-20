NoiseMaker = {}
NoiseMaker.__index = NoiseMaker

local function log(message, logCoalition, duration)
    duration = duration or 10
    trigger.action.outTextForCoalition(logCoalition, message, duration, false)
    env.info(message, false)
end

local debug = trigger.misc.getUserFlag("Debug")

local function debugMessage(message, duration)
    if debug == 1 then
        duration = duration or 10
        trigger.action.outText(message, duration, false)
        env.info(message, false)
    end
end

-- Constructor
-- name: Identifier (e.g. "Kursk-Decoy-1")
-- x, z: DCS world coordinates at deploy (submarine position)
-- depth: Depth at deploy (submarine depth)
-- activationDelay: Seconds before noise maker activates (60, 120, 180, 240)
-- ownerCoalition: coalition of the submarine that deployed it
-- thermalLayerDepth: thermal layer depth (for buoy detection compatibility)
function NoiseMaker:new(name, x, z, depth, activationDelay, ownerCoalition, thermalLayerDepth)
    local driftHeading = math.random() * 360
    local obj = {
        name = name,
        x = x,
        z = z,
        depth = depth,
        -- Duck-type fields for buoy detection compatibility
        speed = 3,                  -- slow drift speed in m/s (~6 kts)
        noiseFactor = 2.0,          -- loud to attract attention
        -- Internal fields
        driftHeading = driftHeading,
        activationDelay = activationDelay or 60,
        batteryLife = 600,          -- 10 minutes active time
        ownerCoalition = ownerCoalition or coalition.side.RED,
        thermalLayerDepth = thermalLayerDepth or 90,
        active = false,             -- not active until delay passes
        deployed = true,            -- deployed but may not be active yet
        elapsedTime = 0,
        activeTime = 0,
        lastUpdateTime = timer.getTime(),
        marker = nil,
        updateScheduleId = nil
    }
    setmetatable(obj, NoiseMaker)
    obj:startUpdateLoop()
    log(name .. " deployed! Activates in " .. activationDelay .. "s", ownerCoalition)
    return obj
end

-- Duck-type compatibility: buoys call sub:isAlive()
function NoiseMaker:isAlive()
    return self.active
end

function NoiseMaker:isDeployed()
    return self.deployed
end

-- Main update loop: runs every second
function NoiseMaker:startUpdateLoop()
    local function update()
        if not self.deployed then return end

        local currentTime = timer.getTime()
        local dt = currentTime - self.lastUpdateTime
        self.lastUpdateTime = currentTime
        self.elapsedTime = self.elapsedTime + dt

        -- Check activation
        if not self.active then
            if self.elapsedTime >= self.activationDelay then
                self.active = true
                log(self.name .. " ACTIVATED! Emitting noise.", self.ownerCoalition)
                -- Activation sound (sub coalition only)
                if ASW_SOUND then
                    ASW_SOUND:playForCoalition(self.ownerCoalition, "noisemaker_loop")
                end
            end
        else
            -- Active: count active time and check battery
            self.activeTime = self.activeTime + dt
            if self.activeTime >= self.batteryLife then
                self:expire()
                return
            end

            -- Drift in random direction
            self:drift(dt)
        end

        -- Update marker for sub coalition
        self:updateMarker()

        self.updateScheduleId = timer.scheduleFunction(function()
            update()
        end, nil, timer.getTime() + 1)
    end

    update()
end

-- Drift slowly in the random heading
function NoiseMaker:drift(dt)
    local headingRad = math.rad(self.driftHeading)
    local distance = self.speed * dt
    self.x = self.x + distance * math.cos(headingRad)
    self.z = self.z + distance * math.sin(headingRad)
end

-- Battery expired
function NoiseMaker:expire()
    self.active = false
    self.deployed = false
    self:stopUpdateLoop()
    self:clearMarker()
    log(self.name .. " battery depleted. Noise maker silent.", self.ownerCoalition)
end

-- Remove noise maker
function NoiseMaker:remove()
    self.active = false
    self.deployed = false
    self:stopUpdateLoop()
    self:clearMarker()
end

function NoiseMaker:stopUpdateLoop()
    if self.updateScheduleId then
        timer.removeFunction(self.updateScheduleId)
        self.updateScheduleId = nil
    end
end

-- Update F10 map marker (visible to sub coalition only)
function NoiseMaker:updateMarker()
    local coord = COORDINATE:New(self.x, 0, self.z)
    local status
    if not self.active then
        local remaining = self.activationDelay - self.elapsedTime
        status = string.format("STANDBY (%.0fs)", math.max(0, remaining))
    else
        local remaining = self.batteryLife - self.activeTime
        status = string.format("ACTIVE (%.0fs)", math.max(0, remaining))
    end
    local text = string.format("%s | DECOY | %s | Depth: %.0fm",
        self.name, status, self.depth)

    if self.marker then
        self.marker:UpdateCoordinate(coord)
        self.marker:UpdateText(text)
    else
        self.marker = MARKER:New(coord, text):ReadOnly():ToCoalition(self.ownerCoalition)
    end
end

-- Remove map marker
function NoiseMaker:clearMarker()
    if self.marker then
        self.marker:Remove()
        self.marker = nil
    end
end
