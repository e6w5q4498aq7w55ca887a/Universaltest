getgenv().controlconfig = getgenv().controlconfig or {}
getgenv().controlconfig.key = "959494846161959497"
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local ScriptContext = game:GetService("ScriptContext")
local MarketplaceService = game:GetService("MarketplaceService")

if getgenv().ControlScriptUnload then
    pcall(getgenv().ControlScriptUnload)
end

local running = true
local connections = {}
local seenJobIds = {}

local function track(conn)
    if conn then
        table.insert(connections, conn)
    end
    return conn
end

getgenv().ControlScriptUnload = function()
    running = false
    for _, conn in ipairs(connections) do
        pcall(function()
            conn:Disconnect()
        end)
    end
    connections = {}
    getgenv().ControlScriptExecuted = nil
end

getgenv().ControlScriptExecuted = true

local config = getgenv().controlconfig or {}
local EXECUTION_KEY = tostring(config.key or math.random(100000000, 999999999))
local SERVER_URL = tostring(config.server or "https://roblox.ryuu.lol")
local HEARTBEAT_INTERVAL = tonumber(config.heartbeat) or 4
local EXECUTION_CHECK_INTERVAL = tonumber(config.execute_interval) or 1.25
local CONSOLE_FLUSH_INTERVAL = tonumber(config.console_flush) or 0.4
local MAX_CONSOLE_LINES = 250
local MAX_BATCH = 50

local player = Players.LocalPlayer
local userId = tostring(player.UserId)

local pendingConsole = {}
local sendingConsole = false
local executing = false
local lastConsoleLine = ""
local lastConsoleAt = 0

local function httpRequest(opts)
    local req = (syn and syn.request)
        or (http and http.request)
        or http_request
        or request
        or (fluxus and fluxus.request)
    if typeof(req) ~= "function" then
        return nil
    end
    local ok, res = pcall(req, opts)
    if not ok then
        return nil
    end
    return res
end

local function urlEncode(value)
    value = tostring(value or "")
    local ok, encoded = pcall(function()
        return HttpService:UrlEncode(value)
    end)
    if ok and typeof(encoded) == "string" then
        return encoded
    end
    return value:gsub("([^%w%-_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

local function responseOk(res)
    if not res then
        return false
    end
    local code = res.StatusCode or res.Status or 0
    if res.Success == true then
        return true
    end
    return code >= 200 and code < 300
end

local function getGameName()
    local name = "Unknown"
    pcall(function()
        name = MarketplaceService:GetProductInfo(game.PlaceId).Name
    end)
    return name
end

local function sendHeartbeat()
    if not running then
        return false
    end
    local res = httpRequest({
        Url = SERVER_URL .. "/api/roblox/heartbeat",
        Method = "POST",
        Headers = {
            ["Content-Type"] = "application/json",
        },
        Body = HttpService:JSONEncode({
            user_id = userId,
            username = player.Name,
            job_id = game.JobId,
            game_id = game.PlaceId,
            game_name = getGameName(),
            execution_key = EXECUTION_KEY,
        }),
    })
    return responseOk(res)
end

local function pushConsoleLine(line)
    if not running then
        return
    end
    line = tostring(line or "")
    if line == "" then
        return
    end
    if #line > 2000 then
        line = line:sub(1, 2000) .. "..."
    end
    local now = os.clock()
    if line == lastConsoleLine and (now - lastConsoleAt) < 0.2 then
        return
    end
    lastConsoleLine = line
    lastConsoleAt = now
    table.insert(pendingConsole, line)
    while #pendingConsole > MAX_CONSOLE_LINES do
        table.remove(pendingConsole, 1)
    end
end

local function flushConsole()
    if not running or sendingConsole or #pendingConsole == 0 then
        return
    end
    sendingConsole = true
    pcall(function()
        while running and #pendingConsole > 0 do
            local batch = {}
            while #pendingConsole > 0 and #batch < MAX_BATCH do
                table.insert(batch, table.remove(pendingConsole, 1))
            end
            local encodeOk, encoded = pcall(function()
                return HttpService:JSONEncode({
                    user_id = userId,
                    output = table.concat(batch, "\n"),
                    lines = batch,
                })
            end)
            if not encodeOk or typeof(encoded) ~= "string" then
                for i = #batch, 1, -1 do
                    table.insert(pendingConsole, 1, batch[i])
                end
                break
            end
            local res = httpRequest({
                Url = SERVER_URL .. "/api/roblox/console_output",
                Method = "POST",
                Headers = {
                    ["Content-Type"] = "application/json",
                },
                Body = encoded,
            })
            if not responseOk(res) then
                for i = #batch, 1, -1 do
                    table.insert(pendingConsole, 1, batch[i])
                end
                break
            end
        end
    end)
    sendingConsole = false
end

local function messageTypeName(messageType)
    if messageType == Enum.MessageType.MessageError then
        return "ERROR"
    end
    if messageType == Enum.MessageType.MessageWarning then
        return "WARN"
    end
    if messageType == Enum.MessageType.MessageInfo then
        return "INFO"
    end
    return "PRINT"
end

track(LogService.MessageOut:Connect(function(message, messageType)
    pushConsoleLine("[" .. messageTypeName(messageType) .. "] " .. tostring(message or ""))
end))

track(ScriptContext.Error:Connect(function(message, stackTrace)
    pushConsoleLine("[ERROR] " .. tostring(message))
    if stackTrace and tostring(stackTrace) ~= "" then
        pushConsoleLine("[STACK] " .. tostring(stackTrace))
    end
end))

local function rememberJob(jobId)
    if typeof(jobId) ~= "string" or jobId == "" then
        return false
    end
    if seenJobIds[jobId] then
        return true
    end
    seenJobIds[jobId] = os.clock()
    local cutoff = os.clock() - 120
    for id, at in pairs(seenJobIds) do
        if at < cutoff then
            seenJobIds[id] = nil
        end
    end
    return false
end

local function checkForExecution()
    if not running or executing then
        return
    end
    executing = true
    local okRun = pcall(function()
        local res = httpRequest({
            Url = SERVER_URL .. "/api/roblox/execute/" .. urlEncode(userId) .. "?key=" .. urlEncode(EXECUTION_KEY),
            Method = "GET",
        })
        if not responseOk(res) then
            return
        end
        local ok, data = pcall(function()
            return HttpService:JSONDecode(res.Body or "{}")
        end)
        if not ok or typeof(data) ~= "table" then
            return
        end
        local command = data.command
        local jobId = data.id
        if typeof(command) ~= "string" or command == "" then
            return
        end
        if typeof(jobId) == "string" and jobId ~= "" and rememberJob(jobId) then
            return
        end

        local fn, loadErr = loadstring(command)
        if not fn then
            pushConsoleLine("[ERROR] Loadstring error: " .. tostring(loadErr))
            flushConsole()
            return
        end
        local execOk, execErr = pcall(fn)
        if not execOk then
            pushConsoleLine("[ERROR] Execution error: " .. tostring(execErr))
        end
        flushConsole()
    end)
    if not okRun then
        pushConsoleLine("[ERROR] Execute loop failed")
    end
    executing = false
end

task.spawn(function()
    while running do
        local ok = false
        for _ = 1, 3 do
            if not running then
                break
            end
            if sendHeartbeat() then
                ok = true
                break
            end
            task.wait(1)
        end
        if running and not ok then
            pushConsoleLine("[WARN] Heartbeat failed")
        end
        task.wait(HEARTBEAT_INTERVAL)
    end
end)

task.spawn(function()
    while running do
        checkForExecution()
        task.wait(EXECUTION_CHECK_INTERVAL)
    end
end)

task.spawn(function()
    while running do
        flushConsole()
        task.wait(CONSOLE_FLUSH_INTERVAL)
    end
end)

sendHeartbeat()
pushConsoleLine("[PRINT] Connected as " .. player.Name .. " key=" .. EXECUTION_KEY)
flushConsole()
