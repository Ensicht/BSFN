-- =============================================================================
-- 启动注册与对外诊断接口
-- =============================================================================
-- 所有 Hook 注册顺序保持稳定版一致；不新增全场景扫描或结算动画接管。

load_config()
record_event("loaded", "outfit target loader active; mode=" .. tostring(config.mode) .. "; targets=" .. tostring(#get_targets()))
install_scene_transition_hook()
install_hook("app.NpcCharacter", { "update", "doStartBegin", "doStartEnd" }, "npc")
install_event_model_npc_hook()

if re and re.on_application_entry then
    if scene_transition_hook_installed then
        re.on_application_entry("UpdateMotion", function()
            scene_transition.initialize_context()
            if scene_transition.update() then
                return
            end
            if not update_normal_runtime_menu_pause() then
                update_registered()
            end
        end)
        hook_state.update = "installed UpdateMotion with deferred scene quarantine release, constructed-skeleton readiness, and GUI050000 quest-list pause"
    else
        re.on_application_entry("UpdateMotion", function()
            update_scene_generation_fallback()
            if scene_transition.update() then
                return
            end
            if not update_normal_runtime_menu_pause() then
                update_registered()
            end
        end)
        hook_state.update = "installed UpdateMotion with one-second SceneManager fallback, constructed-skeleton readiness, and GUI050000 quest-list pause"
    end
else
    hook_state.update = "re.on_application_entry unavailable"
    record_event("error", hook_state.update)
end

if re and re.on_draw_ui then
    re.on_draw_ui(function()
        local ok, err = pcall(draw_ui)
        if not ok then
            stats.last_error = tostring(err)
        end
    end)
end

_G.BoneSystemForNPC = {
    version = VERSION,
    stats = stats,
    performance = performance,
    diagnostics = diagnostics,
    hook_state = hook_state,
    inspect_character = inspect_character,
    resolve_target = resolve_target,
    process_event_model_setupper = process_event_model_setupper,
    load_config = load_config,
    scan_bone_system_configs = scan_bone_system_configs,
    get_scene_generation = function() return scene_generation end,
    is_scene_transition_active = function() return scene_transition.active end
}
write_report(true)
bs_log("loaded")
