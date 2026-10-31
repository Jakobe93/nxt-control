-- perf - a resmon stand-in that runs without the game.
--
--   lua5.4 .github/nxt/perf.lua                 run every scenario in .github/nxt-perf.lua, print the table
--   lua5.4 .github/nxt/perf.lua baseline        run and save the counts to .github/nxt-perf-baseline.lua
--   lua5.4 .github/nxt/perf.lua check           run and fail if a count grew past the baseline (CI)
--   lua5.4 .github/nxt/perf.lua compare A B     two saved baselines side by side
--
-- It loads the resource's client scripts (the order fxmanifest.lua gives) into a fake FiveM: threads, Wait,
-- events, NUI messages, exports, statebags and ox_lib's cache are simulated, and every native is a stub that
-- counts its calls. Then it plays each scenario of the recipe at 60 frames a second and counts, per second:
-- thread wake-ups (and how many threads wake every frame), native calls, NUI messages and their size,
-- calls into other resources' exports, statebag reads and writes, and memory allocated.
--
-- What it can tell: what runs, how often, and whether a change made that more or less. What it cannot: the
-- real milliseconds resmon shows, because the cost of a native lives in the game. The "Lua ms" column is this
-- machine's time for the Lua side with stub natives: compare it between runs, never with resmon.
-- Guide: tools/README-perf.md in Jakobe93/nxt-md.

local RECIPE   = '.github/nxt-perf.lua'
local BASELINE = '.github/nxt-perf-baseline.lua'
local FPS      = 60

-- ── small helpers ───────────────────────────────────────────────────────────
local function readfile(p)
    local fh = io.open(p, 'rb'); if not fh then return nil end
    local s = fh:read('a'); fh:close(); return s
end
local function die(msg) io.stderr:write('perf: ' .. msg .. '\n'); os.exit(2) end

local function joaat(s)
    s = s:lower()
    local h = 0
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = (h ~ (h >> 6)) & 0xFFFFFFFF
    end
    h = (h + (h << 3)) & 0xFFFFFFFF
    h = (h ~ (h >> 11)) & 0xFFFFFFFF
    h = (h + (h << 15)) & 0xFFFFFFFF
    if h >= 0x80000000 then h = h - 0x100000000 end
    return h
end

-- ── Cfx Lua -> stock Lua 5.4 (backtick hashes, compound assignment, !=, ?. , /* */) ─────────────
-- Same scanner idea as nxt_check.py, but this one keeps the meaning: `a += b` becomes `a = a + (b)`.
local function cfxToLua(src)
    local out, i, n = {}, 1, #src
    local function longOpen(j)
        if src:sub(j, j) ~= '[' then return nil end
        local k = j + 1
        while src:sub(k, k) == '=' do k = k + 1 end
        if src:sub(k, k) == '[' then return k - j - 1 end
    end
    local code = {}
    local function flush()
        if #code == 0 then return end
        local t = table.concat(code); code = {}
        t = t:gsub('!=', '~=')
        t = t:gsub('%?([%.%[:])', '%1')
        -- compound assignment: `a += b` -> `a = a + (b)`; the right side ends at the line, a `;`, or a keyword
        -- that closes the statement (`if x then n += 1 end`)
        local function split(rhs)
            local cut = #rhs + 1
            for _, kw in ipairs({ 'end', 'else', 'elseif', 'until' }) do
                local p = rhs:find('%f[%w_]' .. kw .. '%f[^%w_]')
                if p and p < cut then cut = p end
            end
            return rhs:sub(1, cut - 1), rhs:sub(cut)
        end
        local function compound(lhs, op, rhs)
            local e, rest = split(rhs)
            local trail = e:match('%s*$')
            return lhs .. ' = ' .. lhs .. ' ' .. op .. ' (' .. e:gsub('%s*$', '') .. ')' .. trail .. rest
        end
        t = t:gsub('([%w_%.%[%]]+)%s*(%.%.)=%s*([^\n;]+)', compound)
        t = t:gsub('([%w_%.%[%]]+)%s*([%+%-%*/%%%^&|])=([^=][^\n;]*)', compound)
        out[#out + 1] = t
    end
    while i <= n do
        local c, c2 = src:sub(i, i), src:sub(i + 1, i + 1)
        if c == '-' and c2 == '-' then
            flush()
            local lvl = longOpen(i + 2)
            local e
            if lvl then
                local close = ']' .. string.rep('=', lvl) .. ']'
                local _, ce = src:find(close, i + 2, true); e = ce or n
            else
                e = (src:find('\n', i, true) or (n + 1)) - 1
            end
            out[#out + 1] = src:sub(i, e); i = e + 1
        elseif c == '/' and c2 == '*' then
            flush()
            local _, e = src:find('*/', i + 2, true); e = e or n
            local body = src:sub(i, e)
            out[#out + 1] = ' ' .. string.rep('\n', select(2, body:gsub('\n', ''))); i = e + 1
        elseif c == '"' or c == "'" then
            flush()
            local j = i + 1
            while j <= n and src:sub(j, j) ~= c and src:sub(j, j) ~= '\n' do
                j = j + (src:sub(j, j) == '\\' and 2 or 1)
            end
            out[#out + 1] = src:sub(i, j); i = j + 1
        elseif c == '`' then
            flush()
            local e = src:find('`', i + 1, true) or n
            out[#out + 1] = tostring(joaat(src:sub(i + 1, e - 1))); i = e + 1
        elseif c == '[' and longOpen(i) then
            flush()
            local lvl = longOpen(i)
            local close = ']' .. string.rep('=', lvl) .. ']'
            local _, e = src:find(close, i + 2, true); e = e or n
            out[#out + 1] = src:sub(i, e); i = e + 1
        else
            code[#code + 1] = c; i = i + 1
        end
    end
    flush()
    return table.concat(out)
end

-- ── a tiny JSON encoder (NUI message size) and decoder (KVP / recipes) ─────────────
local function jencode(v, seen)
    local t = type(v)
    if t == 'nil' then return 'null'
    elseif t == 'boolean' then return tostring(v)
    elseif t == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return 'null' end
        return (math.type(v) == 'integer' or v == math.floor(v)) and string.format('%d', v) or string.format('%.14g', v)
    elseif t == 'string' then
        return '"' .. v:gsub('[%c"\\]', function(ch) return string.format('\\u%04x', ch:byte()) end) .. '"'
    elseif t == 'table' then
        seen = seen or {}
        if seen[v] then return 'null' end
        seen[v] = true
        local parts, isArr = {}, (#v > 0 or next(v) == nil)
        if isArr then
            for _, x in ipairs(v) do parts[#parts + 1] = jencode(x, seen) end
            seen[v] = nil
            return '[' .. table.concat(parts, ',') .. ']'
        end
        for k, x in pairs(v) do
            if type(x) ~= 'function' then parts[#parts + 1] = jencode(tostring(k)) .. ':' .. jencode(x, seen) end
        end
        seen[v] = nil
        return '{' .. table.concat(parts, ',') .. '}'
    end
    return 'null'
end
local function jdecode(s)
    if type(s) ~= 'string' or s == '' then return nil end
    local lua = s:gsub('%[', '{'):gsub('%]', '}'):gsub('"([^"]-)"%s*:', '["%1"]='):gsub('null', 'nil')
    local f = load('return ' .. lua, 'json', 't', {})
    if not f then return nil end
    local ok, v = pcall(f); return ok and v or nil
end

-- ── vectors ─────────────────────────────────────────────────────────────────
local Vmt = {}
Vmt.__index = function(v, k)
    if k == 'xy' then return setmetatable({ x = v.x, y = v.y }, Vmt) end
    if k == 'xyz' then return setmetatable({ x = v.x, y = v.y, z = v.z }, Vmt) end
end
local function vec(x, y, z, w) return setmetatable({ x = x or 0.0, y = y or 0.0, z = z, w = w }, Vmt) end
local function op(f) return function(a, b)
    if type(a) == 'number' then a, b = b, a end
    if type(b) == 'number' then return vec(f(a.x, b), f(a.y, b), a.z and f(a.z, b), a.w and f(a.w, b)) end
    return vec(f(a.x, b.x), f(a.y, b.y), a.z and f(a.z, b.z or 0), a.w and f(a.w, b.w or 0))
end end
Vmt.__add = op(function(p, q) return p + q end)
Vmt.__sub = op(function(p, q) return p - q end)
Vmt.__mul = op(function(p, q) return p * q end)
Vmt.__div = op(function(p, q) return p / q end)
Vmt.__unm = function(a) return vec(-a.x, -a.y, a.z and -a.z, a.w and -a.w) end
Vmt.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + (a.z or 0) ^ 2 + (a.w or 0) ^ 2) end
Vmt.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z and a.w == b.w end
Vmt.__tostring = function(a) return ('vector(%g, %g, %s)'):format(a.x, a.y, tostring(a.z)) end

-- ── fxmanifest ──────────────────────────────────────────────────────────────
local function readManifest()
    local src = readfile('fxmanifest.lua') or readfile('__resource.lua')
    if not src then die('no fxmanifest.lua here: run from the resource root') end
    local m = { shared = {}, client = {}, name = nil }
    local function adder(list) return function(v)
        if type(v) == 'table' then for _, x in ipairs(v) do list[#list + 1] = x end else list[#list + 1] = v end
    end end
    local env = setmetatable({
        shared_script = adder(m.shared), shared_scripts = adder(m.shared),
        client_script = adder(m.client), client_scripts = adder(m.client),
        name = function(v) m.name = v end,
    }, { __index = function() return function() return function() end end end })
    local f, err = load(cfxToLua(src), '@fxmanifest.lua', 't', env)
    if not f then die(err) end
    f()
    local files = {}
    -- FiveM's globs: `*` and `?` within one name, `**` across folders (`a/**/b.lua` is also `a/b.lua`),
    -- in the file name or in a folder
    local function variants(glob)             -- each `**/` stands for no folder, or one or more (\0)
        local i = glob:find('**/', 1, true)
        if not i then return { glob } end
        local out = {}
        for _, rest in ipairs(variants(glob:sub(i + 3))) do
            out[#out + 1] = glob:sub(1, i - 1) .. rest
            out[#out + 1] = glob:sub(1, i - 1) .. '\0' .. rest
        end
        return out
    end
    local function patterns(glob)
        local out = {}
        for _, v in ipairs(variants(glob)) do
            local lp = v:gsub('[%^%$%(%)%%%.%[%]%+%-]', '%%%0'):gsub('%*%*', '\1'):gsub('%*', '[^/]*')
                :gsub('%?', '[^/]'):gsub('\1', '.*'):gsub('%z', '.-/')
            out[#out + 1] = '^' .. lp .. '$'
        end
        return out
    end
    local function expand(p)
        if p:sub(1, 1) == '@' then files[#files + 1] = p; return end
        if p:find('[%*%?]') then
            local base = p:sub(1, (p:find('[%*%?]') or 1) - 1):match('^(.*)/') or '.'
            local pats = patterns(p)
            local find = io.popen('find "' .. base .. '" -type f 2>/dev/null')
            local names = {}
            for line in find:lines() do
                line = line:gsub('^%./', '')
                for _, pat in ipairs(pats) do if line:match(pat) then names[#names + 1] = line; break end end
            end
            find:close(); table.sort(names)
            for _, nm in ipairs(names) do files[#files + 1] = nm end
        else
            files[#files + 1] = p
        end
    end
    for _, p in ipairs(m.shared) do expand(p) end      -- FiveM loads shared scripts first
    for _, p in ipairs(m.client) do expand(p) end
    m.files = files
    return m
end

-- The first word of a native's name. A global that does not start with one of these is not taken for a native.
local VERBS = {}
for w in ([[Activate Add Allow Animate Animpostfx Apply Are Attach Begin Block Bring Call Can Cancel Cascade Cast Cellcam
    Change Clear Clone Close Compare Copy Create Datafile Deactivate Decor Delete Destroy Detach Disable Display Does Draw
    Enable End End Enumerate Execute Explode Extend Fade Find Fire Fix Flash Force Freeze Get Give Hang Has Have Hide
    Hint Ignore Init Instantly Interior Invalidate Is Kill Knock Leave Load Lock Make Mark Modify Mumble Network Obj
    Open Override Pause Ped Place Play Populate Prepare Preload Process Push Raise Read Reconcile Refresh Register
    Release Reload Remove Render Replace Request Reserve Reset Restart Restore Resurrect Return Save Scaleform Script
    Seethrough Select Send Set Shake Shoot Should Show Shut Simulate Slide Smash Specify Spawn Start Stat Stop Suppress
    Switch Take Task Teleport Terminate Text Toggle Trigger Unlock Unpin Unregister Update Use Vehicle Wait Was Wash
    Water Thefeed Undo Ui Unload Unmount Player Obj Veh Ped Net Cam Audio Hud Blip]]):gmatch('%a+') do VERBS[w] = true end

-- ── one simulated run of one scenario ──────────────────────────────────────
local function run(recipe, manifest, sc)
    local world = {
        now = 0, frame = 0, ped = 1001, pos = vec(0.0, 0.0, 30.0), heading = 0.0, speed = 0.0,
        vehicle = false, seat = -1, health = 200, armour = 0, clock = 12, rpm = 0.2, gear = 1,
    }
    for k, v in pairs(recipe.world or {}) do world[k] = v end
    for k, v in pairs(sc.world or {}) do world[k] = v end
    if type(world.pos) == 'table' and getmetatable(world.pos) ~= Vmt then world.pos = vec(world.pos[1] or world.pos.x, world.pos[2] or world.pos.y, world.pos[3] or world.pos.z) end

    local M = {                                -- counters, reset after the warm-up
        natives = {}, nui = 0, nuiBytes = 0, nuiActions = {}, exports = {}, bagReads = 0, bagWrites = 0,
        events = 0, serverEvents = 0, wakeups = 0, cpu = 0.0, errors = {},
    }
    local threads, timers, handlers, nuiCbs = {}, {}, {}, {}
    local current
    local resName = recipe.resource or manifest.name or 'resource'

    local env = {}
    for _, k in ipairs({ 'assert', 'error', 'ipairs', 'next', 'pairs', 'pcall', 'xpcall', 'print', 'rawequal', 'rawget',
        'rawlen', 'rawset', 'select', 'setmetatable', 'getmetatable', 'tonumber', 'tostring', 'type', 'unpack', 'math',
        'string', 'table', 'coroutine', 'utf8', 'os', 'collectgarbage', 'load', 'debug' }) do env[k] = _G[k] end
    env.print = function() end                   -- scripts' prints are noise here
    env.warn = function() end
    env.table = setmetatable({                   -- FiveM's Lua adds table.wipe (ox_lib uses it)
        wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
    }, { __index = table })
    env._G = env
    env.unpack = table.unpack
    math.randomseed(1)

    -- statebags: every read and write counted
    local function bag(store)
        return setmetatable({}, {
            __index = function(_, k)
                if k == 'set' then return function(_, key, v) M.bagWrites = M.bagWrites + 1; store[key] = v end end
                M.bagReads = M.bagReads + 1; return store[k]
            end,
            __newindex = function(_, k, v) M.bagWrites = M.bagWrites + 1; store[k] = v end,
        })
    end
    local playerBag = {}
    for k, v in pairs(recipe.playerState or {}) do playerBag[k] = v end
    local entityBags = {}
    local function entityBag(h)
        entityBags[h] = entityBags[h] or {}
        for k, v in pairs((recipe.entityState or {})) do if entityBags[h][k] == nil then entityBags[h][k] = v end end
        return { state = bag(entityBags[h]) }
    end
    env.LocalPlayer = { state = bag(playerBag) }
    env.GlobalState = bag({})
    env.Entity = entityBag
    env.Player = function() return { state = bag(playerBag) } end
    env.AddStateBagChangeHandler = function() return 1 end
    env.RemoveStateBagChangeHandler = function() end

    -- the scheduler
    local function spawn(fn, delay)
        local co = coroutine.create(fn)
        local info = debug.getinfo(fn, 'S')
        local site = (info.short_src or '?'):gsub('^.*/client/', 'client/') .. ':' .. (info.linedefined or 0)
        threads[#threads + 1] = { co = co, wake = world.now + (delay or 0), site = site, wakes = 0, cpu = 0.0, frames = {} }
    end
    env.CreateThread = function(fn) spawn(fn, 0) end
    env.SetTimeout = function(ms, fn) spawn(fn, ms or 0) end
    env.Wait = function(ms)
        if not current then return end
        coroutine.yield(ms or 0)
    end
    env.Citizen = { CreateThread = env.CreateThread, Wait = env.Wait, SetTimeout = env.SetTimeout,
        Await = function(p) return p end, InvokeNative = function() return nil end }
    env.promise = { new = function() return { resolve = function() end, reject = function() end } end }
    env.Await = function(p) return p end

    -- events
    local function on(name, fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end
    env.AddEventHandler = function(name, fn) if fn then on(name, fn) end return { name = name } end
    env.RegisterNetEvent = function(name, fn) if fn then on(name, fn) end end
    env.RegisterServerEvent = env.RegisterNetEvent
    env.RemoveEventHandler = function() end
    env.TriggerEvent = function(name, ...)
        M.events = M.events + 1
        for _, fn in ipairs(handlers[name] or {}) do local ok, err = pcall(fn, ...); if not ok then M.errors['event ' .. name] = err end end
    end
    env.TriggerServerEvent = function() M.serverEvents = M.serverEvents + 1 end
    env.TriggerLatentServerEvent = env.TriggerServerEvent
    env.GetInvokingResource = function() return nil end
    env.source = 0

    -- NUI
    env.SendNUIMessage = function(t)
        M.nui = M.nui + 1
        local s = jencode(t); M.nuiBytes = M.nuiBytes + #s
        local a = type(t) == 'table' and (t.action or t.type) or '?'
        M.nuiActions[a] = (M.nuiActions[a] or 0) + 1
    end
    env.SendNuiMessage = function(s) M.nui = M.nui + 1; M.nuiBytes = M.nuiBytes + #(s or '') end
    env.RegisterNUICallback = function(name, fn) nuiCbs[name] = fn end
    env.RegisterCommand = function() end
    env.RegisterKeyMapping = function() end
    env.json = { encode = jencode, decode = jdecode }
    env.joaat = joaat
    env.msgpack = { pack = jencode, unpack = jdecode }
    env.vector2 = function(x, y) return vec(x, y) end
    env.vector3 = function(x, y, z) return vec(x, y, z or 0.0) end
    env.vector4 = function(x, y, z, w) return vec(x, y, z or 0.0, w or 0.0) end
    env.vec2, env.vec3, env.vec4 = env.vector2, env.vector3, env.vector4
    env.vec = function(x, y, z, w) return vec(x, y, z, w) end
    env.quat = env.vector4

    -- exports: ours register, others' are the recipe's fakes; every call into another resource counted
    local own = {}
    local otherFns = recipe.exports or {}
    env.exports = setmetatable({}, {
        __call = function(_, name, fn) own[name] = fn end,
        __index = function(_, res)
            if res == resName then return setmetatable({}, { __index = function(_, k) return function(_, ...) return own[k] and own[k](...) end end }) end
            return setmetatable({}, { __index = function(_, fname)
                return function(_, ...)
                    local key = res .. ':' .. fname
                    M.exports[key] = (M.exports[key] or 0) + 1
                    local f = otherFns[res] and otherFns[res][fname]
                    if type(f) == 'function' then return f(world, ...) end
                    if f == nil then error(('No such export %s in resource %s'):format(fname, res)) end
                    return f
                end
            end })
        end,
    })

    -- ox_lib's cache and the bits of lib a HUD uses; cache follows the world
    local cacheCbs = {}
    local cache = setmetatable({}, { __index = function(_, k)
        if k == 'ped' then return world.ped
        elseif k == 'playerId' then return 0
        elseif k == 'serverId' then return 1
        elseif k == 'vehicle' then return world.vehicle
        elseif k == 'seat' then return world.vehicle and world.seat or false
        elseif k == 'weapon' then return world.weapon or false
        elseif k == 'resource' then return resName
        elseif k == 'game' then return 'fivem' end
    end })
    env.cache = cache
    local libStub
    libStub = setmetatable({
        onCache = function(key, fn) cacheCbs[key] = cacheCbs[key] or {}; table.insert(cacheCbs[key], fn) end,
        callback = setmetatable({ await = function() return recipe.callbackResult end, register = function() end },
            { __call = function() end }),
        locale = function() end,
        notify = function() end,
        print = setmetatable({}, { __index = function() return function() end end }),
        requestAnimDict = function(d) return d end, requestModel = function(m) return m end,
        waitFor = function(fn) return fn() end,
        points = { new = function(t) return setmetatable(t or {}, { __index = { remove = function() end } }) end },
        zones = setmetatable({}, { __index = function() return function(t) return setmetatable(t or {}, { __index = { remove = function() end } }) end end }),
        addKeybind = function(t) return setmetatable(t or {}, { __index = { disable = function() end } }) end,
        table = { deepclone = function(t) return t end, contains = function(t, v) for _, x in pairs(t) do if x == v then return true end end return false end },
        math = { round = function(v, d) local m = 10 ^ (d or 0); return math.floor(v * m + 0.5) / m end },
        getClosestPlayer = function() return nil end, getNearbyVehicles = function() return {} end,
    }, { __index = function() return function() end end })
    env.lib = libStub
    -- a script's own load() gets Cfx Lua too, and its globals by default (ox_lib builds lib this way)
    env.load = function(chunk, name, mode, e)
        if type(chunk) == 'string' then chunk = cfxToLua(chunk) end
        return load(chunk, name, mode, e or env)
    end
    -- ox_lib's require (an ox-layout client entry needs it): from the resource root, dots for
    -- folders, `x` or `x/init`, each module run once
    local modules = {}
    env.require = function(name)
        if modules[name] ~= nil then return modules[name] end
        local path = name:gsub('%.', '/')
        local file = readfile(path .. '.lua') and path .. '.lua' or path .. '/init.lua'
        local src = readfile(file)
        if not src then error(("module '%s' not found"):format(name), 2) end
        local value = assert(load(cfxToLua(src), '@' .. file, 't', env))()
        if value == nil then value = true end
        modules[name] = value
        return value
    end
    env.QBX = recipe.qbx or { PlayerData = { citizenid = 'X0000000', metadata = { hunger = 80, thirst = 70 } } }
    env.QBCore = nil

    -- natives: the world answers what it knows, the recipe overrides, the rest get a default by name
    local W = {
        PlayerPedId = function() return world.ped end, PlayerId = function() return 0 end,
        GetPlayerPed = function() return world.ped end, GetPlayerServerId = function() return 1 end,
        GetGameTimer = function() return math.floor(world.now) end, GetFrameTime = function() return 1 / FPS end,
        GetEntityCoords = function() return world.pos end,
        GetEntityHeading = function() return world.heading end,
        GetEntitySpeed = function() return world.speed end,
        GetEntityVelocity = function() return vec(0.0, world.speed, 0.0) end,
        GetEntitySpeedVector = function() return vec(0.0, world.speed, 0.0) end,
        GetEntityRotation = function() return vec(0.0, 0.0, world.heading) end,
        GetGameplayCamRot = function() return vec(0.0, 0.0, world.camHeading or world.heading) end,
        GetEntityHealth = function() return world.health end, GetPedArmour = function() return world.armour end,
        GetEntityModel = function() return world.model or 0 end,
        IsPedInAnyVehicle = function() return world.vehicle and true or false end,
        GetVehiclePedIsIn = function() return world.vehicle or 0 end,
        GetVehicleCurrentRpm = function() return world.rpm end, GetVehicleCurrentGear = function() return world.gear end,
        GetVehicleNextGear = function() return world.gear end, GetVehicleHighGear = function() return 6 end,
        GetVehicleClass = function() return world.vclass or 0 end,
        GetIsVehicleEngineRunning = function() return world.vehicle and true or false end,
        GetVehicleEngineHealth = function() return 1000.0 end, GetVehicleFuelLevel = function() return 60.0 end,
        GetVehicleLightsState = function() return 1, 0, 0 end,
        GetVehicleEstimatedMaxSpeed = function() return 50.0 end,
        DoesEntityExist = function(e) return e ~= nil and e ~= 0 and e ~= false end,
        IsEntityDead = function() return world.dead == true end, IsPlayerDead = function() return world.dead == true end,
        IsEntityVisible = function() return true end, IsScreenFadedIn = function() return true end,
        IsPlayerControlOn = function() return true end, NetworkIsPlayerActive = function() return true end,
        NetworkGetEntityIsNetworked = function() return true end,
        IsPlayerSwitchInProgress = function() return false end, IsPauseMenuActive = function() return false end,
        GetActiveScreenResolution = function() return 1920, 1080 end,
        GetSafeZoneSize = function() return 1.0 end,
        GetScriptGfxAlignPosition = function(x, y) return x, y end,
        GetClockHours = function() return world.clock end, GetClockMinutes = function() return 0 end,
        GetCurrentResourceName = function() return resName end,
        LoadResourceFile = function(res, path) if res == resName then return readfile(path) end end,
        GetResourceState = function(r)
            if r == resName then return 'started' end
            for _, s in ipairs(recipe.resources or {}) do if s == r then return 'started' end end
            return 'missing'
        end,
        GetHashKey = joaat,
        GetStreetNameAtCoord = function() return 1, 0 end, GetStreetNameFromHashKey = function(h) return h == 0 and '' or 'Sample Street' end,
        GetNameOfZone = function() return 'ZONE' end, GetLabelText = function() return 'Sample District' end,
        RequestScaleformMovie = function() return 1 end, HasScaleformMovieLoaded = function() return true end,
        HasStreamedTextureDictLoaded = function() return true end,
        GetResourceKvpString = function() return nil end, GetResourceKvpInt = function() return 0 end,
        GetResourceKvpFloat = function() return 0.0 end,
        GetSelectedPedWeapon = function() return world.weapon or joaat('WEAPON_UNARMED') end,
        GetPlayerSprintStaminaRemaining = function() return 0.0 end,
        GetPlayerUnderwaterTimeRemaining = function() return 10.0 end,
        IsWaypointActive = function() return world.waypoint and true or false end,
        GetFirstBlipInfoId = function() return world.waypoint and 1 or 0 end,
        GetBlipInfoIdCoord = function() return world.waypoint and vec(world.waypoint[1], world.waypoint[2], 0.0) or vec(0, 0, 0) end,
        DoesBlipExist = function(b) return b ~= 0 end,
        IsControlJustPressed = function() return false end, IsControlPressed = function() return false end,
        IsDisabledControlJustPressed = function() return false end, IsDisabledControlPressed = function() return false end,
        GetDisabledControlNormal = function() return 0.0 end, GetControlNormal = function() return 0.0 end,
        GetOffsetFromEntityInWorldCoords = function(_, x, y, z) return world.pos + vec(x, y, z) end,
    }
    local overrides = {}
    for k, v in pairs(recipe.natives or {}) do overrides[k] = v end
    for k, v in pairs(sc.natives or {}) do overrides[k] = v end
    local stubs = {}
    local function default(name)
        if name:match('^Is') or name:match('^Has') or name:match('^Does') or name:match('^Can') or name:match('^Network') then
            return function() return false end
        end
        if name:match('Coord') or name:match('Velocity') or name:match('Rotation') or name:match('Vector') or name:match('Offset') then
            return function() return vec(0.0, 0.0, 0.0) end
        end
        if name:match('^Get') then return function() return 0 end end
        return function() return nil end
    end
    setmetatable(env, { __index = function(_, k)
        -- natives are CamelCase and start with a verb (GetEntityCoords, IsPedSprinting...), or are N_0x...;
        -- anything else (Config, NxtPause, a module table) is a global the scripts have not set yet
        if type(k) ~= 'string' then return nil end
        if not k:match('^N_0x') then
            if not k:match('^[A-Z][%w]*$') then return nil end
            if not (VERBS[k:match('^[A-Z][a-z]*')] or W[k] or overrides[k] ~= nil) then return nil end
        end
        local s = stubs[k]
        if s then return s end
        local impl = overrides[k]
        if impl ~= nil and type(impl) ~= 'function' then local v = impl; impl = function() return v end
        elseif type(impl) == 'function' then local f = impl; impl = function(...) return f(world, ...) end end
        impl = impl or W[k] or default(k)
        s = function(...) M.natives[k] = (M.natives[k] or 0) + 1; return impl(...) end
        stubs[k] = s
        return s
    end })

    -- load the scripts
    for _, p in ipairs(manifest.files) do
        if p:sub(1, 1) ~= '@' then
            local src = readfile(p)
            if not src then M.errors['load ' .. p] = 'missing file' else
                local f, err = load(cfxToLua(src), '@' .. p, 't', env)
                if not f then M.errors['load ' .. p] = err else
                    current = { site = p }
                    local co = coroutine.create(f)
                    local ok, res = coroutine.resume(co)
                    current = nil
                    if not ok then M.errors['run ' .. p] = res
                    elseif coroutine.status(co) == 'suspended' then
                        threads[#threads + 1] = { co = co, wake = world.now + (res or 0), site = p .. ':main', wakes = 0, cpu = 0.0, frames = {} }
                    end
                end
            end
        end
    end
    if type(recipe.boot) == 'function' then recipe.boot(env, world) end
    if type(sc.boot) == 'function' then sc.boot(env, world) end
    env.TriggerEvent('onClientResourceStart', resName)

    -- play
    local dt = 1000 / FPS
    local warm, total = (sc.warmup or recipe.warmup or 5) * FPS, ((sc.warmup or recipe.warmup or 5) + (sc.seconds or recipe.seconds or 10)) * FPS
    local lastVeh = world.vehicle
    local memStart, measuring
    for f = 1, total do
        world.frame = f
        world.now = world.now + dt
        if f == warm + 1 then
            -- start measuring: zero the counters, stop the collector so allocations can be counted
            for k, v in pairs(M) do
                if type(v) == 'number' then M[k] = 0 elseif k ~= 'errors' then M[k] = {} end
            end
            for _, t in ipairs(threads) do t.wakes, t.cpu, t.frames = 0, 0.0, {} end
            collectgarbage('collect'); collectgarbage('stop')
            memStart, measuring = collectgarbage('count'), true
        end
        if sc.step then sc.step(world, (f - warm) / FPS) end
        if world.vehicle ~= lastVeh then
            lastVeh = world.vehicle
            for _, fn in ipairs(cacheCbs.vehicle or {}) do pcall(fn, world.vehicle) end
            for _, fn in ipairs(cacheCbs.seat or {}) do pcall(fn, world.vehicle and world.seat or false) end
        end
        local i = 1
        while i <= #threads do
            local t = threads[i]
            if t.wake <= world.now and coroutine.status(t.co) == 'suspended' then
                current = t
                local c0 = os.clock()
                local ok, res = coroutine.resume(t.co)
                local c1 = os.clock()
                current = nil
                t.cpu, t.wakes = t.cpu + (c1 - c0), t.wakes + 1
                if measuring then t.frames[f] = true end
                M.wakeups, M.cpu = M.wakeups + 1, M.cpu + (c1 - c0)
                if not ok then M.errors[t.site] = res; table.remove(threads, i); goto continue end
                if coroutine.status(t.co) == 'dead' then table.remove(threads, i); goto continue end
                local ms = tonumber(res) or 0
                t.wake = ms <= 0 and (world.now + dt * 0.5) or (world.now + ms)
            end
            i = i + 1
            ::continue::
        end
    end
    local mem = collectgarbage('count') - (memStart or 0)
    collectgarbage('restart')

    local secs = (sc.seconds or recipe.seconds or 10)
    local frames = secs * FPS
    local frameThreads, hot = 0, {}
    for _, t in ipairs(threads) do
        local n = 0
        for _ in pairs(t.frames) do n = n + 1 end
        if n >= frames * 0.9 then frameThreads = frameThreads + 1 end
        if t.wakes > 0 then hot[#hot + 1] = { site = t.site, wakes = t.wakes / secs, ms = t.cpu * 1000 / frames } end
    end
    table.sort(hot, function(a, b) return a.ms > b.ms end)
    local nat, natN = {}, 0
    for k, v in pairs(M.natives) do nat[#nat + 1] = { k, v / secs }; natN = natN + v end
    table.sort(nat, function(a, b) return a[2] > b[2] end)
    local ex, exN = {}, 0
    for k, v in pairs(M.exports) do ex[#ex + 1] = { k, v / secs }; exN = exN + v end
    table.sort(ex, function(a, b) return a[2] > b[2] end)
    local na = {}
    for k, v in pairs(M.nuiActions) do na[#na + 1] = { k, v / secs } end
    table.sort(na, function(a, b) return a[2] > b[2] end)
    return {
        name = sc.name,
        counts = {
            frameThreads = frameThreads, wakeups = M.wakeups / secs, natives = natN / secs, nui = M.nui / secs,
            nuiKB = M.nuiBytes / 1024 / secs, exports = exN / secs, bagReads = M.bagReads / secs,
            bagWrites = M.bagWrites / secs, events = M.events / secs, allocKB = mem / secs,
        },
        luaMs = M.cpu * 1000 / frames,
        hot = hot, natives = nat, exports = ex, nuiActions = na, errors = M.errors,
    }
end

-- ── output ──────────────────────────────────────────────────────────────────
local COLS = {
    { 'frameThreads', 'threads woken every frame', '%d' },
    { 'wakeups', 'thread wake-ups / s', '%.0f' },
    { 'natives', 'native calls / s', '%.0f' },
    { 'nui', 'NUI messages / s', '%.1f' },
    { 'nuiKB', 'NUI KB / s', '%.2f' },
    { 'exports', 'calls to other resources / s', '%.1f' },
    { 'bagReads', 'statebag reads / s', '%.1f' },
    { 'bagWrites', 'statebag writes / s', '%.2f' },
    { 'events', 'local events / s', '%.1f' },
    { 'allocKB', 'memory allocated KB / s', '%.1f' },
}

local function report(results)
    for _, r in ipairs(results) do
        print(('\n== %s ==  (Lua %.3f ms a frame on this machine, stub natives: compare runs, not resmon)'):format(r.name, r.luaMs))
        for _, c in ipairs(COLS) do print(('  %-32s ' .. c[3]):format(c[2], r.counts[c[1]])) end
        print('  busiest threads (ms a frame here, wake-ups / s):')
        for i = 1, math.min(6, #r.hot) do print(('    %-40s %.4f  %6.1f'):format(r.hot[i].site, r.hot[i].ms, r.hot[i].wakes)) end
        print('  most-called natives / s:')
        for i = 1, math.min(8, #r.natives) do print(('    %-40s %.1f'):format(r.natives[i][1], r.natives[i][2])) end
        if #r.exports > 0 then
            print('  calls to other resources / s:')
            for i = 1, math.min(6, #r.exports) do print(('    %-40s %.1f'):format(r.exports[i][1], r.exports[i][2])) end
        end
        if #r.nuiActions > 0 then
            print('  NUI messages by action / s:')
            for i = 1, math.min(6, #r.nuiActions) do print(('    %-40s %.1f'):format(r.nuiActions[i][1], r.nuiActions[i][2])) end
        end
        local errs = {}
        for k, v in pairs(r.errors) do errs[#errs + 1] = k .. ': ' .. tostring(v) end
        if #errs > 0 then
            table.sort(errs)
            print('  errors (a stub may need a value in the recipe):')
            for _, e in ipairs(errs) do print('    ' .. e) end
        end
    end
end

local function serialize(results)
    local L = { '-- written by `lua5.4 .github/nxt/perf.lua baseline`; counts per second (frameThreads: a count)', 'return {' }
    for _, r in ipairs(results) do
        local parts = {}
        for _, c in ipairs(COLS) do parts[#parts + 1] = ('%s = %.2f'):format(c[1], r.counts[c[1]]) end
        L[#L + 1] = ('    [%q] = { %s },'):format(r.name, table.concat(parts, ', '))
    end
    L[#L + 1] = '}'
    return table.concat(L, '\n') .. '\n'
end

-- ── main ────────────────────────────────────────────────────────────────────
local mode, a1, a2 = arg[1] or 'run', arg[2], arg[3]

if mode == 'compare' then
    local A = a1 and load(readfile(a1) or '', a1, 't', {})
    local B = a2 and load(readfile(a2) or '', a2, 't', {})
    if not (A and B) then die('compare needs two baseline files') end
    A, B = A(), B()
    for name, ca in pairs(A) do
        local cb = B[name] or {}
        print(('\n== %s ==%s'):format(name, B[name] and '' or '  (not in the second file)'))
        print(('  %-32s %12s %12s %8s'):format('', 'first', 'second', 'change'))
        for _, c in ipairs(COLS) do
            local x, y = ca[c[1]] or 0, cb[c[1]] or 0
            local ch = x == 0 and (y == 0 and '' or 'new') or ('%+.0f%%'):format((y - x) / x * 100)
            print(('  %-32s %12.2f %12.2f %8s'):format(c[2], x, y, ch))
        end
    end
    os.exit(0)
end

local rsrc = readfile(RECIPE)
if not rsrc then die('no recipe at ' .. RECIPE .. ' (see tools/README-perf.md in nxt-md)') end
local rf, rerr = load(rsrc, '@' .. RECIPE, 't', setmetatable({ vector3 = function(x, y, z) return vec(x, y, z) end, joaat = joaat }, { __index = _G }))
if not rf then die(rerr) end
local recipe = rf()
local manifest = readManifest()

local results = {}
for _, sc in ipairs(recipe.scenarios or {}) do results[#results + 1] = run(recipe, manifest, sc) end
report(results)

if mode == 'baseline' then
    local fh = assert(io.open(BASELINE, 'wb')); fh:write(serialize(results)); fh:close()
    print('\nperf: baseline written to ' .. BASELINE)
elseif mode == 'check' then
    local bsrc = readfile(BASELINE)
    if not bsrc then print('\nperf: no baseline (' .. BASELINE .. '); nothing to check against'); os.exit(0) end
    local base = load(bsrc, '@' .. BASELINE, 't', {})()
    local bad = 0
    local slack = recipe.slack or 0.10           -- a count may grow 10 % (plus a small absolute margin) before it fails
    for _, r in ipairs(results) do
        local b = base[r.name]
        if b then
            for _, c in ipairs(COLS) do
                local was, now = b[c[1]] or 0, r.counts[c[1]]
                local limit = was * (1 + slack) + (c[1] == 'frameThreads' and 0 or 1)
                if now > limit then
                    bad = bad + 1
                    print(('::error::perf: %s, %s went from %.2f to %.2f'):format(r.name, c[2], was, now))
                end
            end
        end
        for k, v in pairs(r.errors) do
            bad = bad + 1
            print(('::error::perf: %s: %s: %s'):format(r.name, k, tostring(v)))
        end
    end
    if bad > 0 then
        print('perf: if the rise is meant, run `lua5.4 .github/nxt/perf.lua baseline` and commit the new baseline')
        os.exit(1)
    end
    print('\nperf: within the baseline')
end
