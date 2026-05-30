DepthCharge = {}
DepthCharge.__index = DepthCharge

if not _dcMarkIdCounter then _dcMarkIdCounter = 700000 end
local function nextDCMarkId()
    _dcMarkIdCounter = _dcMarkIdCounter + 1
    return _dcMarkIdCounter
end

-- A single depth charge in a drop pattern.
-- Spawning over land discards the charge silently (no explosion, no detonation).
-- Sinks at a fixed rate until reaching setDepth, then detonates.
-- Kills any VirtualSubmarine within killRadius (3D) of the detonation point.
function DepthCharge:new(name, x, z, setDepth, ownerCoalition, submarines)
    -- Discard immediately if spawned over land
    local _, waterDepth = land.getSurfaceHeightWithSeabed({x = x, y = z})
    if waterDepth <= 0 then
        env.info("DepthCharge: " .. name .. " spawned over land — discarded.", false)
        return nil
    end

    local obj = {
        name           = name,
        x              = x,
        z              = z,
        setDepth       = setDepth,
        ownerCoalition = ownerCoalition,
        submarines     = submarines,
        depth          = 0,
        sinkRate       = 3,    -- m/s
        killRadius     = 80,   -- meters (3D)
        active         = true,
        updateScheduleId = nil,
    }
    setmetatable(obj, DepthCharge)
    obj:startSinking()
    return obj
end

function DepthCharge:isActive()
    return self.active
end

function DepthCharge:startSinking()
    local function sink()
        if not self.active then return end
        self.depth = self.depth + self.sinkRate
        if self.depth >= self.setDepth then
            self:detonate()
        else
            self.updateScheduleId = timer.scheduleFunction(function() sink() end, nil, timer.getTime() + 1)
        end
    end
    self.updateScheduleId = timer.scheduleFunction(function() sink() end, nil, timer.getTime() + 1)
end

function DepthCharge:detonate()
    self.active = false

    -- Explosion visual on the water surface
    trigger.action.explosion({x = self.x, y = 1, z = self.z}, 500)

    -- Kill check
    local hit = nil
    for _, sub in ipairs(self.submarines) do
        if sub.maxDepth and sub:isAlive() then
            local dx = sub.x - self.x
            local dz = sub.z - self.z
            local dy = sub.depth - self.setDepth
            local dist3d = math.sqrt(dx * dx + dz * dz + dy * dy)
            if dist3d <= self.killRadius then
                hit = sub
                break
            end
        end
    end

    -- Log for AI awareness
    if ASW_DC_DETONATIONS then
        ASW_DC_DETONATIONS[#ASW_DC_DETONATIONS + 1] = {
            x = self.x, z = self.z, depth = self.setDepth, time = timer.getTime()
        }
    end

    if hit then
        trigger.action.explosion({x = hit.x, y = 0, z = hit.z}, 1000)
        hit:destroy()

        local text = self.name .. " | DEPTH CHARGE | " .. hit.name .. " DESTROYED"
        local coord = COORDINATE:New(hit.x, 0, hit.z)
        MARKER:New(coord, text):ReadOnly():ToAll()

        trigger.action.outText("*** DEPTH CHARGE! " .. self.name .. " has destroyed " .. hit.name .. "! ***", 30, false)
        env.info("DepthCharge: " .. self.name .. " destroyed " .. hit.name .. " at depth " .. math.floor(self.setDepth) .. "m", false)
    else
        env.info("DepthCharge: " .. self.name .. " detonated at depth " .. math.floor(self.setDepth) .. "m — no kill", false)
    end
end
