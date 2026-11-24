# voltlib

A V client for the [Volt.im REST API](https://app.volt.im/docs/api). It uses
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
| `client.open_bot_chat(username)` | `POST /api/bots/:username/chat` |
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

## Encrypted direct messages

`chat.send_message(text)` takes plaintext and encrypts human DMs locally.
It creates and shares keys when a chat needs them and retries if Volt reports
a key change. Channels, groups, and bot chats use plaintext. Pass the same
`client_id` on retries to let Volt deduplicate a send.

`login(username, password)` unlocks existing account encryption when it uses
the sign-in password. When signing in with a token or using a separate
encryption key, unlock explicitly before fetching chats.

```v
locked := voltlib.new(session_token)!
client := locked.unlock_encryption(encryption_password_or_key)!
chat := client.chat(chat_id)!
sent := chat.send_message('Hello from V')!
println(sent.text)
```

Use `client.encryption_unlocked()` to check the unlock state. Accounts without
encryption keys can set them up by signing in to Volt once.

`chat.messages()` decrypts current and historical messages. An unreadable
message retains its ciphertext and reports the reason in
`message.decryption_error`. For apps that manage their own encryption,
`chat.raw_messages()` and `chat.send_raw_message(text)` use the server format.

## Direct bot chats

A signed-in user can open a bot conversation and send text with the regular
chat methods. The public **Start chat** button sends `/start`. [Volt direct bot chat docs](https://app.volt.im/docs/api#direct-bot-chats)

```v
client := voltlib.new(session_token)!
chat := client.open_bot_chat('examplebot')!
chat.send_message('Hello bot')!
```

On the bot side, use the token issued when you register the bot.
[Volt bot registration](https://app.volt.im/docs/api#register-bot)

```v
import os
import time
import voltlib

fn main() {
	bot := voltlib.new_bot(os.getenv('VOLT_BOT_TOKEN'))!
	mut offset := i64(0)
	for {
		updates := bot.updates(offset: offset)!
		for update in updates {
			if message := update.message {
				message.chat.send_message('Thanks for your message',
					reply_to_message_id: message.message_id
					client_id: 'reply-${update.update_id}'
				)!
			}
			offset = update.update_id + 1
		}
		if updates.len == 0 {
			time.sleep(time.second)
		}
	}
}
```

The polling offset acknowledges all earlier updates, including inline queries
and callback queries. Advance it after processing. A stable `client_id` lets
Volt deduplicate retried sends.

| Bot method | HTTP endpoint |
| --- | --- |
| `bot.updates(offset: offset, limit: 20)` | `POST /bot/getUpdates` |
| `bot.chat(chat_id)` | `POST /bot/getChat` |
| `chat.send_message(text, reply_to_message_id: id)` | `POST /bot/sendMessage` |
| `message.edit_text(text)` | `POST /bot/editMessageText` |
| `message.delete()` | `POST /bot/deleteMessage` |

If you have a stored message ID, use `chat.edit_message_text(id, text)` or
`chat.delete_message(id)`.

## Errors

HTTP failures return `voltlib.ApiError` with `status_code` and `detail`.
For channel slow mode, `remaining_ms` gives the time until the next send.
Volt can also return sign-in failures with HTTP status 200, so check the error
returned by `login()` regardless of status.
Bot API failures return `voltlib.BotApiError` with `status_code`,
`error_code`, and `description`.

## Test

Run `v test .` from the module checkout. Tests use a local fixture HTTP server
and Volt's WebCrypto test vectors. Encryption uses the mbedTLS bundled with V.
