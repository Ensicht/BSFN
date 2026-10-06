#include <windows.h>
#include <bcrypt.h>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <vector>
#include <string>
#include <cstddef>
#include <reframework/API.h>
#include "native_vm.hpp"

static const REFrameworkPluginFunctions *api = nullptr;
static constexpr char expected_hash[] =
    "4f0bd2768f8eb081da1f83a24c2b7d4bf1f69636857b9d3444b275a8014c20f4";
static_assert(offsetof(REFrameworkPluginFunctions, create_script_state) == 0x68);
static_assert(offsetof(REFrameworkPluginInitializeParam, functions) == 0x10);

// Pair the host Lua lock on every return path; this adapter runs only at startup.
struct LuaLock {
    LuaLock() {
        api->lock_lua();
    }
    ~LuaLock() {
        api->unlock_lua();
    }
};

// Private entry points are accepted only when loaded bytes match the pinned file.
static bool same_entry_bytes(uintptr_t base, const wchar_t *path) {
    HANDLE file =
        CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (file == INVALID_HANDLE_VALUE)
        return false;
    unsigned char header[4096]{};
    DWORD count = 0;
    bool ok = ReadFile(file, header, sizeof(header), &count, nullptr) && count == sizeof(header);
    auto dos = reinterpret_cast<const IMAGE_DOS_HEADER *>(header);
    ok = ok && dos->e_magic == IMAGE_DOS_SIGNATURE && dos->e_lfanew > 0 &&
         static_cast<size_t>(dos->e_lfanew) + sizeof(IMAGE_NT_HEADERS64) < sizeof(header);
    if (!ok) {
        CloseHandle(file);
        return false;
    }
    auto nt = reinterpret_cast<const IMAGE_NT_HEADERS64 *>(header + dos->e_lfanew);
    auto sections = IMAGE_FIRST_SECTION(nt);
    auto section_end =
        reinterpret_cast<const unsigned char *>(sections + nt->FileHeader.NumberOfSections);
    ok = nt->Signature == IMAGE_NT_SIGNATURE &&
         nt->FileHeader.Machine == IMAGE_FILE_MACHINE_AMD64 &&
         section_end <= header + sizeof(header) &&
         nt->OptionalHeader.SizeOfImage > stock_vm::state_rva + 8;
    for (auto rva : {uintptr_t(0x60d0), stock_vm::load_rva, stock_vm::pcall_rva,
                     stock_vm::settop_rva, stock_vm::index_rva}) {
        if (!ok)
            break;
        bool found = false;
        for (unsigned i = 0; i < nt->FileHeader.NumberOfSections; ++i) {
            const auto &section = sections[i];
            if (rva < section.VirtualAddress ||
                rva - section.VirtualAddress + 32 > section.SizeOfRawData)
                continue;
            DWORD offset =
                section.PointerToRawData + static_cast<DWORD>(rva - section.VirtualAddress);
            unsigned char expected[32];
            auto memory = reinterpret_cast<void *>(base + rva);
            found = SetFilePointer(file, offset, nullptr, FILE_BEGIN) != INVALID_SET_FILE_POINTER &&
                    ReadFile(file, expected, sizeof(expected), &count, nullptr) &&
                    count == sizeof(expected) && stock_vm::readable(memory, sizeof(expected)) &&
                    std::memcmp(memory, expected, sizeof(expected)) == 0;
            break;
        }
        ok = found;
    }
    CloseHandle(file);
    return ok;
}

static bool hash_file(const wchar_t *path, std::string &result) {
    HANDLE file =
        CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (file == INVALID_HANDLE_VALUE)
        return false;
    BCRYPT_ALG_HANDLE algorithm{};
    BCRYPT_HASH_HANDLE hash{};
    bool ok = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0;
    if (ok)
        ok = BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) >= 0;
    unsigned char buffer[16384], digest[32];
    DWORD count = 0;
    while (ok) {
        if (!ReadFile(file, buffer, sizeof(buffer), &count, nullptr)) {
            ok = false;
            break;
        }
        if (!count)
            break;
        ok = BCryptHashData(hash, buffer, count, 0) >= 0;
    }
    if (ok)
        ok = BCryptFinishHash(hash, digest, sizeof(digest), 0) >= 0;
    if (hash)
        BCryptDestroyHash(hash);
    if (algorithm)
        BCryptCloseAlgorithmProvider(algorithm, 0);
    CloseHandle(file);
    if (ok) {
        char hex[65];
        for (int i = 0; i < 32; ++i)
            std::snprintf(hex + i * 2, 3, "%02x", digest[i]);
        result = hex;
    }
    return ok;
}

extern "C" __declspec(dllexport) void
reframework_plugin_required_version(REFrameworkPluginVersion *v) {
    v->major = 1;
    v->minor = 15;
    v->patch = 0;
    v->game_name = nullptr;
}

extern "C" __declspec(dllexport) bool
reframework_plugin_initialize(const REFrameworkPluginInitializeParam *param) {
    if (!param || !param->functions)
        return false;
    api = param->functions;
    api->log_info("[BSFNStockBridge] loaded; startup-only bridge, no frame/lifecycle hooks");
    return true;
}

// Re-read the current private state under the host lock; never retain an old state.
extern "C" __declspec(dllexport) int bsfn_bootstrap(lua_State *main_state) {
    if (!api)
        return 0;
    HMODULE module = GetModuleHandleW(L"BoneSystem.dll");
    wchar_t path[32768]{};
    std::string hash;
    if (!module || !GetModuleFileNameW(module, path, 32768) || !hash_file(path, hash) ||
        hash != expected_hash) {
        api->log_error("[BSFNStockBridge] refused: original BoneSystem 26.2.10.2 SHA-256 required");
        return 0;
    }
    auto base = reinterpret_cast<uintptr_t>(module);
    if (!same_entry_bytes(base, path)) {
        api->log_error(
            "[BSFNStockBridge] refused: loaded BoneSystem entry points differ from original file");
        return 0;
    }
    auto state_slot = reinterpret_cast<void *>(base + stock_vm::state_rva);
    if (!stock_vm::readable(state_slot, sizeof(void *)))
        return 0;
    std::ifstream input("reframework/autorun/BSFNStockBridge/bootstrap.lua", std::ios::binary);
    std::string code((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    if (!input || code.empty() || code.size() > 65536) {
        api->log_error("[BSFNStockBridge] missing/invalid bootstrap.lua");
        return 0;
    }
    std::string error;
    bool ok = false;
    {
        LuaLock lock;
        void *state = stock_vm::read<void *>(state_slot, 0);
        ok = state && state != main_state;
        if (ok)
            ok = stock_vm::run(base, state, code.data(), code.size(), true, error);
        else
            error = "BoneSystem private state is unavailable or equals main state";
    }
    if (ok)
        api->log_info(
            "[BSFNStockBridge] ready: original closures attached in BoneSystem private state");
    else
        api->log_error("[BSFNStockBridge] bootstrap failed: %s", error.c_str());
    return 0;
}
