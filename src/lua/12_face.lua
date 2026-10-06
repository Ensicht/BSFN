 
 
 
 

local function use_private_face_mode(target)
    if config.auto_apply_face_mapping == false then
        return true
    end
    if target and target.private_face_mode ~= nil then
        return target.private_face_mode == true
    end
    return config.default_private_face_mode == true
end

 
local function make_target_bone_data(bone_data, target)
    if type(bone_data) ~= "table" then
        return bone_data, false, "bonesystem"
    end
    local private_mode = use_private_face_mode(target)
    if not private_mode then
        return bone_data, false, "bonesystem"
    end
    local api_bone_data = {}
    for key, value in pairs(bone_data) do
        api_bone_data[key] = value
    end
    api_bone_data.HideFace = false
    api_bone_data.BindFace = false
    return api_bone_data, true, "private"
end

local function probe_call(obj, method_name, ...)
    if not obj or type(method_name) ~= "string" then
        return false, nil
    end
    local args = { ... }
    local ok, result = pcall(function()
        return obj:call(method_name, unpack_args(args))
    end)
    if ok then
        return true, result
    end
    local ok_direct, direct_result = pcall(function()
        local fn = obj[method_name]
        if type(fn) == "function" then
            return fn(obj, unpack_args(args))
        end
        return nil
    end)
    if ok_direct then
        return true, direct_result
    end
    return false, result or direct_result
end

local function get_component_quiet(game_obj, type_name)
    local rt = get_runtime_type(type_name)
    if not rt then
        return nil
    end
    local ok, component = probe_call(game_obj, "getComponent(System.Type)", rt)
    if ok and component then
        return component
    end
    ok, component = pcall(function()
        return game_obj:getComponent(rt)
    end)
    if ok and component then
        return component
    end
    return nil
end

local function get_game_object_quiet(obj)
    if not obj then
        return nil
    end
    local ok, game_obj = probe_call(obj, "get_GameObject")
    if ok and game_obj then
        return game_obj
    end
    ok, game_obj = pcall(function()
        return obj:get_field("_GameObject")
    end)
    if ok and game_obj then
        return game_obj
    end
    return nil
end

local function get_game_object_name_quiet(game_obj)
    if not game_obj then
        return ""
    end
    local ok, name = probe_call(game_obj, "get_Name")
    if ok and name then
        return tostring(name)
    end
    ok, name = probe_call(game_obj, "get_name")
    if ok and name then
        return tostring(name)
    end
    return ""
end

local function summarize_object_for_trace(obj)
    local game_obj = get_game_object_quiet(obj) or obj
    return {
        object = tostring(obj),
        game_object = tostring(game_obj),
        name = get_game_object_name_quiet(game_obj),
        has_motion = get_component_quiet(game_obj, "via.motion.Motion") ~= nil,
        has_child_secondary = get_component_quiet(game_obj, "via.motion.ChildSecondary") ~= nil,
        has_custom_skeleton = get_component_quiet(game_obj, "via.motion.CustomSkeleton") ~= nil,
        has_edit_region = get_component_quiet(game_obj, "app.CharacterEditRegion") ~= nil,
        has_edit_region_root = get_component_quiet(game_obj, "app.CharacterEditRegionRoot") ~= nil
    }
end

local function probe_character_edit_root(root, label, bind_part_name)
    local report = {
        label = tostring(label or "root"),
        object = tostring(root),
        face_part_ok = false,
        bind_part_name = tostring(bind_part_name or ""),
        bind_part_ok = false,
        parts = {}
    }
    if not root then
        report.error = "no CharacterEditRegionRoot"
        return report
    end
    for _, spec in ipairs(CHARACTER_EDIT_HASHES) do
        local entry = { hash = spec.hash, ok = false }
        local ok_part, part = probe_call(root, "getPartsObject", spec.hash)
        if ok_part and part then
            entry.ok = true
            entry.part = summarize_object_for_trace(part)
        else
            entry.error = trim_text(part, 180)
        end
        report.parts[spec.name] = entry
        if spec.name == "Face" and entry.ok then
            report.face_part_ok = true
        end
        if spec.name == bind_part_name and entry.ok then
            report.bind_part_ok = true
        end
    end
    return report
end

local function probe_edit_region_source(obj, label, bind_part_name)
    local game_obj = get_game_object_quiet(obj) or obj
    local source = {
        label = tostring(label or ""),
        object = tostring(obj),
        game_object = tostring(game_obj),
        name = get_game_object_name_quiet(game_obj),
        components = {},
        roots = {},
        face_part_ok = false,
        bind_part_name = tostring(bind_part_name or ""),
        bind_part_ok = false
    }
    if not game_obj then
        source.error = "no game object"
        return source
    end
    local root_component = get_component_quiet(game_obj, "app.CharacterEditRegionRoot")
    source.components.CharacterEditRegionRoot = root_component ~= nil
    if root_component then
        local root_report = probe_character_edit_root(root_component, "component:CharacterEditRegionRoot", bind_part_name)
        table.insert(source.roots, root_report)
        source.face_part_ok = source.face_part_ok or root_report.face_part_ok
        source.bind_part_ok = source.bind_part_ok or root_report.bind_part_ok
    end
    local region = get_component_quiet(game_obj, "app.CharacterEditRegion")
    source.components.CharacterEditRegion = region ~= nil
    if region then
        local ok_root, region_root = probe_call(region, "getRoot")
        source.region_getRoot_ok = ok_root and region_root ~= nil
        if ok_root and region_root then
            local root_report = probe_character_edit_root(region_root, "component:CharacterEditRegion.getRoot", bind_part_name)
            table.insert(source.roots, root_report)
            source.face_part_ok = source.face_part_ok or root_report.face_part_ok
            source.bind_part_ok = source.bind_part_ok or root_report.bind_part_ok
        else
            source.region_getRoot_error = trim_text(region_root, 180)
        end
    end
    return source
end

 
local function build_edit_region_trace(character, root_obj, candidates, bone_data, target)
    if config.edit_region_trace == false then
        return nil
    end
    local bind_part = 1
    if type(bone_data) == "table" and tonumber(bone_data.BindPart) then
        bind_part = tonumber(bone_data.BindPart)
    end
    local bind_part_name = FACE_BIND_PART_NAMES[bind_part] or tostring(bind_part)
    local trace = {
        enabled = true,
        auto_apply_face_mapping = config.auto_apply_face_mapping ~= false,
        private_face_mode = use_private_face_mode(target),
        bind_part = bind_part,
        bind_part_name = bind_part_name,
        root = probe_edit_region_source(root_obj, "root_game_object", bind_part_name),
        character_parts = {},
        candidates = {}
    }
    for index = 0, 5 do
        local entry = { index = index, ok = false }
        local ok_part, part = probe_call(character, "getParts", index)
        if ok_part and part then
            entry.ok = true
            entry.part = summarize_object_for_trace(part)
            entry.edit_region = probe_edit_region_source(part, "character.getParts(" .. tostring(index) .. ")", bind_part_name)
        else
            entry.error = trim_text(part, 180)
        end
        table.insert(trace.character_parts, entry)
    end
    local limit = tonumber(config.edit_region_trace_candidates) or 8
    for index, candidate in ipairs(candidates or {}) do
        if index > limit then
            break
        end
        table.insert(trace.candidates, probe_edit_region_source(candidate.obj, tostring(candidate.label), bind_part_name))
    end
    return trace
end
