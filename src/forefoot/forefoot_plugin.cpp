#include <windows.h>
#include <array>
#include <atomic>
#include <cstring>
#include <limits>
#include <reframework/API.h>
#include "forefoot_core.hpp"
#include "host_signature.hpp"
#include "host_layout.hpp"
#include "resource_helper.hpp"
#include "constraint_reader.hpp"

namespace {
REFrameworkPluginInitializeParam host_copy{};
const REFrameworkPluginInitializeParam* host = nullptr;
using Setter = void (*)(void*, void*, const float*);
std::array<Setter, 3> setters{};
uintptr_t game_base = 0;
int host_state = 0;

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

 
 
bool supported_host() {
    if (host_state) return host_state > 0;
    if (!host) return false;
    if (!host->sdk || !host->sdk->functions || !host->sdk->tdb || !host->sdk->method ||
        !host->sdk->functions->get_tdb || !host->sdk->functions->get_vm_context ||
        !host->sdk->tdb->find_method || !host->sdk->method->get_function)
        return reject_host("SDK interface unavailable");
    host_state = -1;
    game_base = reinterpret_cast<uintptr_t>(GetModuleHandleW(L"MonsterHunterWilds.exe"));
    Memory m;
    ImageContract image;
    if (!image.read(m)) return reject_host("invalid x64 PE structure");
    for (const auto& sig : host_signature::anchors)
        if (!image.range(m, sig.rva, sig.bytes.size(), true) ||
            std::memcmp(reinterpret_cast<void*>(game_base+sig.rva), sig.bytes.data(), sig.bytes.size()))
            return reject_host("code window mismatch", sig.rva);
    for (const auto& sig : host_layout::witnesses)
        if (!image.range(m, sig.rva, sig.bytes.size(), true) ||
            std::memcmp(reinterpret_cast<void*>(game_base+sig.rva), sig.bytes.data(), sig.bytes.size()))
            return reject_host("native layout witness mismatch", sig.rva);
    if (!image.range(m, host_layout::scene_slot, sizeof(uintptr_t), false))
        return reject_host("scene slot outside data section");
    const auto kernel = GetModuleHandleW(L"kernel32.dll");
    const uintptr_t imports[] = {host_layout::enter_iat, host_layout::leave_iat};
    const char* import_names[] = {"EnterCriticalSection", "LeaveCriticalSection"};
    for (unsigned i = 0; i < 2; ++i) {
        const auto expected = kernel ? GetProcAddress(kernel, import_names[i]) : nullptr;
        if (!expected || !image.range(m, imports[i], sizeof(uintptr_t), false) ||
            forefoot::value<uintptr_t>(game_base + imports[i]) != reinterpret_cast<uintptr_t>(expected))
            return reject_host("scene lock import mismatch", imports[i]);
    }
    const auto tdb = host->sdk->functions->get_tdb();
    if (!tdb) return reject_host("TDB unavailable");
    const char* names[] = {"set_LocalPosition", "set_LocalRotation", "set_LocalScale"};
    const uintptr_t rvas[] = {0x0c294e60, 0x0c295130, 0x0c2951d0};
    for (unsigned i = 0; i < 3; ++i) {
        auto method = host->sdk->tdb->find_method(tdb, "via.Joint", names[i]);
        if (!method) return reject_host("Joint setter method missing", i);
        auto fn = host->sdk->method->get_function(method);
        if (reinterpret_cast<uintptr_t>(fn) != game_base+rvas[i]) return reject_host("Joint setter address mismatch", i);
        setters[i] = reinterpret_cast<Setter>(fn);
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

int apply(const Arguments& args) {
    if (!supported_host()) return forefoot::UnsupportedHost;
    Memory memory;
    const auto slot = game_base+host_layout::scene_slot;
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
    if (status != forefoot::Applied) return status;
    NativeSetters native{context};
    return forefoot::commit(plan, native);
}

struct ResourceSceneLock {
    CRITICAL_SECTION* lock = nullptr;
    bool held = false;
    ResourceSceneLock(const Memory& memory, uintptr_t expected_scene) {
        const auto slot = game_base + host_layout::scene_slot;
        if (!memory.range(slot, sizeof(uintptr_t), false)) return;
        const auto scene = forefoot::value<uintptr_t>(slot);
         
        if (!scene || scene != expected_scene || scene > std::numeric_limits<uintptr_t>::max() - host_layout::scene_lock ||
            !memory.range(scene + host_layout::scene_lock, sizeof(CRITICAL_SECTION), true)) return;
        lock = reinterpret_cast<CRITICAL_SECTION*>(scene + host_layout::scene_lock);
        if (!TryEnterCriticalSection(lock)) { lock = nullptr; return; }
        held = forefoot::value<uintptr_t>(slot) == scene;
    }
    ResourceSceneLock(const ResourceSceneLock&) = delete;
    ~ResourceSceneLock() { if (lock) LeaveCriticalSection(lock); }
};

 
 
int inspect_constraint(const Arguments& args) {
    if (!args.values[1] || args.values[2] || args.values[3] || args.values[4] || args.values[5])
        return constraint_reader::Invalid;
    if (!supported_host() || !bsfn_resource::available(host->sdk)) return forefoot::UnsupportedHost;
    Memory memory;
    static int verified = 0;
    if (!verified) {
        verified = -1;
        ImageContract image;
        const std::array<host_layout::Witness, 4> witnesses = {{
             
            {0x6389f, std::string_view("\x48\x83\x79\x10\x00\x0f\x84\xaa\x06\x00\x00\x48\x89\xce\x48\x8b\x49\x20\x48\x85\xc9\x0f\x84\x9a\x06\x00\x00\x80\x79\x39\x00\x75\x0d\xe8\xbb\xeb\xfa\xff\x84\xc0\x0f\x84\x87\x06\x00\x00", 46)},
            {0xc3d7930, std::string_view("\x48\x89\xd1\xe9\xb8\x6d\xa3\x00", 8)},
            {0xce0e6f0, std::string_view("\x48\x83\xec\x28\x48\x83\xc1\x20\xe8\x93\xb6\x81\xfd\x48\x85\xc0\x74\x0c\x0f\xb7\x80\x88\x00\x00\x00", 25)},
            {0xa629d90, std::string_view("\x56\x48\x83\xec\x20\x48\x89\xce\x48\x8b\x09\x48\x85\xc9\x74\x41\x80\x79\x39\x00\x75\x0c\xe8\xd5\x86\x9e\xf5\x84\xc0\x74\x32\x48\x8b\x0e\x48\x8b\x41\x60\x48\x8d\x48\x10\x48\x85\xc0\x48\x0f\x44\xc8\x8b\x51\x18", 52)}
        }};
        if (!image.read(memory)) return forefoot::UnsupportedHost;
        for (const auto& witness : witnesses)
            if (!image.range(memory, witness.rva, witness.bytes.size(), true) ||
                std::memcmp(reinterpret_cast<void*>(game_base + witness.rva), witness.bytes.data(), witness.bytes.size()))
                return forefoot::UnsupportedHost;
        const auto tdb = host->sdk->functions->get_tdb();
        auto method = host->sdk->tdb->find_method(tdb, "via.motion.JointConstraintsLayer", "get_OutputTargetCount");
        if (!method || reinterpret_cast<uintptr_t>(host->sdk->method->get_function(method)) != game_base + 0xc3d7930)
            return forefoot::UnsupportedHost;
        verified = 1;
    }
    if (verified < 0) return forefoot::UnsupportedHost;
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
    const auto slot = game_base + host_layout::scene_slot;
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
    const auto slot = game_base + host_layout::scene_slot;
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
}  

extern "C" __declspec(dllexport) void reframework_plugin_required_version(REFrameworkPluginVersion* v) {
    v->major = 1; v->minor = 15; v->patch = 0; v->game_name = nullptr;
}
extern "C" __declspec(dllexport) bool reframework_plugin_initialize(const REFrameworkPluginInitializeParam* p) {
    if (!p || !p->functions || !p->sdk) return false;
    host_copy = *p;
    host = &host_copy;
    p->functions->log_info("[BSFNForefoot] 1.7.5 ready; native contract gate, explicit calls only, no hooks or frame callbacks");
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
