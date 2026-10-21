#include "CCrypto.h"
#include <CommonCrypto/CommonCrypto.h>
#include <CommonCrypto/CommonKeyDerivation.h>
#include <string.h>

int c_pbkdf2_sha1(const char *password, const uint8_t *salt, size_t saltLen,
                  uint32_t rounds, uint8_t *outKey, size_t keyLen) {
    return CCKeyDerivationPBKDF(kCCPBKDF2, password, strlen(password),
                                salt, saltLen, kCCPRFHmacAlgSHA1,
                                rounds, outKey, keyLen);
}

int c_aes128_cbc_decrypt(const uint8_t *key, const uint8_t *iv,
                         const uint8_t *in, size_t inLen,
                         uint8_t *out, size_t *outLen) {
    size_t moved = 0;
    CCCryptorStatus st = CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
                                 key, kCCKeySizeAES128, iv,
                                 in, inLen, out, *outLen, &moved);
    if (st != kCCSuccess) return (int)st;
    *outLen = moved;
    return 0;
}
