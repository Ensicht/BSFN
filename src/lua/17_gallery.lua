-- =============================================================================
-- 艺术馆完成模型入口
-- =============================================================================
-- 仅在原生模型装配完成回调处理，使用独立上下文；不建立普通场景轮询会话。

local function probe_field_quiet(obj, field_name)
    if not obj or type(field_name) ~= "string" then
        return false, nil
    end
    local ok, result = pcall(function()
        return obj:get_field(field_name)
    end)
    return ok, result
end

local EVENT_GAME_OBJECT_METHODS = {
    "get_GameObject",
    "get_GameObjectRefValue",
    "get_BodyGameObject",
    "get_FaceGameObject",
    "get_TargetGameObject",
    "get_OwnerGameObject",
    "get_ValidGameObject",
    "get_Value"
}

local function accept_event_game_object(value)
    if not value then
        return nil, nil
    end
    if get_game_object_name_quiet(value) ~= "" then
        return value, "self"
    end
    local nested = get_game_object_quiet(value)
    if nested and get_game_object_name_quiet(nested) ~= "" then
        return nested, "get_GameObject"
    end
    return nil, nil
end

local function resolve_event_game_object(value)
    if not value then
        return nil, "nil"
    end
    local direct, direct_route = accept_event_game_object(value)
    if direct then
        return direct, direct_route
    end
    for _, method_name in ipairs(EVENT_GAME_OBJECT_METHODS) do
        local ok, candidate = probe_call(value, method_name)
        if ok and candidate and candidate ~= value then
            local game_obj = accept_event_game_object(candidate)
            if game_obj then
                return game_obj, method_name
            end
        end
    end
    for _, field_name in ipairs({ "_GameObject", "GameObject", "_Value", "Value" }) do
        local ok, candidate = probe_field_quiet(value, field_name)
        if ok and candidate and candidate ~= value then
            local game_obj = accept_event_game_object(candidate)
            if game_obj then
                return game_obj, field_name
            end
        end
    end
    return nil, "unresolved"
end

-- 使用装配器最终 _PlEquip，而不是可能尚未装配或已经被替换的普通角色装备引用。
local function build_event_model_context(setupper)
    local context = {
        owner = get_game_object_quiet(setupper),
        npc_id = nil,
        npc_raw = "",
        model_parts_data = nil,
        pl_equip = nil,
        pl_equip_objects = {},
        body_object = nil,
        body_name = "",
        body_id = nil,
        body_source = "none",
        extra_roots = {},
        reference_routes = {}
    }
    local object_seen = {}
    local function add_object(label, obj, route)
        if not obj then
            return
        end
        local key = tostring(obj)
        context.reference_routes[label] = tostring(route or "")
        if not object_seen[key] and obj ~= context.owner then
            object_seen[key] = true
            table.insert(context.extra_roots, obj)
        end
    end

    local ok_npc, npc_value = probe_field_quiet(setupper, "_NpcID")
    if ok_npc and npc_value ~= nil then
        context.npc_raw = tostring(npc_value)
        context.npc_id = npc_id_from_serializable(npc_value)
    end
    context.npc_id = context.npc_id or read_npc_id(setupper, context.owner)

    local ok_equip, pl_equip = probe_field_quiet(setupper, "_PlEquip")
    if ok_equip and pl_equip then
        context.pl_equip = pl_equip
        for part_index = 0, 5 do
            local ok_part, part = pcall(function()
                return pl_equip[part_index]
            end)
            if ok_part and part then
                local game_obj, route = resolve_event_game_object(part)
                context.pl_equip_objects[tostring(part_index)] = {
                    raw = trim_text(part, 180),
                    object = tostring(game_obj),
                    name = get_game_object_name_quiet(game_obj),
                    route = tostring(route or "")
                }
                add_object("pl_equip_" .. tostring(part_index), game_obj,
                    "_PlEquip[" .. tostring(part_index) .. "]:" .. tostring(route or ""))
                if part_index == 1 and game_obj then
                    context.body_object = game_obj
                    context.body_source = "event_model_pl_equip"
                end
            end
        end
    end

    if not context.body_object then
        local ok_parts, model_parts_data = probe_field_quiet(setupper, "_ModelPartsData")
        if ok_parts then
            context.model_parts_data = model_parts_data
        end
        if model_parts_data then
            local ok_ref, reference = probe_field_quiet(model_parts_data, "_BodyTarget")
            if ok_ref and reference then
                local game_obj, route = resolve_event_game_object(reference)
                add_object("body", game_obj, "_BodyTarget:" .. tostring(route or ""))
                if game_obj then
                    context.body_object = game_obj
                    context.body_source = "event_model_body_target"
                end
            end
        end
    end

    if context.body_object then
        context.body_name = get_game_object_name_quiet(context.body_object)
        context.body_id = body_id_from_object_name(context.body_name)
    end
    context.chest_state = {
        chest_object = context.body_object,
        chest_name = context.body_name,
        chest_body_id = context.body_id,
        source = context.body_source,
        cache_route = "event_model"
    }
    return context
end

local function new_event_cache_entry()
    return {
        dictionary_generation = 0,
        npc_id = nil,
        chest_object = nil,
        chest_name = "",
        chest_body_id = nil,
        outfit_source = "none",
        fallback_object = nil,
        fallback_name = "",
        fallback_body_id = nil,
        fallback_source = nil,
        resolved_target = nil,
        session_unmatched_key = nil,
        session_unmatched_generation = nil,
        unmatched_attempts = 0,
        applied = false
    }
end

local function remember_event_model_setup(item)
    table.insert(diagnostics.event_model_setups, item)
    while #diagnostics.event_model_setups > 16 do
        table.remove(diagnostics.event_model_setups, 1)
    end
end

-- 单次已完成事件使用独立缓存，不能登记进普通 registered 或污染普通未命中缓存。
local function process_event_model_setupper(setupper)
    local context = build_event_model_context(setupper)
    local diagnostic = {
        time = os.clock(),
        setupper = tostring(setupper),
        owner = tostring(context.owner),
        owner_name = get_game_object_name_quiet(context.owner),
        npc_id = tostring(context.npc_id or ""),
        npc_raw = trim_text(context.npc_raw, 180),
        model_parts_data = tostring(context.model_parts_data),
        pl_equip = tostring(context.pl_equip),
        pl_equip_objects = context.pl_equip_objects,
        body_object = tostring(context.body_object),
        body_name = tostring(context.body_name or ""),
        body_id = tostring(context.body_id or ""),
        body_source = tostring(context.body_source or ""),
        reference_routes = context.reference_routes,
        status = "started",
        ok = false
    }
    if not context.owner then
        diagnostic.status = "no EventModelSetupper owner"
        performance.event_model_errors = performance.event_model_errors + 1
        remember_event_model_setup(diagnostic)
        write_report(false)
        return false, diagnostic.status
    end

    local cache_entry = new_event_cache_entry()
    local resolution, match_status = resolve_target(setupper, context.owner, cache_entry, {
        npc_id = context.npc_id,
        chest_state = context.chest_state,
        extra_roots = context.extra_roots,
        disable_session_cache = true
    })
    diagnostic.match_status = tostring(match_status or (resolution and resolution.match_source) or "unmatched")
    if not resolution then
        diagnostic.status = diagnostic.match_status
        performance.event_model_unmatched = performance.event_model_unmatched + 1
        remember_event_model_setup(diagnostic)
        record_event("event_model_unmatched", diagnostic.status .. " npc_id=" .. diagnostic.npc_id)
        write_report(false)
        return false, diagnostic.status
    end

    diagnostic.target = tostring(resolution.target and (resolution.target.display_name or resolution.target.npc_id) or "")
    diagnostic.resolved_body_id = tostring(resolution.body_id or "")
    performance.event_model_apply_attempts = performance.event_model_apply_attempts + 1
    local ok, detail, _, _, _, armor_variant_status, armor_variant_ok = inspect_character(
        setupper,
        "app.EventModelSetupper.setupModelPartsNpc",
        resolution,
        cache_entry,
        {
            root_obj = context.owner,
            extra_roots = context.extra_roots,
            defer_report = true
        }
    )
    diagnostic.ok = ok == true
    diagnostic.status = tostring(detail or "")
    diagnostic.armor_variant_status = tostring(armor_variant_status or "")
    diagnostic.armor_variant_ok = armor_variant_ok == true
    if ok then
        performance.event_model_apply_ok = performance.event_model_apply_ok + 1
    else
        performance.event_model_errors = performance.event_model_errors + 1
    end
    if armor_variant_ok then
        performance.event_model_variant_ok = performance.event_model_variant_ok + 1
    end
    remember_event_model_setup(diagnostic)
    record_event(ok and "event_model_stage_ok" or "event_model_stage_failed", diagnostic.status)
    write_report(false)
    return ok, diagnostic.status
end

local function event_setup_completed(retval)
    if not sdk or type(sdk.to_int64) ~= "function" then
        return false, "sdk.to_int64 unavailable"
    end
    local ok, complete, raw = pcall(function()
        local value = sdk.to_int64(retval)
        return (value & 1) ~= 0, tostring(value)
    end)
    if not ok then
        return false, tostring(complete)
    end
    return complete == true, tostring(raw or "")
end

-- pre/post 通过线程本地 Hook Storage 配对，过渡期两端均提前退出。
local function install_event_model_npc_hook()
    if not thread or type(thread.get_hook_storage) ~= "function" then
        hook_state.event_model_npc = "thread.get_hook_storage unavailable"
        return false
    end
    local type_name = "app.EventModelSetupper"
    local td = safe_sdk_type(type_name)
    if not td then
        hook_state.event_model_npc = type_name .. " not found"
        return false
    end
    local method = nil
    local ok_method = pcall(function()
        method = td:get_method("setupModelPartsNpc") or td:get_method("setupModelPartsNpc()")
    end)
    if not ok_method or not method then
        hook_state.event_model_npc = "no hookable method app.EventModelSetupper.setupModelPartsNpc"
        return false
    end
    local storage_key = "bsfn_setup_model_parts_npc_this"
    local suppressed_storage_key = "bsfn_setup_model_parts_npc_suppressed"
    local ok_hook, err = pcall(function()
        sdk.hook(method, function(args)
            local ok_storage, storage = pcall(thread.get_hook_storage)
            if not ok_storage or not storage then
                return
            end
            storage[storage_key] = nil
            storage[suppressed_storage_key] = nil
            if scene_transition.active then
                storage[suppressed_storage_key] = true
                performance.scene_event_model_suppressed = performance.scene_event_model_suppressed + 1
                return
            end
            local ok_obj, setupper = pcall(function()
                return sdk.to_managed_object(args[2])
            end)
            if ok_obj and setupper then
                storage[storage_key] = setupper
            end
        end, function(retval)
            performance.event_model_hook_hits = performance.event_model_hook_hits + 1
            local ok_storage, storage = pcall(thread.get_hook_storage)
            local setupper = ok_storage and storage and storage[storage_key] or nil
            local suppressed = ok_storage and storage and storage[suppressed_storage_key] == true
            if storage then
                storage[storage_key] = nil
                storage[suppressed_storage_key] = nil
            end
            if suppressed or scene_transition.active then
                return retval
            end
            local completed, raw_result = event_setup_completed(retval)
            if not completed then
                performance.event_model_incomplete_skips = performance.event_model_incomplete_skips + 1
                return retval
            end
            if config.enabled == false then
                return retval
            end
            performance.event_model_completed_hits = performance.event_model_completed_hits + 1
            if not setupper then
                performance.event_model_errors = performance.event_model_errors + 1
                record_event("event_model_error", "completed setup without saved this; ret=" .. tostring(raw_result))
                write_report(false)
                return retval
            end
            local ok_process, process_error = pcall(process_event_model_setupper, setupper)
            if not ok_process then
                performance.event_model_errors = performance.event_model_errors + 1
                stats.last_error = tostring(process_error)
                record_event("event_model_error", tostring(process_error))
                write_report(false)
            end
            return retval
        end)
    end)
    if not ok_hook then
        hook_state.event_model_npc = tostring(err)
        return false
    end
    hook_state.event_model_npc = "installed app.EventModelSetupper.setupModelPartsNpc"
    record_event("hook", hook_state.event_model_npc)
    write_report(false)
    return true
end
