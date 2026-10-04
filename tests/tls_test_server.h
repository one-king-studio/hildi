/*
 * tls_test_server.h - a minimal, test-only mbedTLS echo server.
 *
 * It generates a self-signed localhost certificate at startup (no key is
 * committed), listens on an ephemeral loopback port, completes one handshake,
 * and echoes bytes until the peer closes. Compiled into the test binary only.
 */
#ifndef HILDEGARD_TLS_TEST_SERVER_H
#define HILDEGARD_TLS_TEST_SERVER_H

#ifdef __cplusplus
extern "C" {
#endif

/* Starts the server and its certificate. Returns 0 on success, -1 on failure
   (see tls_test_server_error). */
int tls_test_server_start(void);

/* The ephemeral port the server is listening on, or 0. */
int tls_test_server_port(void);

/* Joins the server thread and releases its contexts. */
void tls_test_server_stop(void);

/* A human description of the last server-side error, or ''. */
const char *tls_test_server_error(void);

/* Copies the self-signed certificate PEM (NUL-terminated) into buf. Returns the
   number of bytes written including the NUL, or -1 if it does not fit. */
int tls_test_server_ca_pem(char *buf, unsigned buflen);

#ifdef __cplusplus
}
#endif

#endif /* HILDEGARD_TLS_TEST_SERVER_H */
