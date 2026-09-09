#include "smc.h"

#include <IOKit/IOKitLib.h>
#include <string.h>
#include <math.h>

#define KERNEL_INDEX_SMC   2
#define SMC_CMD_READ_BYTES   5
#define SMC_CMD_WRITE_BYTES  6
#define SMC_CMD_READ_KEYINFO 9

/* Canonical 80-byte SMCKeyData_t. Natural C alignment matches what the
 * AppleSMC user client expects on both arm64 and x86_64. */
typedef struct {
    uint8_t  major, minor, build, reserved;
    uint16_t release;
} smc_vers_t;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} smc_plimit_t;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} smc_keyinfo_t;

typedef struct {
    uint32_t      key;
    smc_vers_t    vers;
    smc_plimit_t  pLimitData;
    smc_keyinfo_t keyInfo;
    uint8_t       result;
    uint8_t       status;
    uint8_t       data8;
    uint32_t      data32;
    uint8_t       bytes[SMC_DATA_MAX];
} smc_data_t;

_Static_assert(sizeof(smc_data_t) == 80, "SMCKeyData_t must be 80 bytes");

static io_connect_t g_conn = 0;
static uint8_t      g_last_result = 0;   /* SMC result byte of the last call */

uint8_t smc_last_result(void) { return g_last_result; }

uint32_t smc_key(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8)  |  (uint32_t)(uint8_t)s[3];
}

void smc_key_str(uint32_t key, char out[5]) {
    out[0] = (char)(key >> 24); out[1] = (char)(key >> 16);
    out[2] = (char)(key >> 8);  out[3] = (char)key; out[4] = 0;
}

int smc_open(void) {
    if (g_conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(MACH_PORT_NULL,  /* default main port */
                                                  IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    if (kr != kIOReturnSuccess) { g_conn = 0; return -2; }
    return 0;
}

void smc_close(void) {
    if (g_conn) { IOServiceClose(g_conn); g_conn = 0; }
}

static int smc_call(smc_data_t *in, smc_data_t *out) {
    size_t osz = sizeof(smc_data_t);
    if (!g_conn) return -1;
    kern_return_t kr = IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC,
                                                in, sizeof(smc_data_t), out, &osz);
    g_last_result = out->result;
    if (kr != kIOReturnSuccess) return -2;
    if (out->result != 0) return -3;
    return 0;
}

/* Same as a write, but hands back exactly what the kernel said instead of
 * collapsing it to a single failure code. Diagnostics only. */
int smc_write_verbose(uint32_t key, uint32_t size, const uint8_t *buf,
                      int *kr_out, uint8_t *result, uint8_t *status) {
    smc_data_t in = {0}, out = {0};
    size_t osz = sizeof(smc_data_t);
    if (size == 0 || size > SMC_DATA_MAX) return -1;
    if (!g_conn) return -1;
    in.key = key;
    in.keyInfo.dataSize = size;
    in.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(in.bytes, buf, size);
    kern_return_t kr = IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC,
                                                &in, sizeof(in), &out, &osz);
    if (kr_out)  *kr_out  = (int)kr;
    if (result)  *result  = out.result;
    if (status)  *status  = out.status;
    return (kr == kIOReturnSuccess && out.result == 0) ? 0 : -1;
}

int smc_key_info_full(uint32_t key, uint32_t *size, uint32_t *type, uint8_t *attr) {
    smc_data_t in = {0}, out = {0};
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != 0) return -1;
    if (size) *size = out.keyInfo.dataSize;
    if (type) *type = out.keyInfo.dataType;
    if (attr) *attr = out.keyInfo.dataAttributes;
    return 0;
}

int smc_key_info(uint32_t key, uint32_t *size, uint32_t *type) {
    return smc_key_info_full(key, size, type, NULL);
}

int smc_read_raw(uint32_t key, uint32_t size, uint8_t *buf) {
    smc_data_t in = {0}, out = {0};
    if (size == 0 || size > SMC_DATA_MAX) return -1;
    in.key = key;
    in.keyInfo.dataSize = size;
    in.data8 = SMC_CMD_READ_BYTES;
    if (smc_call(&in, &out) != 0) return -1;
    memcpy(buf, out.bytes, size);
    return 0;
}

int smc_write_raw(uint32_t key, uint32_t size, const uint8_t *buf) {
    smc_data_t in = {0}, out = {0};
    if (size == 0 || size > SMC_DATA_MAX) return -1;
    in.key = key;
    in.keyInfo.dataSize = size;
    in.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(in.bytes, buf, size);
    if (smc_call(&in, &out) != 0) return -1;
    return 0;
}

/* --- type codecs ------------------------------------------------------- */

#define T_FLT  0x666c7420u /* "flt " */
#define T_FP1F 0x66703166u
#define T_FP4C 0x66703463u
#define T_FP5B 0x66703562u
#define T_FP6A 0x66703661u
#define T_FP79 0x66703739u
#define T_FP88 0x66703838u
#define T_FPE2 0x66706532u /* "fpe2" */
#define T_SP78 0x73703738u /* "sp78" */
#define T_UI8  0x75693820u
#define T_UI16 0x75693136u
#define T_UI32 0x75693332u
#define T_SI8  0x73693820u
#define T_SI16 0x73693136u

static int fp_frac_bits(uint32_t type) {
    switch (type) {
    case T_FP1F: return 15; case T_FP4C: return 12; case T_FP5B: return 11;
    case T_FP6A: return 10; case T_FP79: return 9;  case T_FP88: return 8;
    case T_FPE2: return 2;
    default: return -1;
    }
}

int smc_read_num(uint32_t key, uint32_t size, uint32_t type, double *out) {
    uint8_t b[SMC_DATA_MAX] = {0};
    if (smc_read_raw(key, size, b) != 0) return -1;

    if (type == T_FLT && size == 4) {
        float f; memcpy(&f, b, 4);            /* little-endian on device */
        if (!isfinite(f)) return -1;
        *out = (double)f; return 0;
    }
    if (type == T_SP78 && size == 2) {        /* signed, big-endian, 8 frac */
        int16_t v = (int16_t)((b[0] << 8) | b[1]);
        *out = v / 256.0; return 0;
    }
    int fb = fp_frac_bits(type);
    if (fb >= 0 && size == 2) {               /* unsigned fixed, big-endian */
        uint16_t v = (uint16_t)((b[0] << 8) | b[1]);
        *out = v / (double)(1u << fb); return 0;
    }
    if (type == T_UI8  && size >= 1) { *out = b[0]; return 0; }
    if (type == T_SI8  && size >= 1) { *out = (int8_t)b[0]; return 0; }
    if (type == T_UI16 && size == 2) { *out = (uint16_t)((b[0]<<8)|b[1]); return 0; }
    if (type == T_SI16 && size == 2) { *out = (int16_t)((b[0]<<8)|b[1]); return 0; }
    if (type == T_UI32 && size == 4) {
        *out = ((uint32_t)b[0]<<24)|((uint32_t)b[1]<<16)|((uint32_t)b[2]<<8)|b[3];
        return 0;
    }
    return -2;                                 /* unsupported type */
}

int smc_write_num(uint32_t key, uint32_t size, uint32_t type, double val) {
    uint8_t b[SMC_DATA_MAX] = {0};
    if (type == T_FLT && size == 4) {
        float f = (float)val; memcpy(b, &f, 4);
    } else if (type == T_UI8 && size == 1) {
        b[0] = (uint8_t)(val < 0 ? 0 : (val > 255 ? 255 : val));
    } else if (type == T_UI16 && size == 2) {
        uint32_t v = (uint32_t)(val < 0 ? 0 : (val > 65535 ? 65535 : val));
        b[0] = (uint8_t)(v >> 8); b[1] = (uint8_t)v;
    } else {
        int fb = fp_frac_bits(type);
        if (fb < 0 || size != 2) return -2;
        double s = val * (double)(1u << fb);
        uint32_t v = (uint32_t)(s < 0 ? 0 : (s > 65535 ? 65535 : s));
        b[0] = (uint8_t)(v >> 8); b[1] = (uint8_t)v;
    }
    return smc_write_raw(key, size, b);
}
