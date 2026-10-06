-- =============================================================================
-- 普通 NPC 注册与更新
-- =============================================================================
-- 保留稳定版 Hook 和 UpdateMotion 路径；完成应用后命中 apply_once 快速路径。

-- 原生更新只登记或刷新 last_seen，不在此 Hook 内执行资源替换。
local function register_character(character, source)
    if not character or scene_transition.active then
        return
    end
    local key = tostring(character)
    if normal_player_rejections[key] then
        return
    end
    local entry = registered[key]
    local now = normal_runtime_clock()
    if not entry or entry.scene_generation ~= scene_generation then
        stats.seen = stats.seen + 1
        registered[key] = {
            character = character,
            source = source or "unknown",
            first_seen = now,
            last_seen = now,
            last_inspect = -9999,
            scene_generation = scene_generation,
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
            pending_target = nil,
            pending_body_id = nil,
            pending_bone_body_id = nil,
            pending_match_source = nil,
            pending_dictionary_generation = nil,
            pending_key = nil,
            readiness_signature = nil,
            readiness_stable_frames = 0,
            readiness_burst_checks = 0,
            readiness_holder_address = nil,
            next_readiness_probe = nil,
            readiness_status = "not started",
            player_character_rejected = false,
            applied = false
        }
    else
        entry.character = character
        entry.source = source or entry.source
        entry.last_seen = now
    end
end

local function install_hook(type_name, method_names, state_key)
    local td = safe_sdk_type(type_name)
    if not td then
        hook_state[state_key] = type_name .. " not found"
        return
    end
    for _, method_name in ipairs(method_names) do
        local ok_method, method = pcall(function()
            return td:get_method(method_name)
        end)
        if ok_method and method then
            local ok_hook, err = pcall(function()
                sdk.hook(method, function(args)
                    if scene_transition.active then
                        performance.scene_registration_suppressed = performance.scene_registration_suppressed + 1
                        return
                    end
                    local ok_obj, character = pcall(function()
                        return sdk.to_managed_object(args[2])
                    end)
                    if ok_obj and character and not normal_runtime_menu_suspended then
                        register_character(character, type_name .. "." .. method_name)
                    end
                end)
            end)
            if ok_hook then
                hook_state[state_key] = "installed " .. type_name .. "." .. method_name
                record_event("hook", hook_state[state_key])
                write_report(true)
                return
            end
            hook_state[state_key] = tostring(err)
        end
    end
    if hook_state[state_key] == "not attempted" then
        hook_state[state_key] = "no hookable method on " .. type_name
    end
end

local function apply_registered_armor_variants(now)
    if config.auto_sync_armor_variant == false then
        return
    end
    local interval = tonumber(config.armor_variant_reapply_interval) or 0.7
    if interval <= 0 or now - last_armor_variant_sync_time < interval then
        return
    end
    last_armor_variant_sync_time = now
    local recent_window = tonumber(config.armor_variant_recent_seen_window) or 1.0
    for key, entry in pairs(registered) do
        if not entry.character or not is_valid_managed_object(entry.character) or now - entry.last_seen > recent_window then
            entry.armor_variant_status = "skipped stale registered entry"
            record_event("stale registered entry", tostring(key))
        elseif entry.applied and entry.character and entry.target then
            local ok, status = apply_armor_variant_with_api(entry.character, entry.target, entry.bone_body_id or entry.body_id)
            entry.armor_variant_ok = ok
            entry.armor_variant_status = status
        end
    end
end

-- 就绪样本不能替代最终校验：重新取当前对象，再核对相同的骨骼签名。
local function apply_ready_registered_entry(entry, ready_state)
    local pending_target = entry.pending_target
    local pending_body_id = entry.pending_body_id
    local pending_bone_body_id = entry.pending_bone_body_id
    local expected_signature = ready_state and ready_state.signature or entry.readiness_signature
    if not expected_signature then
        clear_entry_readiness(entry, "missing final readiness signature", false)
        entry.next_readiness_probe = normal_runtime_clock() + (tonumber(config.readiness_retry_interval) or 0.1)
        return false
    end

    -- Final application never trusts the wrappers used by the preceding readiness frames.
    -- Reacquire the character root, outfit carrier, candidate, Motion, CustomSkeleton and
    -- holder, then require an exact signature match inside inspect_character().
    local root_ok, root_obj = safe_call(entry.character, "get_GameObject")
    if not root_ok or not root_obj then
        performance.game_object_failures = performance.game_object_failures + 1
        clear_entry_readiness(entry, "final root GameObject unavailable", false)
        entry.next_readiness_probe = normal_runtime_clock() + (tonumber(config.readiness_retry_interval) or 0.1)
        return false
    end
    clear_fallback_cache(entry)
    if entry.session_unmatched_key then
        session_unmatched_cache[entry.session_unmatched_key] = nil
    end
    entry.session_unmatched_key = nil
    entry.session_unmatched_generation = nil
    local resolution, match_status = resolve_target(entry.character, root_obj, entry)
    entry.match_status = match_status or (resolution and resolution.match_source) or "unmatched"
    if not resolution then
        clear_entry_readiness(entry, "final target resolution failed: " .. tostring(entry.match_status), true)
        return false
    end
    local target = resolution.target
    local current_body_id = resolution.body_id or (target and target.body_id)
    local current_bone_body_id = target and (target.bone_system_body_id or current_body_id or target.body_id) or nil
    if target ~= pending_target
        or tostring(current_body_id or "") ~= tostring(pending_body_id or "")
        or tostring(current_bone_body_id or "") ~= tostring(pending_bone_body_id or "") then
        performance.readiness_final_mismatches = performance.readiness_final_mismatches + 1
        clear_entry_readiness(entry, "target changed before final apply", true)
        return false
    end

    local ok, detail, matched_target, matched_body_id, matched_bone_body_id, armor_variant_status =
        inspect_character(entry.character, entry.source, resolution, entry, {
            root_obj = root_obj,
            expected_readiness_signature = expected_signature
        })
    if not ok then
        performance.readiness_final_mismatches = performance.readiness_final_mismatches + 1
        begin_entry_readiness(entry, resolution)
        clear_entry_readiness(entry, "final apply deferred: " .. tostring(detail), false)
        entry.next_readiness_probe = normal_runtime_clock() + (tonumber(config.readiness_retry_interval) or 0.1)
        return false
    end
    entry.applied = true
    entry.target = matched_target
    entry.resolved_target = matched_target
    entry.body_id = matched_body_id
    entry.bone_body_id = matched_bone_body_id
    entry.armor_variant_status = armor_variant_status
    clear_entry_readiness(entry, "applied", true)
    return true
end

-- 已应用目标和明确未命中目标均快速跳过；周期差分重同步默认关闭。
local function update_registered()
    local now = normal_runtime_clock()
    local inspect_interval = tonumber(config.inspect_interval) or 1.0
    local entry_ttl = tonumber(config.registered_entry_ttl) or 3.0
    for key, entry in pairs(registered) do
        if entry.scene_generation ~= scene_generation then
            record_event("stale_scene_generation", tostring(key))
            registered[key] = nil
        elseif entry.player_character_rejected then
            registered[key] = nil
        elseif not entry.character or not is_valid_managed_object(entry.character) or now - entry.last_seen > entry_ttl then
            record_event("stale_registered_entry", tostring(key))
            registered[key] = nil
        elseif config.enabled then
            if entry.nonhuman_ik_pending then nonhuman_ik.update(entry, now) end
            if entry.nonhuman_fingers_pending then nonhuman_fingers.update(entry, now) end
            if entry.nonhuman_forefoot_pending then nonhuman_forefoot.update(entry, now) end
            if entry.pending_target and config.auto_apply_bone ~= false then
                local ready_state = update_entry_readiness(entry, now)
                if ready_state then
                    apply_ready_registered_entry(entry, ready_state)
                end
            elseif now - entry.last_inspect >= inspect_interval then
                entry.last_inspect = now
                local same_generation = entry.dictionary_generation == dictionary_generation
                local session_cached = entry.session_unmatched_key
                    and entry.session_unmatched_generation == dictionary_generation
                    and session_unmatched_cache[entry.session_unmatched_key]
                if session_cached then
                    performance.session_unmatched_cache_hits = performance.session_unmatched_cache_hits + 1
                    entry.match_status = "unmatched_session_cache"
                elseif config.apply_once == true and entry.applied and entry.target and same_generation then
                    performance.apply_once_fast_skips = performance.apply_once_fast_skips + 1
                    entry.match_status = "apply_once_cached"
                else
                    local root_ok, root_obj = safe_call(entry.character, "get_GameObject")
                    if not root_ok or not root_obj then
                        performance.game_object_failures = performance.game_object_failures + 1
                        record_event("registered_game_object_failed", tostring(key))
                        registered[key] = nil
                    else
                        local resolution, match_status = resolve_target(entry.character, root_obj, entry)
                        entry.match_status = match_status or (resolution and resolution.match_source) or "unmatched"
                        if resolution and (config.apply_once ~= true or not entry.applied or resolution.cache_changed) then
                            if config.auto_apply_bone == false then
                                local ok, _, matched_target, matched_body_id, matched_bone_body_id, armor_variant_status =
                                    inspect_character(entry.character, entry.source, resolution, entry)
                                if ok then
                                    entry.applied = true
                                    entry.target = matched_target
                                    entry.resolved_target = matched_target
                                    entry.body_id = matched_body_id
                                    entry.bone_body_id = matched_bone_body_id
                                    entry.armor_variant_status = armor_variant_status
                                end
                            else
                                if begin_entry_readiness(entry, resolution) then
                                    local ready_state = update_entry_readiness(entry, now)
                                    if ready_state then
                                        apply_ready_registered_entry(entry, ready_state)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    apply_registered_armor_variants(now)
    write_report(false)
end
