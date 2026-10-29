/*
 * hildi_tls_shim.h - a tiny, opaque C surface over mbedTLS for the
 * hildi Pascal TLS socket handler.
 *
 * The shim exists so that no mbedTLS struct layout is mirrored in Pascal: the
 * Pascal unit holds a `hildi_tls *` it never dereferences. mbedTLS error
 * codes are normalised to a small, stable result set so Pascal needs no mbedTLS
 * constants.
 *
 * The caller owns the file descriptor; the shim only reads and writes it.
 */
#ifndef HILDI_TLS_SHIM_H
#define HILDI_TLS_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

/* Result codes (normalised mbedTLS error space). */
#define HILDI_TLS_OK          0
#define HILDI_TLS_WOULD_BLOCK (-1)  /* retryable; see the read/write notes */
#define HILDI_TLS_ERROR       (-2)  /* hard failure; see last_error */

typedef struct hildi_tls hildi_tls;

/* Lifecycle. new() returns NULL on allocation failure. */
hildi_tls *hildi_tls_new(void);
void           hildi_tls_free(hildi_tls *h);

/* Trust chain: a NUL-terminated PEM buffer (len includes the NUL), or a PEM
   file path. 0 on success, HILDI_TLS_ERROR otherwise. */
int hildi_tls_set_ca_mem(hildi_tls *h, const void *pem, unsigned len);
int hildi_tls_set_ca_file(hildi_tls *h, const char *path);

/* Handshake on an already-connected fd. host drives SNI and verification.
   0 on success, HILDI_TLS_ERROR otherwise. */
int hildi_tls_connect(hildi_tls *h, int fd, const char *host);

/* read:  >0 bytes, 0 orderly EOF, HILDI_TLS_WOULD_BLOCK, or ERROR.
   write: >=0 bytes, or WOULD_BLOCK/ERROR. */
int hildi_tls_read(hildi_tls *h, void *buf, int len);
int hildi_tls_write(hildi_tls *h, const void *buf, int len);

/* Buffered plaintext bytes already decrypted and waiting. */
int hildi_tls_pending(hildi_tls *h);

/* Best-effort close_notify. 0 or HILDI_TLS_ERROR. */
int hildi_tls_close(hildi_tls *h);

/* The last error: the mbedTLS code, and a human, non-secret string copied into
   buf. Returns the code. */
int hildi_tls_last_error(hildi_tls *h, char *buf, unsigned buflen);

/* Live shim contexts; the test asserts it returns to zero. */
int hildi_tls_live_count(void);

/* The embedded CA bundle, generated at build time from deps/cacert/cacert.pem.
   len includes the trailing NUL. */
const unsigned char *hildi_ca_pem(void);
unsigned             hildi_ca_pem_len(void);

/* SHA-256 (via mbedTLS), for PKCE. Writes 32 bytes to out. 0 on success. */
int hildi_sha256(const unsigned char *data, unsigned len,
                     unsigned char out[32]);

#ifdef __cplusplus
}
#endif

#endif /* HILDI_TLS_SHIM_H */
