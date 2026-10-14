#ifndef CRSASHIM_H
#define CRSASHIM_H

#include <stddef.h>
#include <stdint.h>

// Prototypes for BoringSSL functions that swift-crypto already links in (prefixed
// CCryptoBoringSSL_*). Declared with opaque pointers so this module does not depend on
// swift-crypto's non-product C target. Used to sign RSA keys with rsa-sha2-256/512,
// which Citadel 0.12.0 lacks (it only does SHA-1 "ssh-rsa").
void *CCryptoBoringSSL_RSA_new(void);
void CCryptoBoringSSL_RSA_free(void *rsa);
int CCryptoBoringSSL_RSA_set0_key(void *rsa, void *n, void *e, void *d);
int CCryptoBoringSSL_RSA_sign(int hash_nid, const uint8_t *digest, size_t digest_len,
                              uint8_t *out, unsigned *out_len, void *rsa);
int CCryptoBoringSSL_RSA_verify(int hash_nid, const uint8_t *digest, size_t digest_len,
                                const uint8_t *sig, size_t sig_len, void *rsa);
void *CCryptoBoringSSL_BN_bin2bn(const uint8_t *in, size_t len, void *ret);
void *CCryptoBoringSSL_BN_dup(const void *src);

enum { CRSA_NID_sha256 = 672, CRSA_NID_sha512 = 674 };

#endif
