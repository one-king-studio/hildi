/*
 * hildegard_tls_shim.h - a tiny, opaque C surface over mbedTLS for the
 * hildegard-helper Pascal TLS socket handler.
 *
 * The shim exists so that no mbedTLS struct layout is mirrored in Pascal: the
 * Pascal unit holds a `hildegard_tls *` it never dereferences. mbedTLS error
 * codes are normalised to a small, stable result set so Pascal needs no mbedTLS
 * constants.
 *
 * The caller owns the file descriptor; the shim only reads and writes it.
 */
#ifndef HILDEGARD_TLS_SHIM_H
#define HILDEGARD_TLS_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

/* Result codes (normalised mbedTLS error space). */
#define HILDEGARD_TLS_OK          0
#define HILDEGARD_TLS_WOULD_BLOCK (-1)  /* retryable; see the read/write notes */
#define HILDEGARD_TLS_ERROR       (-2)  /* hard failure; see last_error */

typedef struct hildegard_tls hildegard_tls;

/* Lifecycle. new() returns NULL on allocation failure. */
hildegard_tls *hildegard_tls_new(void);
void           hildegard_tls_free(hildegard_tls *h);

/* Trust chain: a NUL-terminated PEM buffer (len includes the NUL), or a PEM
   file path. 0 on success, HILDEGARD_TLS_ERROR otherwise. */
int hildegard_tls_set_ca_mem(hildegard_tls *h, const void *pem, unsigned len);
int hildegard_tls_set_ca_file(hildegard_tls *h, const char *path);

/* Handshake on an already-connected fd. host drives SNI and verification.
   0 on success, HILDEGARD_TLS_ERROR otherwise. */
int hildegard_tls_connect(hildegard_tls *h, int fd, const char *host);

/* read:  >0 bytes, 0 orderly EOF, HILDEGARD_TLS_WOULD_BLOCK, or ERROR.
   write: >=0 bytes, or WOULD_BLOCK/ERROR. */
int hildegard_tls_read(hildegard_tls *h, void *buf, int len);
int hildegard_tls_write(hildegard_tls *h, const void *buf, int len);

/* Buffered plaintext bytes already decrypted and waiting. */
int hildegard_tls_pending(hildegard_tls *h);

/* Best-effort close_notify. 0 or HILDEGARD_TLS_ERROR. */
int hildegard_tls_close(hildegard_tls *h);

/* The last error: the mbedTLS code, and a human, non-secret string copied into
   buf. Returns the code. */
int hildegard_tls_last_error(hildegard_tls *h, char *buf, unsigned buflen);

/* Live shim contexts; the test asserts it returns to zero. */
int hildegard_tls_live_count(void);

/* The embedded CA bundle, generated at build time from deps/cacert/cacert.pem.
   len includes the trailing NUL. */
const unsigned char *hildegard_ca_pem(void);
unsigned             hildegard_ca_pem_len(void);

/* SHA-256 (via mbedTLS), for PKCE. Writes 32 bytes to out. 0 on success. */
int hildegard_sha256(const unsigned char *data, unsigned len,
                     unsigned char out[32]);

#ifdef __cplusplus
}
#endif

#endif /* HILDEGARD_TLS_SHIM_H */
