# voltlib

A V client for the [Volt.im REST API](https://app.volt.im/#api). It uses
V's standard library and defaults to `https://app.volt.im`.

## Install

Clone the module alongside your project's `v.mod`.

```sh
git clone https://github.com/volt-im/voltlib.git voltlib
```

## Use

```v
import os
import voltlib

fn main() {
	token := os.getenv_opt('VOLT_TOKEN') or { panic('Set VOLT_TOKEN') }
	client := voltlib.new(token)!
	me := client.me()!
	println('Signed in as ${me.name}')

	for server in client.servers()! {
		for chat in server.chats()! {
			println('${server.name}/${chat.name}')
		}
	}

	dms := me.chats()!
	println('${dms.len} direct message chats')
}
```

Pass the cookie value as the token. The client chooses `__Host-volt-token`
for `app.volt.im` and `token` for other hosts. You can also obtain a session
with `voltlib.login(username, password)!`. Supply
`base_url: 'http://localhost:8077'` to either constructor to use a local
Volt server.

| Method | HTTP endpoint |
| --- | --- |
| `client.me()` | `GET /api/me` |
| `client.servers()` | `GET /api/servers` |
| `client.server(server_id)` | `GET /api/servers/:server_id` |
| `server.chats()` | `GET /api/servers/:server_id/chats` |
| `client.chat(chat_id)` | `GET /api/chats/:chat_id` |
| `me.chats()` | `GET /api/me/chats` |
| `me.all_chats()` | `GET /api/allchats` |
| `chat.messages(before: id)` | `GET /api/chats/:chat_id/messages` |
| `chat.send_message(text)` | `POST /api/chats/:chat_id/messages` |
| `client.emotes()` | `GET /api/emotes` (public) |

Servers and chats returned by the API use the client's session for follow-up
requests. With a known chat ID, use `chat := client.chat(chat_id)!`.
`chat.messages()` returns the latest page, up to 100 messages in ascending ID
order. Pass `before: id` to page backward or `after: id` to page forward. Both
cursors are exclusive.

Send plain text to channels. Direct messages require an encrypted `enc:v1:`
envelope. Provide that envelope as the message text when sending to a DM.
Received message text contains the original payload, including ciphertext for
encrypted DMs. Pass the same `client_id` on retries to let Volt deduplicate a
send.

HTTP failures return `voltlib.ApiError` with `status_code` and `detail`.
For channel slow mode, `remaining_ms` gives the time until the next send.
Volt can also return sign-in failures with HTTP status 200, so check the error
returned by `login()` regardless of status.

## Test

Run `v test .` from the module checkout. Tests use a local fixture HTTP server.
