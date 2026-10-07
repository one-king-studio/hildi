/*
 * hildegard_tls_shim.c - mbedTLS client wrapper for the hildegard-helper TLS
 * socket handler. See hildegard_tls_shim.h for the contract.
 *
 * One hildegard_tls owns one connection. Every mbedTLS context is initialised in
 * hildegard_tls_new and released in hildegard_tls_free, so there is a single
 * place to audit for leaks.
 */
#include "hildegard_tls_shim.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

#include "mbedtls/ctr_drbg.h"
#include "mbedtls/entropy.h"
#include "mbedtls/error.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"
#include "mbedtls/sha256.h"

struct hildegard_tls {
  mbedtls_ssl_context      ssl;
  mbedtls_ssl_config       conf;
  mbedtls_entropy_context  entropy;
  mbedtls_ctr_drbg_context ctr_drbg;
  mbedtls_x509_crt         ca;
  int  fd;
  int  handshaked;
  int  last_error;
  char last_error_string[256];
};

static int g_live_count = 0;

static void set_error(hildegard_tls *h, int code) {
  h->last_error = code;
  h->last_error_string[0] = '\0';
  if (code < 0) {
    mbedtls_strerror(code, h->last_error_string, sizeof(h->last_error_string));
    if (h->last_error_string[0] == '\0')
      snprintf(h->last_error_string, sizeof(h->last_error_string),
               "mbedTLS error %d", code);
  }
}

/* BIO callbacks over the caller's fd. */
static int bio_send(void *ctx, const unsigned char *buf, size_t len) {
  hildegard_tls *h = (hildegard_tls *)ctx;
  ssize_t n;
#ifdef MSG_NOSIGNAL
  /* Linux: suppress SIGPIPE on a write to a closed peer. */
  n = send(h->fd, buf, len, MSG_NOSIGNAL);
#else
  n = send(h->fd, buf, len, 0);
#endif
  if (n < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) return MBEDTLS_ERR_SSL_WANT_WRITE;
    return MBEDTLS_ERR_NET_SEND_FAILED;
  }
  return (int)n;
}

static int bio_recv(void *ctx, unsigned char *buf, size_t len) {
  hildegard_tls *h = (hildegard_tls *)ctx;
  ssize_t n = recv(h->fd, buf, len, 0);
  if (n < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) return MBEDTLS_ERR_SSL_WANT_READ;
    return MBEDTLS_ERR_NET_RECV_FAILED;
  }
  return (int)n;
}

hildegard_tls *hildegard_tls_new(void) {
  hildegard_tls *h = (hildegard_tls *)calloc(1, sizeof(*h));
  if (h == NULL) return NULL;
  mbedtls_ssl_init(&h->ssl);
  mbedtls_ssl_config_init(&h->conf);
  mbedtls_entropy_init(&h->entropy);
  mbedtls_ctr_drbg_init(&h->ctr_drbg);
  mbedtls_x509_crt_init(&h->ca);
  h->fd = -1;
  g_live_count++;
  return h;
}

void hildegard_tls_free(hildegard_tls *h) {
  if (h == NULL) return;
  mbedtls_ssl_free(&h->ssl);
  mbedtls_ssl_config_free(&h->conf);
  mbedtls_ctr_drbg_free(&h->ctr_drbg);
  mbedtls_entropy_free(&h->entropy);
  mbedtls_x509_crt_free(&h->ca);
  g_live_count--;
  free(h);
}

int hildegard_tls_live_count(void) { return g_live_count; }

int hildegard_tls_set_ca_mem(hildegard_tls *h, const void *pem, unsigned len) {
  int rc;
  if (h == NULL || pem == NULL || len == 0) return HILDEGARD_TLS_ERROR;
  mbedtls_x509_crt_free(&h->ca);
  mbedtls_x509_crt_init(&h->ca);
  /* PEM parsing expects the length to include the trailing NUL. */
  rc = mbedtls_x509_crt_parse(&h->ca, (const unsigned char *)pem, (size_t)len);
  if (rc != 0) {
    set_error(h, rc);
    return HILDEGARD_TLS_ERROR;
  }
  return HILDEGARD_TLS_OK;
}

int hildegard_tls_set_ca_file(hildegard_tls *h, const char *path) {
  int rc;
  if (h == NULL || path == NULL || path[0] == '\0') return HILDEGARD_TLS_ERROR;
  mbedtls_x509_crt_free(&h->ca);
  mbedtls_x509_crt_init(&h->ca);
  rc = mbedtls_x509_crt_parse_file(&h->ca, path);
  if (rc != 0) {
    set_error(h, rc);
    return HILDEGARD_TLS_ERROR;
  }
  return HILDEGARD_TLS_OK;
}

int hildegard_tls_connect(hildegard_tls *h, int fd, const char *host) {
  int rc;
  if (h == NULL) return HILDEGARD_TLS_ERROR;
  h->fd = fd;

#if defined(SO_NOSIGPIPE)
  {
    /* macOS: a write to a closed peer must return EPIPE, not raise SIGPIPE. */
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
  }
#endif

  rc = mbedtls_ctr_drbg_seed(&h->ctr_drbg, mbedtls_entropy_func, &h->entropy,
                             (const unsigned char *)"hildegard-helper", 15);
  if (rc != 0) {
    set_error(h, rc);
    return HILDEGARD_TLS_ERROR;
  }

  rc = mbedtls_ssl_config_defaults(&h->conf, MBEDTLS_SSL_IS_CLIENT,
                                   MBEDTLS_SSL_TRANSPORT_STREAM,
                                   MBEDTLS_SSL_PRESET_DEFAULT);
  if (rc != 0) {
    set_error(h, rc);
    return HILDEGARD_TLS_ERROR;
  }

  mbedtls_ssl_conf_authmode(&h->conf, MBEDTLS_SSL_VERIFY_REQUIRED);
  mbedtls_ssl_conf_rng(&h->conf, mbedtls_ctr_drbg_random, &h->ctr_drbg);
  mbedtls_ssl_conf_ca_chain(&h->conf, &h->ca, NULL);

  rc = mbedtls_ssl_setup(&h->ssl, &h->conf);
  if (rc != 0) {
    set_error(h, rc);
    return HILDEGARD_TLS_ERROR;
  }

  if (host != NULL && host[0] != '\0') {
    rc = mbedtls_ssl_set_hostname(&h->ssl, host);
    if (rc != 0) {
      set_error(h, rc);
      return HILDEGARD_TLS_ERROR;
    }
  }

  mbedtls_ssl_set_bio(&h->ssl, h, bio_send, bio_recv, NULL);

  while ((rc = mbedtls_ssl_handshake(&h->ssl)) != 0) {
    if (rc != MBEDTLS_ERR_SSL_WANT_READ && rc != MBEDTLS_ERR_SSL_WANT_WRITE) {
      set_error(h, rc);
      return HILDEGARD_TLS_ERROR;
    }
  }
  h->handshaked = 1;
  return HILDEGARD_TLS_OK;
}

int hildegard_tls_read(hildegard_tls *h, void *buf, int len) {
  int n;
  if (h == NULL || !h->handshaked) return HILDEGARD_TLS_ERROR;
  n = mbedtls_ssl_read(&h->ssl, (unsigned char *)buf, (size_t)len);
  if (n > 0) return n;
  if (n == 0) return 0;
  if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE)
    return HILDEGARD_TLS_WOULD_BLOCK;
  if (n == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) return 0;
  set_error(h, n);
  return HILDEGARD_TLS_ERROR;
}

int hildegard_tls_write(hildegard_tls *h, const void *buf, int len) {
  int n;
  if (h == NULL || !h->handshaked) return HILDEGARD_TLS_ERROR;
  n = mbedtls_ssl_write(&h->ssl, (const unsigned char *)buf, (size_t)len);
  if (n >= 0) return n;
  if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE)
    return HILDEGARD_TLS_WOULD_BLOCK;
  set_error(h, n);
  return HILDEGARD_TLS_ERROR;
}

int hildegard_tls_pending(hildegard_tls *h) {
  if (h == NULL) return 0;
  return (int)mbedtls_ssl_get_bytes_avail(&h->ssl);
}

int hildegard_tls_close(hildegard_tls *h) {
  if (h == NULL) return HILDEGARD_TLS_ERROR;
  if (h->handshaked) {
    /* Best effort: a blocked close_notify must not hang the caller. */
    mbedtls_ssl_close_notify(&h->ssl);
    h->handshaked = 0;
  }
  return HILDEGARD_TLS_OK;
}

int hildegard_tls_last_error(hildegard_tls *h, char *buf, unsigned buflen) {
  if (h == NULL) return 0;
  if (buf != NULL && buflen > 0) {
    strncpy(buf, h->last_error_string, buflen - 1);
    buf[buflen - 1] = '\0';
  }
  return h->last_error;
}

int hildegard_sha256(const unsigned char *data, unsigned len,
                     unsigned char out[32]) {
  return mbedtls_sha256(data, len, out, 0) == 0 ? 0 : HILDEGARD_TLS_ERROR;
}
