module voltlib

import crypto.rand
import encoding.base64
import json2
import net.mbedtls as _

#flag -I @VEXEROOT/thirdparty/mbedtls/include
#flag -I @VEXEROOT/thirdparty/mbedtls/library
#include "@DIR/e2ee.h"

fn C.voltlib_e2ee_pbkdf2_sha256(password &u8, password_len int, salt &u8, salt_len int, iterations int, out &u8, out_len int) int
fn C.voltlib_e2ee_gcm_encrypt(key &u8, key_len int, iv &u8, iv_len int, input &u8, len int, out &u8) int
fn C.voltlib_e2ee_gcm_decrypt(key &u8, key_len int, iv &u8, iv_len int, input &u8, in_len int, out &u8) int
fn C.voltlib_e2ee_rsa_oaep_decrypt(n &u8, n_len int, e &u8, e_len int, d &u8, d_len int, p &u8, p_len int, q &u8, q_len int, input &u8, in_len int, out &u8, out_max int, out_len &int) int
fn C.voltlib_e2ee_rsa_oaep_encrypt(n &u8, n_len int, e &u8, e_len int, input &u8, in_len int, out &u8) int

const encrypted_prefix = 'enc:v1:'
const wrap_key_iterations = 210_000
const aes_key_size = 32
const gcm_nonce_size = 12
const gcm_tag_size = 16

struct EncryptedEnvelope {
	iv    string
	data  string
	epoch int
}

struct RsaJwk {
	kty string
	n   string
	e   string
	d   string
	p   string
	q   string
}

struct RsaPrivateKey {
	n []u8
	e []u8
	d []u8
	p []u8
	q []u8
}

fn (jwk RsaJwk) public_parts() !([]u8, []u8) {
	n := base64.url_decode(jwk.n)
	e := base64.url_decode(jwk.e)
	if jwk.kty != 'RSA' || n.len !in [256, 384, 512] || e.len == 0 || e.len > 8 {
		return error('Invalid Volt RSA key')
	}
	return n, e
}

fn unlock_private_key(material string, salt_text string, private_envelope string) !RsaPrivateKey {
	salt := base64.decode(salt_text)
	if salt.len == 0 {
		return error('Missing Volt encryption salt')
	}
	wrapping_key := []u8{len: aes_key_size}
	if C.voltlib_e2ee_pbkdf2_sha256(material.str, material.len, salt.data, salt.len,
		wrap_key_iterations, wrapping_key.data, wrapping_key.len) != 0 {
		return error('Could not derive the Volt encryption key')
	}
	envelope := json2.decode[EncryptedEnvelope](private_envelope) or {
		return error('Invalid Volt private key envelope')
	}
	plain := envelope.open(wrapping_key) or { return error('Could not unlock Volt encryption with this password or key') }
	jwk := json2.decode[RsaJwk](plain) or { return error('Invalid Volt private key') }
	n, e := jwk.public_parts()!
	key := RsaPrivateKey{
		n: n
		e: e
		d: base64.url_decode(jwk.d)
		p: base64.url_decode(jwk.p)
		q: base64.url_decode(jwk.q)
	}
	if key.d.len == 0 || key.d.len > n.len || key.p.len == 0 || key.q.len == 0
		|| key.p.len >= n.len || key.q.len >= n.len {
		return error('Invalid Volt private key')
	}
	return key
}

fn (key RsaPrivateKey) unwrap(wrapped string) ![]u8 {
	ciphertext := base64.decode(wrapped)
	if ciphertext.len != key.n.len {
		return error('Invalid wrapped Volt chat key')
	}
	out := []u8{len: aes_key_size}
	mut out_len := 0
	if C.voltlib_e2ee_rsa_oaep_decrypt(key.n.data, key.n.len, key.e.data, key.e.len, key.d.data,
		key.d.len, key.p.data, key.p.len, key.q.data, key.q.len, ciphertext.data,
		ciphertext.len, out.data, out.len, &out_len) != 0 || out_len != out.len {
		return error('Could not unwrap the Volt chat key')
	}
	return out
}

fn wrap_chat_key(public_key string, raw []u8) !string {
	jwk := json2.decode[RsaJwk](public_key) or { return error('Invalid Volt public key') }
	n, e := jwk.public_parts()!
	out := []u8{len: n.len}
	if C.voltlib_e2ee_rsa_oaep_encrypt(n.data, n.len, e.data, e.len, raw.data, raw.len,
		out.data) != 0 {
		return error('Could not wrap the Volt chat key')
	}
	return base64.encode(out)
}

fn encrypt_text(text string, key []u8, epoch int) !string {
	iv := rand.bytes(gcm_nonce_size)!
	out := []u8{len: text.len + gcm_tag_size}
	if C.voltlib_e2ee_gcm_encrypt(key.data, key.len, iv.data, iv.len, text.str, text.len,
		out.data) != 0 {
		return error('Could not encrypt the Volt message')
	}
	return encrypted_prefix + json2.encode(EncryptedEnvelope{
		iv:    base64.encode(iv)
		data:  base64.encode(out)
		epoch: epoch
	})
}

fn (envelope EncryptedEnvelope) open(key []u8) !string {
	iv := base64.decode(envelope.iv)
	data := base64.decode(envelope.data)
	if iv.len != gcm_nonce_size || data.len < gcm_tag_size {
		return error('Invalid Volt encryption envelope')
	}
	out := []u8{len: data.len - gcm_tag_size}
	if C.voltlib_e2ee_gcm_decrypt(key.data, key.len, iv.data, iv.len, data.data, data.len,
		out.data) != 0 {
		return error('Volt ciphertext authentication failed')
	}
	return out.bytestr()
}

fn parse_message_envelope(text string) !EncryptedEnvelope {
	body := text[encrypted_prefix.len..].replace_each([
		'&#34;',
		'"',
		'&quot;',
		'"',
		'&#39;',
		"'",
		'&amp;',
		'&',
		'&lt;',
		'<',
		'&gt;',
		'>',
		'&#43;',
		'+',
		'&#61;',
		'=',
	])
	envelope := json2.decode[EncryptedEnvelope](body) or {
		return error('Invalid Volt message encryption envelope')
	}
	if envelope.epoch < 0 {
		return error('Invalid Volt message encryption epoch')
	}
	return envelope
}
