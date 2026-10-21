#pragma once
#include <stdint.h>
#include <stddef.h>

// PBKDF2-HMAC-SHA1. Returns 0 on success.
int c_pbkdf2_sha1(const char *password, const uint8_t *salt, size_t saltLen,
                  uint32_t rounds, uint8_t *outKey, size_t keyLen);

// AES-128-CBC decrypt with PKCS7 padding.
// out must have room for inLen bytes; outLen is in/out. Returns 0 on success.
int c_aes128_cbc_decrypt(const uint8_t *key, const uint8_t *iv,
                         const uint8_t *in, size_t inLen,
                         uint8_t *out, size_t *outLen);
