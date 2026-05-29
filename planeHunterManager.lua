PlaneHunterManager = setmetatable({}, {__index = OrdnanceManager})
PlaneHunterManager.__index = PlaneHunterManager

-- ASW fixed-wing hunter management.
-- Capabilities: sonarbuoy deployment, torpedo launch.
-- No dipping sonar. No buoy recovery.
-- Higher default altitude and speed limits than helicopters.

function PlaneHunterManager:new(config)
    config.maxAltitude = config.maxAltitude or 200
    config.maxSpeed    = config.maxSpeed    or 120
    return OrdnanceManager.new(self, config)
end

function PlaneHunterManager:initGroup(groupName)
    local unit = self:getGroupUnit(groupName)
    if unit and unit:getDesc().category ~= Unit.Category.AIRPLANE then
        self.trackedGroups[groupName] = true
        self:log("ASW WARNING: Group '" .. groupName .. "' has fixed-wing prefix but is not a plane — skipping.")
        return
    end

    OrdnanceManager.initGroup(self, groupName)
end
