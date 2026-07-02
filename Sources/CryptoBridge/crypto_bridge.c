#include "crypto_bridge.h"
#include <openssl/evp.h>

int gb_aes128_cbc_decrypt(const unsigned char *key, const unsigned char *iv,
                          const unsigned char *in, int in_len,
                          unsigned char *out, int *out_len) {
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return 0;
    int ok = 0, len = 0, total = 0;
    /* PKCS7 padding is on by default for EVP_aes_128_cbc(). */
    if (EVP_DecryptInit_ex(ctx, EVP_aes_128_cbc(), NULL, key, iv) == 1 &&
        EVP_DecryptUpdate(ctx, out, &len, in, in_len) == 1) {
        total = len;
        if (EVP_DecryptFinal_ex(ctx, out + total, &len) == 1) {
            total += len;
            *out_len = total;
            ok = 1;
        }
    }
    EVP_CIPHER_CTX_free(ctx);
    return ok;
}
