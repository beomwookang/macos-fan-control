/* smc.h - minimal AppleSMC access (Apple Silicon + Intel), IOKit only. */
#ifndef FANCTL_SMC_H
#define FANCTL_SMC_H

#include <stdint.h>
#include <stdbool.h>

#define SMC_DATA_MAX 32

/* four-char key packed big-endian into a uint32, e.g. "F0Tg" */
uint32_t smc_key(const char *s);
void     smc_key_str(uint32_t key, char out[5]);

/* SMC result byte from the most recent call. 0x86 means the key exists but is
 * not writable - F0Mn is like that on an M4 mini. */
uint8_t smc_last_result(void);
#define SMC_RESULT_READONLY 0x86

int  smc_open(void);          /* 0 on success */
void smc_close(void);

/* Raw access. size is in/out for read. */
int smc_key_info(uint32_t key, uint32_t *size, uint32_t *type);
int smc_key_info_full(uint32_t key, uint32_t *size, uint32_t *type,
                      uint8_t *attr);
int smc_read_raw(uint32_t key, uint32_t size, uint8_t *buf);
int smc_write_raw(uint32_t key, uint32_t size, const uint8_t *buf);
int smc_write_verbose(uint32_t key, uint32_t size, const uint8_t *buf,
                      int *kr_out, uint8_t *result, uint8_t *status);

/* Typed helpers: decode flt/fpe2/sp78/ui8/ui16/ui32/si16 into double. */
int smc_read_num(uint32_t key, uint32_t size, uint32_t type, double *out);
int smc_write_num(uint32_t key, uint32_t size, uint32_t type, double val);

#endif
