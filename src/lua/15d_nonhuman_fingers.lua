-- =============================================================================
-- 四指原生角色的小指跟随：实例私有约束层，等待目标骨架提交后安装一次
-- =============================================================================
-- 不改原生层，不保留 Joint/Layer 包装，不添加帧回调；只进入普通 NPC 路径。
local nonhuman_fingers = (function()
    local helper = {}
    local destination = "BoneSystemForNPC/Constraints/WyverianPinky_DSG.jcns"
    local max_checks, retry_interval, max_layers = 12, 0.05, 16
    local metrics = { prepared = 0, applied = 0, skipped = 0, errors = 0, checks = 0, recent = {} }
    performance.nonhuman_fingers = metrics

    local function normalized(path)
        return tostring(path or ""):gsub("\\", "/"):lower():gsub("^@", ""):gsub("%.%d+$", "")
    end

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

    local function path_of(object, method)
        return normalized(read(read(object, method), "get_ResourcePath"))
    end

    local function record(entry, status, detail)
        entry.nonhuman_fingers_pending = nil
        entry.nonhuman_fingers = { status = status, detail = tostring(detail or "") }
        metrics.recent[#metrics.recent + 1] = {
            generation = scene_generation, npc_id = entry.npc_id, status = status,
            detail = tostring(detail or "")
        }
        if #metrics.recent > 16 then table.remove(metrics.recent, 1) end
        if status == "applied" then metrics.applied = metrics.applied + 1
        elseif status == "error" then metrics.errors = metrics.errors + 1
        else metrics.skipped = metrics.skipped + 1 end
        bs_log("[NonhumanFingers] " .. tostring(entry.npc_id) .. " " .. status .. " " .. tostring(detail))
    end

    -- 验证完整父链和有效绑定旋转；原生约束提取 Ring 的相对动作并保留 Pinky 自身初始姿态。
    function helper.prepare(candidate, state, entry, bone_data)
        if not state or not entry or entry.nonhuman_fingers or not config.enabled
            or config.mode ~= "api_fix_bone" or config.auto_apply_bone == false
            or scene_transition.active or normal_runtime_menu_suspended
            or entry.scene_generation ~= scene_generation or bone_data.FixBone == false then return nil end
        local family = nonhuman_family.classify(candidate, state, entry)
        if not family.ik_asset then return nil end
        if not family.fingers_ok then
            record(entry, "skipped", "native four-finger topology not verified")
            return nil
        end
        local desired = resource_path_from_bone_data(bone_data)
        if not desired or normalized(desired) == normalized(state.resource_path) then return nil end
        if not same_runtime_object(read(entry.character, "get_GameObject"), candidate.obj) then
            record(entry, "skipped", "candidate is not the registered NPC root")
            return nil
        end
        local component = get_component(candidate.obj, "via.motion.JointConstraints")
        local root, motion, skeleton, constraints = address(candidate.obj), address(state.motion),
            address(state.custom_skeleton), address(component)
        if not root or not motion or not skeleton or not constraints then
            record(entry, "skipped", "native component identity unavailable")
            return nil
        end
        if not same_runtime_object(read(component, "get_GameObject"), candidate.obj) then
            record(entry, "skipped", "constraints owner mismatch")
            return nil
        end
        metrics.prepared = metrics.prepared + 1
        return { root = root, motion = motion, skeleton = skeleton, constraints = constraints,
            desired = normalized(desired), profile = family.profile,
            generation = scene_generation, dictionary = dictionary_generation, checks = 0, next_check = 0 }
    end

    function helper.finish(plan, bone_ok, entry)
        if not plan or not bone_ok then return end
        entry.nonhuman_fingers_pending = plan
        entry.nonhuman_fingers = { status = "pending", detail = "waiting for target finger chain" }
    end

    -- 只验证静止基准，不限制当前手势。目标小指各自的位置、长度始终由原模型保留。
    local function valid_bind_rotation(rotation)
        if not rotation then return false end
        local ok, result = pcall(function()
            local x, y, z, w = rotation.x, rotation.y, rotation.z, rotation.w
            if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" or type(w) ~= "number" then return false end
            local norm = x * x + y * y + z * z + w * w
            -- NaN/Inf/退化四元数均不能进入原生相对旋转计算；不限制正常的初始张开角度。
            return norm == norm and math.abs(norm - 1) < 0.001
        end)
        return ok and result == true
    end

    local function finger_chain(root)
        local transform = get_transform(root)
        if not transform then return false, "missing transform" end
        for _, side in ipairs({ "L", "R" }) do
            local palm = read(transform, "getJointByName", side .. "_Palm")
            if not palm or read(palm, "get_Valid") ~= true then return false, "missing palm " .. side end
            for _, finger in ipairs({ "RingF", "PinkyF" }) do
                local previous = side .. "_Palm"
                for index = 1, 3 do
                    local name = side .. "_" .. finger .. index
                    local joint = read(transform, "getJointByName", name)
                    if not joint or read(joint, "get_Valid") ~= true then return false, "missing joint " .. name end
                    if read(read(joint, "get_Parent"), "get_Name") ~= previous then
                        return false, "unexpected parent " .. name
                    end
                    if not valid_bind_rotation(read(joint, "get_BaseLocalRotation")) then
                        return false, "invalid base rotation " .. name
                    end
                    previous = name
                end
            end
        end
        return true
    end

    -- 保留现有层和重复安装检查；新建层的引用、配置和尾槽回滚全部在原生调用内完成。
    local function append_layer(component, plan)
        local count = read(component, "getLayerCount")
        assert(type(count) == "number" and count >= 1 and count < max_layers and count % 1 == 0, "invalid layer count")
        for index = 0, count - 1 do
            local layer = assert(read(component, "getLayer", index), "original layer unavailable")
            local path = path_of(layer, "get_JointConstraintsAsset")
            if path == normalized(destination) then return "applied", "already attached; no additional layer" end
        end
        local result = nonhuman_resources("fingers", plan.root, plan.constraints, count)
        if result == 2 then return "pending", "native Scene lock busy; throttled retry" end
        assert(result == 0, "native constraint resource guard=" .. tostring(result))
        return "applied", "native constraint layer attached; index=" .. count
    end

    function helper.update(entry, now)
        local plan = entry.nonhuman_fingers_pending
        if not nonhuman_retry.ready(plan, now) then return end
        plan.checks = plan.checks + 1
        plan.next_check = now + retry_interval
        metrics.checks = metrics.checks + 1
        local ok, status, detail = pcall(function()
            if not config.enabled or config.mode ~= "api_fix_bone" or config.auto_apply_bone == false
                or scene_transition.active or normal_runtime_menu_suspended or entry.player_character_rejected
                or scene_generation ~= plan.generation or entry.scene_generation ~= plan.generation
                or dictionary_generation ~= plan.dictionary or registered[tostring(entry.character)] ~= entry then
                return "skipped", "lifecycle/configuration changed"
            end
            if now - entry.last_seen > (tonumber(config.readiness_recent_seen_window) or 0.5) then
                return "pending", "NPC no longer recently updated"
            end
            local root = read(entry.character, "get_GameObject")
            if not is_valid_managed_object(root) or address(root) ~= plan.root then return "skipped", "root identity changed" end
            local motion = get_component(root, "via.motion.Motion")
            local skeleton = get_component(root, "via.motion.CustomSkeleton")
            local component = get_component(root, "via.motion.JointConstraints")
            if address(motion) ~= plan.motion or address(skeleton) ~= plan.skeleton
                or address(component) ~= plan.constraints
                or not same_runtime_object(read(motion, "get_GameObject"), root)
                or not same_runtime_object(read(skeleton, "get_GameObject"), root)
                or not same_runtime_object(read(component, "get_GameObject"), root) then
                return "skipped", "component identity/owner changed"
            end
            if path_of(skeleton, "get_SkeletonResourceHandle") ~= plan.desired then
                return "skipped", "target skeleton changed"
            end
            if read(motion, "get_JointsConstructed") ~= true then return "pending", "joints not constructed" end
            local valid, reason = finger_chain(root)
            if not valid then return "pending", reason end
            local status, detail = append_layer(component, plan)
            return status, detail .. "; expression_lod=" .. tostring(read(motion, "get_ExpressionLOD"))
        end)
        if not ok then detail, status = tostring(status), "error" end
        if status == "pending" then
            nonhuman_retry.defer(plan, entry.nonhuman_fingers, detail, now, max_checks, plan.checks)
            return
        end
        record(entry, status, detail)
    end

    return helper
end)()
