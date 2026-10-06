 
 
 
 
local nonhuman_family = (function()
    local helper = {}
    local enum_values
    local metrics = { inspected = 0, eligible = 0, skipped = 0, recent = {} }
    performance.nonhuman_family = metrics

    local function read(object, method, ...)
        if not object then return nil end
        local ok, value = safe_call(object, method, ...)
        if ok then return value end
        return nil
    end

    local function address(object)
        if not object then return nil end
        local ok, value = pcall(function() return object:get_address() end)
        if ok and type(value) == "number" and value > 0 and value % 1 == 0 then return value end
        return nil
    end

     
    local function constants()
        if enum_values ~= nil then return enum_values end
        local ok, values = pcall(function()
            local function value(kind, name)
                local definition = assert(safe_sdk_type(kind), "enum type unavailable")
                local field = assert(definition:get_field(name), "enum field unavailable")
                local result = field:get_data(nil)
                assert(type(result) == "number" and result == result and result % 1 == 0, "invalid enum value")
                return result
            end
            return {
                species = value("app.NpcDef.SPECIES", "RYUJIN"),
                normal = value("app.NpcDef.SKELETON_TYPE", "RYUJIN_NML"),
                small = value("app.NpcDef.SKELETON_TYPE", "RYUJIN_SML")
            }
        end)
        enum_values = ok and values or false
        return enum_values
    end

    local function joint(transform, name)
        local object = read(transform, "getJointByName", name)
        if object and read(object, "get_Valid") == true then return object end
        return nil
    end

     
    local function source_legs(transform, profile)
        local chain = profile == "RYUJIN_NML" and { "Thigh", "Knee", "Shin", "Foot", "Toe" }
            or { "Thigh", "Shin", "Foot", "Toe" }
        for _, side in ipairs({ "L", "R" }) do
            if joint(transform, side .. "_Instep") then return false end
            if profile == "RYUJIN_SML" and joint(transform, side .. "_Knee") then return false end
            local previous
            for _, suffix in ipairs(chain) do
                local name = side .. "_" .. suffix
                local current = joint(transform, name)
                if not current or previous and read(read(current, "get_Parent"), "get_Name") ~= previous then
                    return false
                end
                previous = name
            end
        end
        return true
    end

     
    local function source_fingers(transform)
        for _, side in ipairs({ "L", "R" }) do
            local previous = side .. "_Palm"
            if not joint(transform, previous) then return false end
            for index = 1, 3 do
                if joint(transform, side .. "_PinkyF" .. index) then return false end
                local name = side .. "_RingF" .. index
                local current = joint(transform, name)
                if not current or read(read(current, "get_Parent"), "get_Name") ~= previous then return false end
                previous = name
            end
        end
        return true
    end

    function helper.classify(candidate, state, entry)
         
        if not same_runtime_object(read(entry.character, "get_GameObject"), candidate.obj) then
            return { profile = "unsupported", leg_ok = false, fingers_ok = false, reason = "not the NPC root" }
        end
        local root_id, motion_id, skeleton_id = address(candidate.obj), address(state.motion), address(state.custom_skeleton)
        if not root_id or not motion_id or not skeleton_id then
            return { profile = "unsupported", leg_ok = false, fingers_ok = false, reason = "native identity unavailable" }
        end
        local cached = entry.nonhuman_family
        if cached and cached.root == root_id and cached.motion == motion_id and cached.skeleton == skeleton_id
            and cached.generation == scene_generation then return cached end
         
         
        local result = { profile = "unsupported", leg_ok = false, fingers_ok = false, reason = "native tags unavailable",
            root = root_id, motion = motion_id, skeleton = skeleton_id, generation = scene_generation }
        entry.nonhuman_family = result
        metrics.inspected = metrics.inspected + 1
        local values = constants()
        local context = values and read(entry.character, "get_NpcContext")
        if context then
            local species_ok, species = safe_field(context, "Species")
            local skeleton_ok, skeleton = safe_field(context, "SkeletonType")
            if species_ok and type(species) == "number" then result.species = species end
            if skeleton_ok and type(skeleton) == "number" then result.skeleton_type = skeleton end
            if species_ok and skeleton_ok and species == values.species
                and (skeleton == values.normal or skeleton == values.small) then
                result.profile = skeleton == values.normal and "RYUJIN_NML" or "RYUJIN_SML"
                result.ik_asset = skeleton == values.normal and "NpcIkLeg_Ryujin.ikleg2" or "NpcIkLeg_RyujinSmall.ikleg2"
                local transform = get_transform(candidate.obj)
                if transform and read(state.motion, "get_JointsConstructed") == true then
                    result.leg_ok = source_legs(transform, result.profile)
                    result.fingers_ok = source_fingers(transform)
                    result.reason = "native tags and original joint topology checked"
                else
                    result.reason = "original joints unavailable; no speculative correction"
                end
                metrics.eligible = metrics.eligible + 1
            else
                result.reason = "species/skeleton family not supported"
            end
        end
        if not result.leg_ok and not result.fingers_ok then metrics.skipped = metrics.skipped + 1 end
         
        local row = { npc_id = tostring(entry.npc_id), generation = scene_generation }
        for key, value in pairs(result) do row[key] = value end
        metrics.recent[#metrics.recent + 1] = row
        if #metrics.recent > 16 then table.remove(metrics.recent, 1) end
        bs_log("[NonhumanFamily] " .. row.npc_id .. " " .. result.profile .. " " .. result.reason)
        return result
    end

    return helper
end)()
