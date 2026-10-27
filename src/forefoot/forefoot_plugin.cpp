#include <windows.h>
#include <array>
#include <atomic>
#include <cstring>
#include <limits>
#include <reframework/API.h>
#include "forefoot_core.hpp"
#include "host_layout.hpp"
#include "host_resolver.hpp"
#include "resource_helper.hpp"
#include "constraint_reader.hpp"

namespace {
REFrameworkPluginInitializeParam host_copy{};
const REFrameworkPluginInitializeParam* host = nullptr;
using Setter = void (*)(void*, void*, const float*);
std::array<Setter, 3> setters{};
uintptr_t game_base = 0;
int host_state = 0;
host_resolver::Resolution resolved_host{};

struct Memory {
    bool range(uintptr_t p, size_t n, bool write) const {
        MEMORY_BASIC_INFORMATION info{};
        if (!p || !n || p > std::numeric_limits<uintptr_t>::max()-n ||
            !VirtualQuery(reinterpret_cast<void*>(p), &info, sizeof(info))) return false;
        if (info.State != MEM_COMMIT || (info.Protect & (PAGE_GUARD|PAGE_NOACCESS))) return false;
        const DWORD mode = info.Protect & 0xff;
        if (write && mode != PAGE_READWRITE && mode != PAGE_WRITECOPY &&
            mode != PAGE_EXECUTE_READWRITE && mode != PAGE_EXECUTE_WRITECOPY) return false;
        if (!write && mode == PAGE_EXECUTE) return false;
        const auto end = reinterpret_cast<uintptr_t>(info.BaseAddress) + info.RegionSize;
        return p <= end && n <= end-p;
    }
};

// 仅接收七个 Lua 5.4 整数，在现有末参数槽返回整数；无分配、Lua 回调或私有 VM 调用。
// 先检查整段栈与 CallInfo 容量，再解码；不接受 float、userdata 或指针字符串。
struct Arguments {
    std::array<uintptr_t, 7> values{};
    uintptr_t result = 0;
    bool parse(lua_State* state) {
        Memory m;
        const auto s = reinterpret_cast<uintptr_t>(state);
        if (!m.range(s, 0x28, false)) return false;
        const auto ci = forefoot::value<uintptr_t>(s, 0x20);
        if (!m.range(ci, 16, false)) return false;
        const auto begin = forefoot::value<uintptr_t>(ci);
        const auto top = forefoot::value<uintptr_t>(s, 0x10);
        const auto limit = forefoot::value<uintptr_t>(ci, 8);
        if (begin > top || top-begin != 16*8 || limit < top ||
            !m.range(begin, 16*8, true)) return false;
        for (size_t i = 0; i < values.size(); ++i) {
            const auto slot = begin+(i+1)*16;
            if (forefoot::value<uint8_t>(slot, 8) != 3) return false;
            const auto value = forefoot::value<int64_t>(slot);
            if (value < 0) return false;
            values[i] = static_cast<uintptr_t>(value);
        }
        if (values[0] != 0x42534638 || values[6] != 0) return false;
        result = top-16;
        return true;
    }
    int finish(int status) const {
        const int64_t answer = status;
        std::memcpy(reinterpret_cast<void*>(result), &answer, sizeof(answer));
        return 1;
    }
};

bool reject_host(const char* reason, uintptr_t detail = 0) {
    host_state = -1;
    if (host && host->functions && host->functions->log_error)
        host->functions->log_error("[BSFNForefoot] host validation refused: %s; detail=0x%llx",
                                  reason, static_cast<unsigned long long>(detail));
    return false;
}

// PE 只负责体系结构和边界，不以编译时间戳/整文件大小认定兼容性。
// 所有探测均限定在镜像节内，失败不调用原生代码，不靠试加锁验证布局。
struct ImageContract {
    const IMAGE_NT_HEADERS64* nt = nullptr;
    const IMAGE_SECTION_HEADER* sections = nullptr;
    bool read(const Memory& memory) {
        if (!memory.range(game_base, 4096, false)) return false;
        const auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(game_base);
        if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew < 0 || dos->e_lfanew > 3072) return false;
        nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(game_base + dos->e_lfanew);
        if (nt->Signature != IMAGE_NT_SIGNATURE || nt->FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64 ||
            nt->FileHeader.SizeOfOptionalHeader < sizeof(IMAGE_OPTIONAL_HEADER64) ||
            nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC ||
            !nt->FileHeader.NumberOfSections || nt->FileHeader.NumberOfSections > 96 ||
            nt->OptionalHeader.SizeOfHeaders < static_cast<size_t>(dos->e_lfanew) + sizeof(IMAGE_NT_HEADERS64) ||
            nt->OptionalHeader.SizeOfHeaders > nt->OptionalHeader.SizeOfImage ||
            game_base > std::numeric_limits<uintptr_t>::max() - nt->OptionalHeader.SizeOfImage) return false;
        const size_t offset = static_cast<size_t>(dos->e_lfanew) + offsetof(IMAGE_NT_HEADERS64, OptionalHeader) +
                              nt->FileHeader.SizeOfOptionalHeader;
        const size_t bytes = nt->FileHeader.NumberOfSections * sizeof(IMAGE_SECTION_HEADER);
        if (offset > nt->OptionalHeader.SizeOfHeaders || bytes > nt->OptionalHeader.SizeOfHeaders - offset ||
            !memory.range(game_base + offset, bytes, false)) return false;
        sections = reinterpret_cast<const IMAGE_SECTION_HEADER*>(game_base + offset);
        // 节区重叠/溢出不能为同一地址提供相互矛盾的权限证明。
        for (unsigned i = 0; i < nt->FileHeader.NumberOfSections; ++i) {
            const auto& s = sections[i];
            const size_t size = s.Misc.VirtualSize;
            if (s.VirtualAddress > nt->OptionalHeader.SizeOfImage ||
                size > nt->OptionalHeader.SizeOfImage - s.VirtualAddress) return false;
            for (unsigned j = 0; j < i; ++j)
                if (size && sections[j].Misc.VirtualSize && s.VirtualAddress <
                    static_cast<size_t>(sections[j].VirtualAddress) + sections[j].Misc.VirtualSize &&
                    sections[j].VirtualAddress < static_cast<size_t>(s.VirtualAddress) + size) return false;
        }
        return true;
    }
    bool range(const Memory& memory, uintptr_t rva, size_t size, bool code) const {
        if (!size || rva > nt->OptionalHeader.SizeOfImage || size > nt->OptionalHeader.SizeOfImage - rva)
            return false;
        for (unsigned i = 0; i < nt->FileHeader.NumberOfSections; ++i) {
            const auto& s = sections[i];
            if (rva < s.VirtualAddress || rva - s.VirtualAddress > s.Misc.VirtualSize ||
                size > s.Misc.VirtualSize - (rva - s.VirtualAddress)) continue;
            const bool executable = (s.Characteristics & IMAGE_SCN_MEM_EXECUTE) != 0;
            if (!(s.Characteristics & IMAGE_SCN_MEM_READ) || executable != code ||
                !memory.range(game_base + rva, size, false)) return false;
            MEMORY_BASIC_INFORMATION region{};
            if (!VirtualQuery(reinterpret_cast<void*>(game_base + rva), &region, sizeof(region)) ||
                reinterpret_cast<uintptr_t>(region.AllocationBase) != game_base) return false;
            const DWORD mode = region.Protect & 0xff;
            return !code || mode == PAGE_EXECUTE_READ || mode == PAGE_EXECUTE_READWRITE ||
                   mode == PAGE_EXECUTE_WRITECOPY;
        }
        return false;
    }
};

// 首次使用解析 SDK 入口及关联的接口/布局证据，成功与失败均缓存，不新增帧扫描。
// UpdateTransform 仅检查 REFramework 未挂钩的内部窗口；不调用或覆盖它。
bool supported_host() {
    if (host_state) return host_state > 0;
    if (!host) return false;
    if (!host->sdk || !host->sdk->functions || !host->sdk->tdb || !host->sdk->method ||
        !host->sdk->functions->get_tdb || !host->sdk->functions->get_vm_context ||
        !host->sdk->tdb->find_method || !host->sdk->tdb->find_type || !host->sdk->method->get_function ||
        !host->sdk->method->get_return_type || !host->sdk->method->get_num_params || !host->sdk->method->get_params)
        return reject_host("SDK interface unavailable");
    host_state = -1;
    game_base = reinterpret_cast<uintptr_t>(GetModuleHandleW(L"MonsterHunterWilds.exe"));
    Memory m;
    ImageContract image;
    if (!image.read(m)) return reject_host("invalid x64 PE structure");
    const auto tdb = host->sdk->functions->get_tdb();
    if (!tdb) return reject_host("TDB unavailable");
    const char* names[] = {"set_LocalPosition", "set_LocalRotation", "set_LocalScale",
                           "get_ConstraintJoint", "get_OutputTargetCount", "get_CurrentScene"};
    const char* parameters[] = {"via.vec3", "via.Quaternion", "via.vec3"};
    std::array<uintptr_t, 6> typed{};
    for (unsigned i = 0; i < typed.size(); ++i) {
        auto method = host->sdk->tdb->find_method(tdb,
            i == 5 ? "via.SceneManager" : i == 4 ? "via.motion.JointConstraintsLayer" : "via.Joint", names[i]);
        if (!method) return reject_host("Joint setter method missing", i);
        const auto expected_return = host->sdk->tdb->find_type(tdb,
            i < 3 ? "System.Void" : i == 3 ? "via.Joint" : i == 4 ? "System.Int32" : "via.Scene");
        if (!expected_return || host->sdk->method->get_return_type(method) != expected_return ||
            host->sdk->method->get_num_params(method) != (i < 3 ? 1u : 0u))
            return reject_host("typed method signature mismatch", i);
        if (i < 3) {
            REFrameworkMethodParameter parameter{};
            uint32_t count = 0;
            if (host->sdk->method->get_params(method, &parameter, sizeof(parameter), &count) != REFRAMEWORK_ERROR_NONE ||
                count != 1 || parameter.t != host->sdk->tdb->find_type(tdb, parameters[i]))
                return reject_host("Joint setter parameter mismatch", i);
        }
        auto fn = host->sdk->method->get_function(method);
        const auto address = reinterpret_cast<uintptr_t>(fn);
        if (address < game_base || !image.range(m, address - game_base, 8, true))
            return reject_host("typed method outside executable image", i);
        typed[i] = address - game_base;
        if (i < setters.size()) setters[i] = reinterpret_cast<Setter>(fn);
    }
    host_resolver::Resolver<ImageContract, Memory> resolver(game_base, image, m);
    if (!resolver.run(typed, resolved_host)) return reject_host("native structure unresolved or ambiguous; stage", resolver.stage);
    const auto kernel = GetModuleHandleW(L"kernel32.dll");
    const uintptr_t imports[] = {resolved_host.enter_iat, resolved_host.leave_iat};
    const char* import_names[] = {"EnterCriticalSection", "LeaveCriticalSection"};
    for (unsigned i = 0; i < 2; ++i) {
        const auto expected = kernel ? GetProcAddress(kernel, import_names[i]) : nullptr;
        if (!expected || forefoot::value<uintptr_t>(game_base + imports[i]) != reinterpret_cast<uintptr_t>(expected))
            return reject_host("scene lock import mismatch", imports[i]);
    }
    host_state = 1;
    return true;
}

struct SceneLock {
    CRITICAL_SECTION* lock;
    bool held;
    explicit SceneLock(CRITICAL_SECTION* p) : lock(p), held(TryEnterCriticalSection(p) != 0) {}
    ~SceneLock() { if (held) LeaveCriticalSection(lock); }
};
struct NativeSetters {
    void* context;
    void position(uintptr_t joint, const float* data) { setters[0](context, reinterpret_cast<void*>(joint), data); }
    void rotation(uintptr_t joint, const float* data) { setters[1](context, reinterpret_cast<void*>(joint), data); }
    void scale(uintptr_t joint, const float* data) { setters[2](context, reinterpret_cast<void*>(joint), data); }
};

int apply(const Arguments& args, bool inspect_only = false) {
    if (!supported_host()) return forefoot::UnsupportedHost;
    Memory memory;
    const auto slot = game_base+resolved_host.scene_slot;
    if (!memory.range(slot, sizeof(uintptr_t), false)) return forefoot::UnsupportedHost;
    const auto scene = forefoot::value<uintptr_t>(slot);
    if (!scene || scene > std::numeric_limits<uintptr_t>::max() - host_layout::scene_lock ||
        !memory.range(scene+host_layout::scene_lock, sizeof(CRITICAL_SECTION), true)) return forefoot::Busy;
    auto context = host->sdk->functions->get_vm_context();
    if (!context) return forefoot::MissingContext;
    SceneLock guard(reinterpret_cast<CRITICAL_SECTION*>(scene+host_layout::scene_lock));
    if (!guard.held) return forefoot::Busy;
    if (forefoot::value<uintptr_t>(slot) != scene) return forefoot::Busy;
    const forefoot::Request request{args.values[1], args.values[2], args.values[3], args.values[4], args.values[5]};
    forefoot::Plan plan;
    auto status = forefoot::prepare(memory, request, plan);
    if (status != forefoot::Applied || inspect_only) return status;
    NativeSetters native{context};
    return forefoot::commit(plan, native);
}

struct ResourceSceneLock {
    CRITICAL_SECTION* lock = nullptr;
    bool held = false;
    ResourceSceneLock(const Memory& memory, uintptr_t expected_scene) {
        const auto slot = game_base + resolved_host.scene_slot;
        if (!memory.range(slot, sizeof(uintptr_t), false)) return;
        const auto scene = forefoot::value<uintptr_t>(slot);
        // Compare the scalar before touching a possibly retired scene's critical section.
        if (!scene || scene != expected_scene || scene > std::numeric_limits<uintptr_t>::max() - host_layout::scene_lock ||
            !memory.range(scene + host_layout::scene_lock, sizeof(CRITICAL_SECTION), true)) return;
        lock = reinterpret_cast<CRITICAL_SECTION*>(scene + host_layout::scene_lock);
        if (!TryEnterCriticalSection(lock)) { lock = nullptr; return; }
        held = forefoot::value<uintptr_t>(slot) == scene;
    }
    ResourceSceneLock(const ResourceSceneLock&) = delete;
    ~ResourceSceneLock() { if (lock) LeaveCriticalSection(lock); }
};

// Read-only compatibility check; original layers and resources are never edited.
// Keep these extra witnesses local to this optional path, not the existing IK gate.
int inspect_constraint(const Arguments& args) {
    if (!args.values[1] || args.values[2] || args.values[3] || args.values[4] || args.values[5])
        return constraint_reader::Invalid;
    if (!supported_host() || !bsfn_resource::available(host->sdk)) return forefoot::UnsupportedHost;
    Memory memory;
    const auto object = reinterpret_cast<bsfn_resource::Object>(args.values[1]);
    if (!memory.range(args.values[1], 0x28, false) || !host->sdk->managed_object->is_managed_object(object))
        return constraint_reader::Invalid;
    const auto tdb = host->sdk->functions->get_tdb();
    const auto expected_type = host->sdk->tdb->find_type(tdb, bsfn_resource::layer_type);
    if (!expected_type || host->sdk->managed_object->get_type_definition(object) != expected_type)
        return constraint_reader::Invalid;
    bsfn_resource::References references{host->sdk};
    bsfn_resource::Pin<bsfn_resource::Object> pin(references);
    pin.acquire(object);
    const auto slot = game_base + resolved_host.scene_slot;
    if (!memory.range(slot, sizeof(uintptr_t), false)) return forefoot::UnsupportedHost;
    ResourceSceneLock guard(memory, forefoot::value<uintptr_t>(slot));
    return guard.held ? constraint_reader::layer(memory, args.values[1]) : constraint_reader::Pending;
}

int apply_resource_impl(const Arguments& args, bool fingers, bsfn_resource::Diagnostic& diagnostic) {
    if (!args.values[1] || !args.values[2] || args.values[1] == args.values[2] ||
        args.values[4] || args.values[5] || (fingers ? args.values[3] < 1 || args.values[3] > 15 : args.values[3] != 0))
        return bsfn_resource::BadArguments;
    if (!supported_host()) return bsfn_resource::UnsupportedHost;
    if (!bsfn_resource::available(host->sdk)) return bsfn_resource::MissingApi;
    Memory memory;
    const auto slot = game_base + resolved_host.scene_slot;
    if (!memory.range(slot, sizeof(uintptr_t), false)) return bsfn_resource::UnsupportedHost;
    const auto expected_scene = forefoot::value<uintptr_t>(slot);
    if (!expected_scene) return bsfn_resource::Busy;
    if (!host->sdk->functions->get_vm_context()) return bsfn_resource::MissingContext;
    return bsfn_resource::execute(host->sdk, memory, args.values[1], args.values[2],
        static_cast<unsigned>(args.values[3]), fingers, [&] { return ResourceSceneLock(memory, expected_scene); }, &diagnostic);
}

std::atomic<unsigned> resource_error_logs{0};
int apply_resource(const Arguments& args, bool fingers) {
    bsfn_resource::Diagnostic diagnostic;
    int result;
    try { result = apply_resource_impl(args, fingers, diagnostic); }
    catch (...) { diagnostic.native_exception = true; result = bsfn_resource::Unexpected; }
    // Only a diagnostic budget is global; no target/resource identity is retained.
    if (result >= 10 && host && host->functions && host->functions->log_error) {
        unsigned count = resource_error_logs.load(std::memory_order_relaxed);
        while (count < 8 && !resource_error_logs.compare_exchange_weak(count, count + 1, std::memory_order_relaxed)) {}
        if (count < 8) try {
            host->functions->log_error("[BSFNResource] op=%s status=%d phase=%s method=%s sdk=%d exception=%d native_exception=%d settings_read=%d pause=%u expected_pause=%u timing=%u blend=%.17g (log %u/8)",
                fingers ? "fingers" : "ik", result, diagnostic.phase, diagnostic.method, diagnostic.sdk_error,
                diagnostic.exception ? 1 : 0, diagnostic.native_exception ? 1 : 0,
                diagnostic.settings_read ? 1 : 0, static_cast<unsigned>(diagnostic.pause),
                static_cast<unsigned>(diagnostic.expected_pause), static_cast<unsigned>(diagnostic.timing),
                diagnostic.blend, count + 1);
        } catch (...) {}
    }
    return result;
}
} // namespace

extern "C" __declspec(dllexport) void reframework_plugin_required_version(REFrameworkPluginVersion* v) {
    v->major = 1; v->minor = 15; v->patch = 0; v->game_name = nullptr;
}
extern "C" __declspec(dllexport) bool reframework_plugin_initialize(const REFrameworkPluginInitializeParam* p) {
    if (!p || !p->functions || !p->sdk) return false;
    host_copy = *p;
    host = &host_copy;
    p->functions->log_info("[BSFNForefoot] 1.7.6 ready; dynamic native contract, explicit calls only, no hooks or frame callbacks");
    return true;
}
extern "C" __declspec(dllexport) int bsfn_forefoot_probe(lua_State* state) {
    Arguments args;
    return args.parse(state) ? args.finish(8) : 0;
}
extern "C" __declspec(dllexport) int bsfn_forefoot_apply(lua_State* state) {
    Arguments args;
    return args.parse(state) ? args.finish(apply(args)) : 0;
}
// 与写入入口共用场景锁和完整结构校验；只读入口不调用任何姿态 setter。
extern "C" __declspec(dllexport) int bsfn_forefoot_inspect(lua_State* state) {
    Arguments args;
    return args.parse(state) ? args.finish(apply(args, true)) : 0;
}
extern "C" __declspec(dllexport) int bsfn_forefoot_constraint(lua_State* state) {
    Arguments args;
    if (!args.parse(state)) return 0;
    int status = constraint_reader::Invalid;
    try { status = inspect_constraint(args); } catch (...) {}
    return args.finish(status);
}
extern "C" __declspec(dllexport) int bsfn_resource_ik(lua_State* state) {
    Arguments args;
    return args.parse(state) ? args.finish(apply_resource(args, false)) : 0;
}
extern "C" __declspec(dllexport) int bsfn_resource_probe(lua_State* state) {
    Arguments args;
    return args.parse(state) ? args.finish(1) : 0;
}
extern "C" __declspec(dllexport) int bsfn_resource_fingers(lua_State* state) {
    Arguments args;
    return args.parse(state) ? args.finish(apply_resource(args, true)) : 0;
}
