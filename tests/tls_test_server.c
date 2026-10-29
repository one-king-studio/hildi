/*
 * tls_test_server.c - see tls_test_server.h.
 *
 * Test-only. The certificate is generated in-process so no private key is
 * committed; it is never linked into a shipping binary.
 */
#include "tls_test_server.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "mbedtls/ctr_drbg.h"
#include "mbedtls/ecp.h"
#include "mbedtls/entropy.h"
#include "mbedtls/error.h"
#include "mbedtls/md.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/pem.h"
#include "mbedtls/pk.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"

#define CERT_PEM_MAX 4096

static int g_listen_fd = -1;
static int g_port = 0;
static int g_started = 0;
static pthread_t g_thread;
static char g_error[256] = "";
static char g_cert_pem[CERT_PEM_MAX];
static size_t g_cert_pem_len = 0;

static mbedtls_entropy_context g_entropy;
static mbedtls_ctr_drbg_context g_drbg;
static mbedtls_x509_crt g_crt;
static mbedtls_pk_context g_key;

static void set_error(const char *what, int rc) {
  if (rc < 0) {
    mbedtls_strerror(rc, g_error, sizeof(g_error));
    if (g_error[0] == '\0') snprintf(g_error, sizeof(g_error), "%s (%d)", what, rc);
  } else {
    snprintf(g_error, sizeof(g_error), "%s", what);
  }
}

/* Generate a self-signed localhost certificate and leave its PEM in
   g_cert_pem. Uses the file-scope g_drbg/g_crt/g_key. */
static int make_cert(void) {
  mbedtls_x509write_cert wc;
  mbedtls_x509_san_list san;
  unsigned char der[2048];
  unsigned char pem[CERT_PEM_MAX];
  size_t der_len, pem_len = 0;
  int rc;

  mbedtls_x509write_crt_init(&wc);
  rc = mbedtls_pk_setup(&g_key, mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY));
  if (rc) goto done;
  rc = mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1, mbedtls_pk_ec(g_key),
                           mbedtls_ctr_drbg_random, &g_drbg);
  if (rc) goto done;

  mbedtls_x509write_crt_set_subject_key(&wc, &g_key);
  mbedtls_x509write_crt_set_issuer_key(&wc, &g_key);
  rc = mbedtls_x509write_crt_set_subject_name(&wc, "CN=localhost");
  if (rc) goto done;
  rc = mbedtls_x509write_crt_set_issuer_name(&wc, "CN=localhost");
  if (rc) goto done;
  mbedtls_x509write_crt_set_version(&wc, MBEDTLS_X509_CRT_VERSION_3);
  mbedtls_x509write_crt_set_md_alg(&wc, MBEDTLS_MD_SHA256);
  rc = mbedtls_x509write_crt_set_validity(&wc, "20200101000000",
                                          "20301231235959");
  if (rc) goto done;
  /* CA:TRUE so the client can trust this self-signed cert as its own chain. */
  rc = mbedtls_x509write_crt_set_basic_constraints(&wc, 1, -1);
  if (rc) goto done;

  memset(&san, 0, sizeof(san));
  san.node.type = MBEDTLS_X509_SAN_DNS_NAME;
  san.node.san.unstructured_name.p = (unsigned char *)"localhost";
  san.node.san.unstructured_name.len = 9;
  rc = mbedtls_x509write_crt_set_subject_alternative_name(&wc, &san);
  if (rc) goto done;

  rc = mbedtls_x509write_crt_der(&wc, der, sizeof(der),
                                 mbedtls_ctr_drbg_random, &g_drbg);
  if (rc < 0) goto done;
  der_len = (size_t)rc; /* DER is right-aligned in the buffer */

  rc = mbedtls_pem_write_buffer("-----BEGIN CERTIFICATE-----\n",
                                "-----END CERTIFICATE-----\n",
                                der + sizeof(der) - der_len, der_len,
                                pem, sizeof(pem), &pem_len);
  if (rc) goto done;

  memcpy(g_cert_pem, pem, pem_len);
  g_cert_pem_len = pem_len;
  rc = mbedtls_x509_crt_parse(&g_crt, pem, pem_len);

done:
  mbedtls_x509write_crt_free(&wc);
  return rc;
}

static void *server_main(void *arg) {
  (void)arg;
  int conn_fd = -1;
  struct sockaddr_in cli;
  socklen_t cli_len = sizeof(cli);
  mbedtls_ssl_context ssl;
  mbedtls_ssl_config conf;
  mbedtls_net_context net;
  unsigned char buf[512];
  int rc, n;

  mbedtls_ssl_init(&ssl);
  mbedtls_ssl_config_init(&conf);

  rc = mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_SERVER,
                                   MBEDTLS_SSL_TRANSPORT_STREAM,
                                   MBEDTLS_SSL_PRESET_DEFAULT);
  if (rc) { set_error("config", rc); goto done; }
  mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &g_drbg);
  mbedtls_ssl_conf_ca_chain(&conf, NULL, NULL);
  rc = mbedtls_ssl_conf_own_cert(&conf, &g_crt, &g_key);
  if (rc) { set_error("own cert", rc); goto done; }
  rc = mbedtls_ssl_setup(&ssl, &conf);
  if (rc) { set_error("setup", rc); goto done; }

  conn_fd = accept(g_listen_fd, (struct sockaddr *)&cli, &cli_len);
  if (conn_fd < 0) { set_error("accept", -1); goto done; }
#if defined(SO_NOSIGPIPE)
  {
    int one = 1;
    setsockopt(conn_fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
  }
#endif

  net.fd = conn_fd;
  mbedtls_ssl_set_bio(&ssl, &net, mbedtls_net_send, mbedtls_net_recv, NULL);
  while ((rc = mbedtls_ssl_handshake(&ssl)) != 0) {
    if (rc != MBEDTLS_ERR_SSL_WANT_READ && rc != MBEDTLS_ERR_SSL_WANT_WRITE) {
      set_error("handshake", rc);
      goto done;
    }
  }
  /* Minimal HTTP/1.x: read the request, answer 200 with a fixed body. */
  n = mbedtls_ssl_read(&ssl, buf, sizeof(buf));
  if (n > 0) {
    static const char response[] =
        "HTTP/1.1 200 OK\r\n"
        "Content-Length: 5\r\n"
        "Connection: close\r\n"
        "\r\n"
        "hello";
    mbedtls_ssl_write(&ssl, (const unsigned char *)response,
                      sizeof(response) - 1);
  }
  mbedtls_ssl_close_notify(&ssl);

done:
  if (conn_fd >= 0) close(conn_fd);
  mbedtls_ssl_free(&ssl);
  mbedtls_ssl_config_free(&conf);
  return NULL;
}

int tls_test_server_start(void) {
  struct sockaddr_in addr;
  socklen_t alen;
  int one = 1, rc;

  g_error[0] = '\0';
  g_cert_pem_len = 0;

  /* A test write to a closed peer must not kill the whole test process. */
  signal(SIGPIPE, SIG_IGN);

  mbedtls_entropy_init(&g_entropy);
  mbedtls_ctr_drbg_init(&g_drbg);
  mbedtls_x509_crt_init(&g_crt);
  mbedtls_pk_init(&g_key);

  rc = mbedtls_ctr_drbg_seed(&g_drbg, mbedtls_entropy_func, &g_entropy,
                             (const unsigned char *)"hildi-test", 14);
  if (rc) { set_error("drbg seed", rc); return -1; }
  rc = make_cert();
  if (rc) { set_error("make cert", rc); return -1; }

  g_listen_fd = socket(AF_INET, SOCK_STREAM, 0);
  if (g_listen_fd < 0) { set_error("socket", -1); return -1; }
  setsockopt(g_listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;
  if (bind(g_listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    set_error("bind", -1);
    return -1;
  }
  alen = sizeof(addr);
  getsockname(g_listen_fd, (struct sockaddr *)&addr, &alen);
  g_port = ntohs(addr.sin_port);
  if (listen(g_listen_fd, 1) != 0) { set_error("listen", -1); return -1; }

  if (pthread_create(&g_thread, NULL, server_main, NULL) != 0) {
    set_error("thread", -1);
    return -1;
  }
  g_started = 1;
  return 0;
}

int tls_test_server_port(void) { return g_port; }

void tls_test_server_stop(void) {
  if (g_started) {
    pthread_join(g_thread, NULL);
    g_started = 0;
  }
  if (g_listen_fd >= 0) {
    close(g_listen_fd);
    g_listen_fd = -1;
  }
  mbedtls_x509_crt_free(&g_crt);
  mbedtls_pk_free(&g_key);
  mbedtls_ctr_drbg_free(&g_drbg);
  mbedtls_entropy_free(&g_entropy);
}

const char *tls_test_server_error(void) { return g_error; }

int tls_test_server_ca_pem(char *buf, unsigned buflen) {
  if (g_cert_pem_len == 0 || g_cert_pem_len > buflen) return -1;
  memcpy(buf, g_cert_pem, g_cert_pem_len);
  return (int)g_cert_pem_len;
}
