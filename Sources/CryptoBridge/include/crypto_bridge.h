#ifndef CRYPTO_BRIDGE_H
#define CRYPTO_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/* AES-128-CBC decrypt with PKCS7 padding (HLS `AES-128`) over the linked libcrypto.
* `out` needs capacity >= in_len + 16; `*out_len` gets the plaintext length. 1 = ok. */
int gb_aes128_cbc_decrypt(const unsigned char *key, const unsigned char *iv,
                          const unsigned char *in, int in_len,
                          unsigned char *out, int *out_len);

#ifdef __cplusplus
}
#endif

#endif
