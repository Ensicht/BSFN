-- =============================================================================
-- 托管调用与场景事件接入
-- =============================================================================
-- 不把 pcall 当作原生对象生命周期保证；调用前的场景和身份门禁由各入口负责。

local function safe_call(obj, method_name, ...)
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
    stats.last_error = tostring(result)
    return false, result
end

local function direct_call(obj, method_name, ...)
    if not obj or type(method_name) ~= "string" then
        return false, nil
    end
    local args = { ... }
    local ok, result = pcall(function()
        local fn = obj[method_name]
        if type(fn) == "function" then
            return fn(obj, unpack_args(args))
        end
        return nil
    end)
    if ok then
        return true, result
    end
    stats.last_error = tostring(result)
    return false, result
end

local function call_any(obj, method_name, ...)
    local ok, result = safe_call(obj, method_name, ...)
    if ok then
        return true, result
    end
    return direct_call(obj, method_name, ...)
end

local function safe_field(obj, field_name)
    if not obj or type(field_name) ~= "string" then
        return false, nil
    end
    local ok, result = pcall(function()
        return obj:get_field(field_name)
    end)
    if ok then
        return true, result
    end
    stats.last_error = tostring(result)
    return false, result
end

local function safe_sdk_type(type_name)
    if type_cache[type_name] ~= nil then
        return type_cache[type_name]
    end
    local ok, td = pcall(sdk.find_type_definition, type_name)
    if ok and td then
        type_cache[type_name] = td
        return td
    end
    type_cache[type_name] = false
    return nil
end

-- 保留已实测的加载、黑屏与淡入信号；不要用所有画面变黑事件替代场景生命周期。
local function install_scene_transition_hook()
    local td = safe_sdk_type("app.EnvironmentManager")
    if not td then
        hook_state.scene = "app.EnvironmentManager not found; SceneManager polling fallback active"
        return false
    end
    local method = nil
    local ok_method = pcall(function()
        method = td:get_method("evSceneLoadBefore()") or td:get_method("evSceneLoadBefore")
    end)
    if not ok_method or not method then
        hook_state.scene = "evSceneLoadBefore not found; SceneManager polling fallback active"
        return false
    end
    local ok_hook, err = pcall(function()
        sdk.hook(method, function()
            scene_transition.mark_start("app.EnvironmentManager.evSceneLoadBefore")
        end)
    end)
    if not ok_hook then
        hook_state.scene = tostring(err)
        return false
    end
    scene_transition_hook_installed = true
    local end_td = safe_sdk_type("app.PlayerManager")
    if end_td then
        for _, method_name in ipairs({
            "evSceneLoadEnd()",
            "evSceneLoadEnd_FastTravel()",
            "evSceneLoadEnd_SceneTransition()",
            "evSceneLoadEnd_ThroughJunction()"
        }) do
            local end_method_name = method_name
            local end_reason = "app.PlayerManager." .. end_method_name
            local end_method = nil
            pcall(function()
                end_method = end_td:get_method(end_method_name)
            end)
            if end_method then
                local ok_end = pcall(function()
                    sdk.hook(end_method, function()
                    end, function(retval)
                        scene_transition.mark_end(end_reason)
                        return retval
                    end)
                end)
                if ok_end then
                    scene_transition.end_hook_count = scene_transition.end_hook_count + 1
                end
            end
        end
    end
    local fade_hook_installed = false
    local fade_td = safe_sdk_type("app.CameraManager")
    local fade_method = nil
    if fade_td then
        pcall(function()
            fade_method = fade_td:get_method("onSceneLoadFadeIn()") or fade_td:get_method("onSceneLoadFadeIn")
        end)
    end
    if fade_method then
        fade_hook_installed = pcall(function()
            sdk.hook(fade_method, function()
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval)
                if scene_transition.active and scene_transition.requires_fade_in then
                    scene_transition.mark_end("app.CameraManager.onSceneLoadFadeIn", true)
                end
                return retval
            end)
        end)
        if fade_hook_installed then
            scene_transition.fade_in_end_hook_count = 1
        end
    end
    if fade_hook_installed then
        local fast_travel_td = safe_sdk_type("app.mcFastTravel")
        local setup_loading_method = nil
        if fast_travel_td then
            pcall(function()
                setup_loading_method = fast_travel_td:get_method("setupLoadingEvent")
            end)
        end
        if setup_loading_method then
            local ok_black_start = pcall(function()
                sdk.hook(setup_loading_method, function()
                    if not scene_transition.active then
                        scene_transition.mark_start("app.mcFastTravel.setupLoadingEvent", true)
                    end
                    return sdk.PreHookResult.CALL_ORIGINAL
                end, function(retval)
                    return retval
                end)
            end)
            if ok_black_start then
                scene_transition.black_screen_start_hook_count = 1
            end
        end
    end
    hook_state.scene = "installed app.EnvironmentManager.evSceneLoadBefore minimal quarantine trigger; PlayerManager load-end hooks=" .. tostring(scene_transition.end_hook_count)
        .. "; black-screen start hooks=" .. tostring(scene_transition.black_screen_start_hook_count)
        .. "; fade-in end hooks=" .. tostring(scene_transition.fade_in_end_hook_count)
        .. "; SceneManager fallback polling disabled"
    record_event("hook", hook_state.scene)
    return true
end

local function get_runtime_type(type_name)
    local td = safe_sdk_type(type_name)
    if td then
        local ok_rt, rt = pcall(function()
            return td:get_runtime_type()
        end)
        if ok_rt and rt then
            return rt
        end
    end
    if sdk and sdk.typeof then
        local ok_typeof, rt = pcall(sdk.typeof, type_name)
        if ok_typeof and rt then
            return rt
        end
    end
    return nil
end

local function is_valid_managed_object(obj)
    if not obj then
        return false
    end
    if sdk and sdk.is_managed_object then
        local ok, result = pcall(sdk.is_managed_object, obj)
        return ok and result == true
    end
    return true
end
local function get_game_object(obj)
    if not obj then
        return nil
    end
    local ok, game_obj = safe_call(obj, "get_GameObject")
    if ok and game_obj then
        return game_obj
    end
    ok, game_obj = safe_field(obj, "_GameObject")
    if ok and game_obj then
        return game_obj
    end
    ok, game_obj = safe_call(obj, "get_GameObject(System.Boolean)", true)
    if ok and game_obj then
        return game_obj
    end
    return nil
end

local function get_transform(game_obj)
    if not game_obj then
        return nil
    end
    local ok, transform = safe_call(game_obj, "get_Transform")
    if ok and transform then
        return transform
    end
    ok, transform = safe_call(game_obj, "get_transform")
    if ok and transform then
        return transform
    end
    return nil
end

local function get_game_object_name(game_obj)
    if not game_obj then
        return ""
    end
    local ok, name = safe_call(game_obj, "get_Name")
    if ok and name then
        return tostring(name)
    end
    ok, name = safe_call(game_obj, "get_name")
    if ok and name then
        return tostring(name)
    end
    return ""
end

local function lower_contains(text, needle)
    if not text or not needle or needle == "" then
        return false
    end
    return string.find(string.lower(tostring(text)), string.lower(tostring(needle)), 1, true) ~= nil
end
