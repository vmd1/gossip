// Loads libgossip_ffi.so the way the app's JNA bindings do (dlopen + dlsym of the UniFFI C ABI) and makes real
// calls, to prove the shared library works in Android's runtime. Built and run by scripts/test-android-library.sh.
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct { uint64_t capacity; uint64_t len; uint8_t *data; } RustBuffer;
typedef struct { int8_t code; RustBuffer errorBuf; } RustCallStatus;

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "libgossip_ffi.so";
    void *lib = dlopen(path, RTLD_NOW);
    if (!lib) { printf("FAIL dlopen: %s\n", dlerror()); return 1; }

    uint32_t (*version)(void) = dlsym(lib, "ffi_gossip_ffi_uniffi_contract_version");
    RustBuffer (*new_uuid)(RustCallStatus *) = dlsym(lib, "uniffi_gossip_ffi_fn_func_new_uuid");
    RustBuffer (*gen_identity)(RustCallStatus *) = dlsym(lib, "uniffi_gossip_ffi_fn_func_generate_identity");
    void (*buf_free)(RustBuffer, RustCallStatus *) = dlsym(lib, "ffi_gossip_ffi_rustbuffer_free");
    if (!version || !new_uuid || !gen_identity || !buf_free) { printf("FAIL dlsym\n"); return 1; }

    int failures = 0;
    printf("contract version %u\n", version());
    if (version() != 30) { printf("FAIL contract version\n"); failures++; }

    RustCallStatus st = {0};
    RustBuffer u = new_uuid(&st);
    char text[64] = {0};
    if (u.len < sizeof text) memcpy(text, u.data, u.len);
    printf("uuid %s\n", text);
    if (st.code != 0 || u.len != 36 || text[8] != '-' || text[13] != '-' || text[14] != '4') { printf("FAIL new_uuid\n"); failures++; }
    buf_free(u, &st);

    RustCallStatus st2 = {0};
    RustBuffer id = gen_identity(&st2);
    printf("generate_identity returned %llu bytes\n", (unsigned long long)id.len);
    // device id (4 + 36) + four byte arrays of 32 (each 4 + 32).
    if (st2.code != 0 || id.len != 4 + 36 + 4 * (4 + 32)) { printf("FAIL generate_identity\n"); failures++; }
    buf_free(id, &st2);

    printf(failures ? "FAILED\n" : "android library: all checks passed\n");
    return failures ? 1 : 0;
}
