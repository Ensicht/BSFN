-- =============================================================================
-- 非人类适配就绪等待：复用普通注册表、运行时钟和暂停入口
-- =============================================================================
-- 短时就绪检查耗尽后降频，不把尚未就绪记作永久失败；不保存原生对象。
-- 加载时旧 entry 随正常场景隔离丢弃，菜单期间时钟冻结，成功后不再进入。
local nonhuman_retry = (function()
    local helper = {}

    function helper.ready(plan, now)
        return plan ~= nil and config.enabled and not scene_transition.active
            and not normal_runtime_menu_suspended and now >= plan.next_check
    end

    -- 使用原有检查间隔作为低频下限；配置异常时也不能形成逐帧轮询。
    local function slow_interval()
        local value = tonumber(config.inspect_interval) or 1.0
        if value ~= value or value == math.huge or value == -math.huge then value = 1.0 end
        return math.max(0.5, value)
    end

    function helper.defer(plan, state, detail, now, limit, checks)
        local slow = checks >= limit
        plan.next_check = now + (slow and slow_interval() or 0.05)
        state.status, state.detail = "pending", tostring(detail or "not ready")
        state.checks, state.retry_mode = plan.checks, slow and "throttled" or "initial"
    end
    return helper
end)()
