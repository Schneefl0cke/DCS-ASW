ShipCommander = {}
ShipCommander.__index = ShipCommander

local ZIG_ZAG_AMPLITUDE = 20     -- degrees either side of target heading
local ZIG_ZAG_PERIOD    = 45     -- seconds per full oscillation
local WAYPOINT_REFRESH  = 5      -- seconds between waypoint pushes
local WAYPOINT_DISTANCE = 50000  -- 50 km lookahead

local function log(message, logCoalition, duration)
    duration = duration or 10
    trigger.action.outTextForCoalition(logCoalition, message, duration, false)
    env.info(message, false)
end

-- Constructor
-- config fields:
--   groupPrefix:       string prefix for ship group names (default "asw_ship")
--   ownerCoalition:    coalition.side.BLUE or RED
--   submarines:        shared detectableObjects table
--   thermalLayerDepth: number (meters)
function ShipCommander:new(config)
    config = config or {}
    local obj = {
        groupPrefix       = config.groupPrefix or "asw_ship",
        ownerCoalition    = config.ownerCoalition or coalition.side.BLUE,
        submarines        = config.submarines or {},
        thermalLayerDepth = config.thermalLayerDepth or 90,
        ships             = {},    -- shipData keyed by groupName
        rootMenu          = nil,
    }
    setmetatable(obj, ShipCommander)
    obj:discoverShips()
    return obj
end

-- ===== DISCOVERY =====

function ShipCommander:discoverShips()
    local groups = coalition.getGroups(self.ownerCoalition)
    local found  = 0
    for _, group in ipairs(groups) do
        local gName = group:getName()
        if gName:find(self.groupPrefix, 1, true) then
            local units = group:getUnits()
            if #units ~= 1 then
                log(string.format(
                    "ASW WARNING: Ship group '%s' has %d units — must be exactly 1. Skipped.",
                    gName, #units), self.ownerCoalition, 20)
            else
                self:initShip(gName)
                found = found + 1
            end
        end
    end
    if found == 0 then
        env.info("ShipCommander: no groups found with prefix '" .. self.groupPrefix .. "'", false)
    else
        env.info(string.format("ShipCommander: initialized %d ship(s).", found), false)
    end
end

-- Ship data fields:
--   groupName     string
--   sonar         ShipSonar
--   targetHeading number  (degrees 0-360, player-set compass heading)
--   targetSpeed   number  (knots)
--   dcDepth       number  (meters)
--   dcCount       number  (charges per pattern drop)
--   dcInterval    number  (seconds between pattern charges)
--   dcDropCounter number  (for naming individual charges)
--   aiZigZag      bool
function ShipCommander:initShip(groupName)
    local dcsGroup = Group.getByName(groupName)
    if not dcsGroup or not dcsGroup:isExist() then
        env.info("ShipCommander: group '" .. groupName .. "' not found at init.", false)
        return
    end
    local unit = dcsGroup:getUnit(1)
    if not unit or not unit:isExist() then return end

    local hdgDeg = math.deg(unit:getHeading()) % 360

    local data = {
        groupName     = groupName,
        sonar         = ShipSonar:new(groupName, self.ownerCoalition, self.thermalLayerDepth, self.submarines),
        targetHeading = hdgDeg,
        targetSpeed   = 10,
        dcDepth       = 50,
        dcCount       = 5,
        dcInterval    = 10,
        dcDropCounter = 0,
        aiZigZag      = false,
    }

    self.ships[groupName] = data
    self:buildMenus(groupName)
    self:startWaypointLoop(groupName)

    log(string.format("Ship '%s' online | HDG: %.0f° | Speed: %d kt",
        groupName, hdgDeg, data.targetSpeed), self.ownerCoalition, 10)
end

-- ===== MENUS (COALITION-WIDE) =====

function ShipCommander:buildMenus(groupName)
    local side = self.ownerCoalition
    local data = self.ships[groupName]

    if not self.rootMenu then
        self.rootMenu = MENU_COALITION:New(side, "ASW Ships")
    end

    local shipMenu = MENU_COALITION:New(side, groupName, self.rootMenu)

    -- Speed
    local speedMenu    = MENU_COALITION:New(side, "Speed", shipMenu)
    local setSpeedMenu = MENU_COALITION:New(side, "Set Speed", speedMenu)
    MENU_COALITION_COMMAND:New(side, "Increase Speed (+5 kt)", speedMenu,    self.changeSpeed,   self, groupName,  5)
    MENU_COALITION_COMMAND:New(side, "Decrease Speed (-5 kt)", speedMenu,    self.changeSpeed,   self, groupName, -5)
    MENU_COALITION_COMMAND:New(side, "Stop (0 kt)",            speedMenu,    self.setSpeed,      self, groupName,  0)
    for _, kt in ipairs({5, 10, 15, 20}) do
        MENU_COALITION_COMMAND:New(side, kt .. " kt", setSpeedMenu, self.setSpeed, self, groupName, kt)
    end

    -- Heading
    local hdgMenu    = MENU_COALITION:New(side, "Heading", shipMenu)
    local setHdgMenu = MENU_COALITION:New(side, "Set Heading", hdgMenu)
    MENU_COALITION_COMMAND:New(side, "Turn Left  30°", hdgMenu, self.changeHeading, self, groupName, -30)
    MENU_COALITION_COMMAND:New(side, "Turn Right 30°", hdgMenu, self.changeHeading, self, groupName,  30)
    for _, entry in ipairs({
        {"N  (000°)",   0}, {"NE (045°)",  45}, {"E  (090°)",  90}, {"SE (135°)", 135},
        {"S  (180°)", 180}, {"SW (225°)", 225}, {"W  (270°)", 270}, {"NW (315°)", 315},
    }) do
        MENU_COALITION_COMMAND:New(side, entry[1], setHdgMenu, self.setHeading, self, groupName, entry[2])
    end

    -- Depth charges
    local dcMenu      = MENU_COALITION:New(side, "Depth Charges", shipMenu)
    local dcDepthMenu = MENU_COALITION:New(side, "Set DC Depth",  dcMenu)
    MENU_COALITION_COMMAND:New(side, "Drop 1 Charge",                      dcMenu,      self.dropDepthCharges, self, groupName, 1)
    MENU_COALITION_COMMAND:New(side, string.format("Drop Pattern (%d charges)", data.dcCount), dcMenu, self.dropPattern, self, groupName)
    MENU_COALITION_COMMAND:New(side, "DC Status",                          dcMenu,      self.reportStatus,     self, groupName)
    for _, d in ipairs({30, 50, 100, 150, 200}) do
        MENU_COALITION_COMMAND:New(side, d .. "m", dcDepthMenu, self.setDCDepth, self, groupName, d)
    end

    -- Sonar
    local sonarMenu = MENU_COALITION:New(side, "Sonar", shipMenu)
    MENU_COALITION_COMMAND:New(side, "Activate (Active Mode)",    sonarMenu, self.setSonarMode,      self, groupName, "active")
    MENU_COALITION_COMMAND:New(side, "Deactivate (Passive Mode)", sonarMenu, self.setSonarMode,      self, groupName, "passive")
    MENU_COALITION_COMMAND:New(side, "Sonar Status",              sonarMenu, self.reportSonarStatus, self, groupName)

    -- AI
    local aiMenu = MENU_COALITION:New(side, "AI Behavior", shipMenu)
    MENU_COALITION_COMMAND:New(side, "Toggle Zig-Zag", aiMenu, self.toggleZigZag, self, groupName)
    MENU_COALITION_COMMAND:New(side, "Ship Status",    aiMenu, self.reportStatus,  self, groupName)
end

-- ===== SPEED / HEADING =====

function ShipCommander:changeSpeed(groupName, delta)
    local data = self.ships[groupName]
    if not data then return end
    data.targetSpeed = math.max(0, data.targetSpeed + delta)
    log(string.format("%s speed → %d kt", groupName, data.targetSpeed), self.ownerCoalition)
end

function ShipCommander:setSpeed(groupName, kt)
    local data = self.ships[groupName]
    if not data then return end
    data.targetSpeed = math.max(0, kt)
    log(string.format("%s speed → %d kt", groupName, data.targetSpeed), self.ownerCoalition)
end

function ShipCommander:changeHeading(groupName, deltaDeg)
    local data = self.ships[groupName]
    if not data then return end
    data.targetHeading = (data.targetHeading + deltaDeg) % 360
    log(string.format("%s heading → %.0f°", groupName, data.targetHeading), self.ownerCoalition)
end

function ShipCommander:setHeading(groupName, deg)
    local data = self.ships[groupName]
    if not data then return end
    data.targetHeading = deg % 360
    log(string.format("%s heading → %.0f°", groupName, data.targetHeading), self.ownerCoalition)
end

-- ===== WAYPOINT LOOP =====

function ShipCommander:startWaypointLoop(groupName)
    local function refresh()
        local data = self.ships[groupName]
        if not data then return end

        local dcsGroup = Group.getByName(groupName)
        if not dcsGroup or not dcsGroup:isExist() then return end
        local unit = dcsGroup:getUnit(1)
        if not unit or not unit:isExist() then return end

        local pos     = unit:getPoint()
        local speedMs = data.targetSpeed * 0.514444   -- kt → m/s

        -- Apply zig-zag sine wave offset around the player-set heading
        local effectiveHeading = data.targetHeading
        if data.aiZigZag then
            local offset = math.sin(timer.getTime() * 2 * math.pi / ZIG_ZAG_PERIOD) * ZIG_ZAG_AMPLITUDE
            effectiveHeading = (effectiveHeading + offset) % 360
        end

        -- Compute a waypoint far ahead in the desired direction using MOOSE
        local coord       = COORDINATE:New(pos.x, 0, pos.z)
        local targetCoord = coord:Translate(WAYPOINT_DISTANCE, effectiveHeading)

        local wp = {
            type         = "Turning Point",
            action       = "Turning Point",
            x            = targetCoord.x,
            y            = targetCoord.z,   -- route point y = DCS world z
            speed        = speedMs,
            speed_locked = true,
            ETA_locked   = false,
        }

        dcsGroup:getController():setTask({
            id     = "Mission",
            params = { route = { points = { wp } } }
        })

        timer.scheduleFunction(function() refresh() end, nil, timer.getTime() + WAYPOINT_REFRESH)
    end

    timer.scheduleFunction(function() refresh() end, nil, timer.getTime() + 1)
end

-- ===== DEPTH CHARGES =====

function ShipCommander:dropDepthCharges(groupName, count)
    local data = self.ships[groupName]
    if not data then return end
    local dcsGroup = Group.getByName(groupName)
    if not dcsGroup then return end
    local unit = dcsGroup:getUnit(1)
    if not unit or not unit:isExist() then return end

    self:dropSingleCharge(groupName, data, unit)
end

function ShipCommander:dropSingleCharge(groupName, data, unit)
    local pos = unit:getPoint()
    data.dcDropCounter = data.dcDropCounter + 1
    local name = groupName .. "-DC-" .. data.dcDropCounter
    local dc = DepthCharge:new(name, pos.x, pos.z, data.dcDepth, self.ownerCoalition, self.submarines)
    if dc then
        log(string.format("%s dropped %s at depth %dm", groupName, name, data.dcDepth), self.ownerCoalition)
    end
end

function ShipCommander:dropPattern(groupName)
    local data = self.ships[groupName]
    if not data then return end

    log(string.format("%s DC pattern: %d charges, %ds interval, depth %dm",
        groupName, data.dcCount, data.dcInterval, data.dcDepth), self.ownerCoalition)

    local function dropNext(remaining)
        if remaining <= 0 then return end
        local dcsGroup = Group.getByName(groupName)
        if not dcsGroup then return end
        local unit = dcsGroup:getUnit(1)
        if not unit or not unit:isExist() then return end

        self:dropSingleCharge(groupName, data, unit)

        if remaining > 1 then
            timer.scheduleFunction(function()
                dropNext(remaining - 1)
            end, nil, timer.getTime() + data.dcInterval)
        end
    end

    dropNext(data.dcCount)
end

function ShipCommander:setDCDepth(groupName, depth)
    local data = self.ships[groupName]
    if not data then return end
    data.dcDepth = depth
    log(string.format("%s DC depth set to %dm", groupName, depth), self.ownerCoalition)
end

-- ===== SONAR =====

function ShipCommander:setSonarMode(groupName, mode)
    local data = self.ships[groupName]
    if not data or not data.sonar then return end
    local msg = data.sonar:setMode(mode)
    log(groupName .. " | " .. msg, self.ownerCoalition)
end

function ShipCommander:reportSonarStatus(groupName)
    local data = self.ships[groupName]
    if not data or not data.sonar then return end
    log(groupName .. " | " .. data.sonar:getStatusText(), self.ownerCoalition)
end

-- ===== AI =====

function ShipCommander:toggleZigZag(groupName)
    local data = self.ships[groupName]
    if not data then return end
    data.aiZigZag = not data.aiZigZag
    local state = data.aiZigZag and "ENABLED" or "DISABLED"
    log(string.format("%s Zig-Zag %s (±%d° / %ds period)",
        groupName, state, ZIG_ZAG_AMPLITUDE, ZIG_ZAG_PERIOD), self.ownerCoalition)
end

-- ===== STATUS =====

function ShipCommander:reportStatus(groupName)
    local data = self.ships[groupName]
    if not data then return end
    local zigStr = data.aiZigZag and "ON" or "OFF"
    local msg = string.format(
        "%s | HDG: %.0f° | Speed: %d kt | DC Depth: %dm | Zig-Zag: %s\n%s",
        groupName, data.targetHeading, data.targetSpeed, data.dcDepth, zigStr,
        data.sonar and data.sonar:getStatusText() or "No sonar")
    log(msg, self.ownerCoalition, 10)
end
