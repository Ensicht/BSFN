 
local registry = ...
assert(type(registry) == "table", "BoneSystem private registry missing")
assert(type(sdk.fix_bone) == "function" and type(sdk.bind_face) == "function",
    "Not the initialized BoneSystem private Lua state")

if rawget(_G, "__BSFNStockBridgeAttempted") then
    assert(rawget(_G, "__BSFNStockBridgeReady"), "Previous bridge attempt failed; reset scripts")
    return
end
_G.__BSFNStockBridgeAttempted = true

local report = { version = "1.7.5", status = "locating_original_closures",
    route = "stock_dll_private_state", registry_entries = 0, functions_checked = 0 }
local function write_report()
    if json and json.dump_file then
        pcall(json.dump_file, "BoneSystemForNPC/StockBridgeReport.json", report)
    end
end

 
local function attach()
    local seen, found = {}, {}
    local function original_info(fn)
        if type(fn) ~= "function" then return nil end
        local info = debug.getinfo(fn, "Su")
        if info.what ~= "Lua" or not info.source:match("[\\/]BoneSystem%.lua$") then
            return nil
        end
        return info
    end
    local function visit(fn, depth)
        if seen[fn] or depth > 8 or not original_info(fn) then return end
        seen[fn] = true
        report.functions_checked = report.functions_checked + 1
        assert(report.functions_checked <= 512, "BoneSystem closure search budget exceeded")
        for i = 1, 255 do
            local name, value = debug.getupvalue(fn, i)
            if not name then break end
            if name == "fix_bone" or name == "load_data" then
                local info = original_info(value)
                local first = name == "fix_bone" and 511 or 236
                local last = name == "fix_bone" and 635 or 248
                local count = name == "fix_bone" and 3 or 1
                if info and info.linedefined == first and info.lastlinedefined == last
                    and info.nparams == count then
                    assert(not found[name] or found[name] == value, "Ambiguous original " .. name)
                    found[name] = value
                end
            end
            if type(value) == "function" then visit(value, depth + 1) end
        end
    end
    for key, value in next, registry do
        report.registry_entries = report.registry_entries + 1
        assert(report.registry_entries <= 16384, "BoneSystem registry search budget exceeded")
        if type(key) == "number" and type(value) == "function" then visit(value, 0) end
    end
    assert(found.fix_bone and found.load_data, "Original BoneSystem closures not found")

    local script, err = loadfile("reframework/autorun/BSNPC.lua")
    assert(script, err)
    report.fix_bone = debug.getinfo(found.fix_bone, "Su")
    report.load_data = debug.getinfo(found.load_data, "Su")
     
    _G.BoneSystemNPCAPI = { fix_bone = found.fix_bone, load_data = found.load_data }
    _G.__BSFNStockBridgeAuthorized = true
    script()
    assert(rawget(_G, "__BoneSystemForNPCLoaded"), "BSFN did not complete its entry guard")
    _G.__BSFNStockBridgeReady = true
    report.status = "ready"
end

local ok, err = xpcall(attach, debug.traceback)
if not ok then report.status = "failed"; report.error = tostring(err) end
write_report()
assert(ok, err)
