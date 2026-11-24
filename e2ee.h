// Volt end-to-end encryption primitives, matching the WebCrypto calls in
// static/volt.js: PBKDF2-SHA256 wrap keys, AES-256-GCM envelopes (ciphertext
// followed by the 16-byte tag) and RSA-OAEP-SHA256 chat key wrapping.
// Built on the mbedtls that V's net.mbedtls module already links for HTTPS.
#ifndef VOLTLIB_E2EE_H
#define VOLTLIB_E2EE_H

#include "entropy_poll.h"
#include "mbedtls/gcm.h"
#include "mbedtls/md.h"
#include "mbedtls/pkcs5.h"
#include "mbedtls/rsa.h"

#define VOLT_E2EE_TAG_LEN 16

static int voltlib_e2ee_rng(void *ctx, unsigned char *out, size_t len) {
	size_t written = 0;
	int ret = mbedtls_platform_entropy_poll(ctx, out, len, &written);
	return ret != 0 ? ret : (written == len ? 0 : -1);
}

static int voltlib_e2ee_pbkdf2_sha256(const unsigned char *password, int password_len,
		const unsigned char *salt, int salt_len, int iterations, unsigned char *out, int out_len) {
	return mbedtls_pkcs5_pbkdf2_hmac_ext(MBEDTLS_MD_SHA256, password, (size_t)password_len, salt,
		(size_t)salt_len, (unsigned int)iterations, (uint32_t)out_len, out);
}

// out must hold len + VOLT_E2EE_TAG_LEN bytes.
static int voltlib_e2ee_gcm_encrypt(const unsigned char *key, int key_len, const unsigned char *iv,
		int iv_len, const unsigned char *in, int len, unsigned char *out) {
	mbedtls_gcm_context gcm;
	mbedtls_gcm_init(&gcm);
	int ret = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, (unsigned int)key_len * 8);
	if (ret == 0) {
		ret = mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT, (size_t)len, iv, (size_t)iv_len,
			NULL, 0, in, out, VOLT_E2EE_TAG_LEN, out + len);
	}
	mbedtls_gcm_free(&gcm);
	return ret;
}

// in is ciphertext followed by the tag; out must hold in_len - VOLT_E2EE_TAG_LEN bytes.
static int voltlib_e2ee_gcm_decrypt(const unsigned char *key, int key_len, const unsigned char *iv,
		int iv_len, const unsigned char *in, int in_len, unsigned char *out) {
	if (in_len < VOLT_E2EE_TAG_LEN) {
		return -1;
	}
	size_t len = (size_t)(in_len - VOLT_E2EE_TAG_LEN);
	mbedtls_gcm_context gcm;
	mbedtls_gcm_init(&gcm);
	int ret = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, (unsigned int)key_len * 8);
	if (ret == 0) {
		ret = mbedtls_gcm_auth_decrypt(&gcm, len, iv, (size_t)iv_len, NULL, 0, in + len,
			VOLT_E2EE_TAG_LEN, in, out);
	}
	mbedtls_gcm_free(&gcm);
	return ret;
}

// Private key parts come big-endian, as a JWK's base64url fields decode.
static int voltlib_e2ee_rsa_oaep_decrypt(const unsigned char *n, int n_len, const unsigned char *e,
		int e_len, const unsigned char *d, int d_len, const unsigned char *p, int p_len,
		const unsigned char *q, int q_len, const unsigned char *in, int in_len, unsigned char *out,
		int out_max, int *out_len) {
	mbedtls_rsa_context rsa;
	mbedtls_rsa_init(&rsa);
	int ret = mbedtls_rsa_set_padding(&rsa, MBEDTLS_RSA_PKCS_V21, MBEDTLS_MD_SHA256);
	if (ret == 0) {
		ret = mbedtls_rsa_import_raw(&rsa, n, (size_t)n_len, p, (size_t)p_len, q, (size_t)q_len, d,
			(size_t)d_len, e, (size_t)e_len);
	}
	if (ret == 0) {
		ret = mbedtls_rsa_complete(&rsa);
	}
	if (ret == 0 && (size_t)in_len != mbedtls_rsa_get_len(&rsa)) {
		ret = -1;
	}
	size_t olen = 0;
	if (ret == 0) {
		ret = mbedtls_rsa_rsaes_oaep_decrypt(&rsa, voltlib_e2ee_rng, NULL, NULL, 0, &olen, in, out,
			(size_t)out_max);
	}
	*out_len = (int)olen;
	mbedtls_rsa_free(&rsa);
	return ret;
}

// out must hold n_len bytes.
static int voltlib_e2ee_rsa_oaep_encrypt(const unsigned char *n, int n_len, const unsigned char *e,
		int e_len, const unsigned char *in, int in_len, unsigned char *out) {
	mbedtls_rsa_context rsa;
	mbedtls_rsa_init(&rsa);
	int ret = mbedtls_rsa_set_padding(&rsa, MBEDTLS_RSA_PKCS_V21, MBEDTLS_MD_SHA256);
	if (ret == 0) {
		ret = mbedtls_rsa_import_raw(&rsa, n, (size_t)n_len, NULL, 0, NULL, 0, NULL, 0, e,
			(size_t)e_len);
	}
	if (ret == 0) {
		ret = mbedtls_rsa_complete(&rsa);
	}
	if (ret == 0) {
		ret = mbedtls_rsa_rsaes_oaep_encrypt(&rsa, voltlib_e2ee_rng, NULL, NULL, 0, (size_t)in_len, in,
			out);
	}
	mbedtls_rsa_free(&rsa);
	return ret;
}

#endif
