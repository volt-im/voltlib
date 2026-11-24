module voltlib

import json2
import net.http
import net.urllib

pub const default_base_url = 'https://app.volt.im'

@[params]
pub struct ClientOptions {
pub:
	base_url string = default_base_url
}

pub struct Client {
	token       string @[skip]
	cookie_name string
	encryption  ?EncryptionIdentity @[skip]
pub:
	base_url string
}

// new creates a client with an existing session token. An empty token creates
// an anonymous client.
pub fn new(token string, options ClientOptions) !Client {
	origin := parse_volt_origin(options.base_url)!
	for byte in token {
		if byte < 0x21 || byte > 0x7e || byte in [`"`, `,`, `;`, `\\`] {
			return error('Invalid Volt session token')
		}
	}
	host := origin.hostname().trim_right('.').to_lower()
	return Client{
		base_url:    '${origin.scheme}://${origin.host}'
		token:       token
		cookie_name: if host == 'app.volt.im' { '__Host-volt-token' } else { 'token' }
	}
}

fn parse_volt_origin(base_url string) !urllib.URL {
	trimmed := base_url.trim_right('/')
	origin := urllib.parse(trimmed) or { return error('Invalid Volt base URL') }
	if origin.scheme !in ['http', 'https'] || origin.hostname() == '' || origin.path != ''
		|| trimmed.contains_any('@?#') {
		return error('Volt base URL must be an HTTP or HTTPS origin')
	}
	return origin
}

// str returns the client origin with credentials omitted.
pub fn (client Client) str() string {
	return 'voltlib.Client(${client.base_url})'
}

// session_token returns the credential for callers that need to persist it.
pub fn (client Client) session_token() string {
	return client.token
}

// login signs in and unlocks account encryption when it uses this password.
pub fn login(username string, password string, options ClientOptions) !Client {
	client := new('', options)!
	body := json2.encode(LoginRequest{
		username: username
		password: password
	})
	response := client.request(.post, '/auth', body)!
	result := json2.decode[AuthResponse](response.body) or {
		return error('Invalid Volt API response for POST /api/auth')
	}
	if result.error != '' || result.token == '' {
		return ApiError{
			status_code: response.status_code
			detail:      if result.error != '' { result.error } else { 'Missing session token' }
		}
	}
	signed_in := new(result.token, options)!
	info := signed_in.account_encryption() or { return signed_in }
	if info.enc_uses_separate_key {
		return signed_in
	}
	return signed_in.unlock_account(info, password) or { signed_in }
}

struct LoginRequest {
	username string
	password string
}

struct AuthResponse {
	token string
	error string
}

// ApiError reports a failed Volt response. status_code is the HTTP status,
// including 200 when /api/auth returns a login error in a successful response.
pub struct ApiError {
	Error
pub:
	status_code  int
	api_code     string
	detail       string
	remaining_ms i64 // Set when a send is limited by channel slow mode.
}

pub fn (err ApiError) msg() string {
	return 'Volt API HTTP ${err.status_code} — ${err.detail}'
}

pub fn (err ApiError) code() int {
	return err.status_code
}

struct ErrorResponse {
	code         string
	text         string
	error        string
	remaining_ms i64
}

fn (client Client) request(method http.Method, path string, data string) !http.Response {
	mut header := http.Header{}
	if client.token != '' {
		header.set(.cookie, '${client.cookie_name}=${client.token}')
	}
	response := fetch_volt_response(client.base_url, method, '/api' + path, data, mut header)!
	if response.status_code >= 200 && response.status_code < 300 {
		return response
	}
	body := json2.decode[ErrorResponse](response.body) or { ErrorResponse{} }
	detail := if body.error != '' {
		body.error
	} else if body.text != '' {
		body.text
	} else if body.remaining_ms > 0 {
		'Channel slow mode'
	} else {
		http.status_from_int(response.status_code).str()
	}
	return ApiError{
		status_code:  response.status_code
		api_code:     body.code
		detail:       detail
		remaining_ms: body.remaining_ms
	}
}

fn fetch_volt_response(base_url string, method http.Method, path string, data string, mut header http.Header) !http.Response {
	if base_url == '' {
		return error('Volt request requires a configured client')
	}
	header.set(.accept, 'application/json')
	if data != '' {
		header.set(.content_type, 'application/json')
	}
	return http.fetch(
		url:            base_url + path
		method:         method
		header:         header
		data:           data
		allow_redirect: false
		max_retries:    1
	)
}

fn (client Client) request_json[T](method http.Method, path string, data string) !T {
	response := client.request(method, path, data)!
	return json2.decode[T](response.body) or {
		return error('Invalid Volt API response for ${method} /api${path}')
	}
}
