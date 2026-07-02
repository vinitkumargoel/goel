#ifndef CRYPTO_BRIDGE_H
#define CRYPTO_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/* AES-128-CBC decrypt with PKCS7 padding (the HLS `AES-128` method), over the
 * already-linked OpenSSL libcrypto. `out` must have capacity >= in_len + 16;
 * `*out_len` receives the plaintext length. Returns 1 on success, 0 on failure. */
int gb_aes128_cbc_decrypt(const unsigned char *key, const unsigned char *iv,
                          const unsigned char *in, int in_len,
                          unsigned char *out, int *out_len);

#ifdef __cplusplus
}
#endif

#endif
