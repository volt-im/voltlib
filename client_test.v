module voltlib

import encoding.base64
import io
import json2
import net
import net.http
import os
import time

struct Exchange {
	method        http.Method = .get
	prefix        string      = '/api'
	path          string
	cookie        string = 'token=fixture-session'
	authorization string
	request       string
	status        string = '200 OK'
	location      string
	response      string
	check_request ?fn (http.Request)
}

fn serve_exchanges(mut listener net.TcpListener, exchanges []Exchange) {
	defer { listener.close() or {} }
	for exchange in exchanges {
		mut connection := listener.accept() or { panic(err) }
		connection.set_read_timeout(5 * time.second)
		mut reader := io.new_buffered_reader(reader: connection)
		req := http.parse_request(mut reader) or { panic(err) }
		assert req.method == exchange.method
		assert req.url == exchange.prefix + exchange.path
		assert (req.header.get(.cookie) or { '' }) == exchange.cookie
		assert (req.header.get(.authorization) or { '' }) == exchange.authorization
		assert (req.header.get(.accept) or { '' }) == 'application/json'
		if exchange.request != '' {
			assert (req.header.get(.content_type) or { '' }) == 'application/json'
			actual := json2.decode[map[string]json2.Any](req.data) or { panic(err) }
			expected := json2.decode[map[string]json2.Any](exchange.request) or { panic(err) }
			assert actual == expected
		}
		if check_request := exchange.check_request {
			check_request(req)
		}
		location := if exchange.location != '' { 'Location: ${exchange.location}\r\n' } else { '' }
		connection.write_string('HTTP/1.1 ${exchange.status}\r\nContent-Type: application/json\r\nContent-Length: ${exchange.response.len}\r\n${location}Connection: close\r\n\r\n${exchange.response}') or {
			panic(err)
		}
		connection.close() or { panic(err) }
	}
}

fn mock_server(exchanges []Exchange) !(string, thread) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	listener.set_accept_timeout(5 * time.second)
	base_url := 'http://127.0.0.1:${listener.addr()!.port()!}'
	done := spawn serve_exchanges(mut listener, exchanges)
	return base_url, done
}

fn test_client_configuration() {
	client := new('fixture-session')!
	assert client.base_url == 'https://app.volt.im'
	assert client.cookie_name == '__Host-volt-token'
	assert !client.str().contains(client.session_token())
	assert new('fixture-session', base_url: 'https://app.volt.im:443/')!.cookie_name == '__Host-volt-token'
	assert new('fixture-session', base_url: 'https://volt.im/')!.cookie_name == 'token'

	for invalid in ['volt.im', 'https://volt.im/api', 'https://volt.im/#api', 'https://name@volt.im',
		'https://volt.im/?'] {
		if _ := new('fixture-session', base_url: invalid) {
			assert false, 'accepted invalid base URL ${invalid}'
		}
	}
	if _ := new('fixture-session; extra=cookie') {
		assert false, 'accepted more than one cookie'
	}
}

fn test_unbound_resource_returns_an_error() {
	server := Server{ id: 13 }
	if _ := server.chats() {
		assert false, 'fetched chats without a configured client'
	} else {
		assert err.msg() == 'Volt request requires a configured client'
	}
}

fn test_documented_api() {
	base_url, done := mock_server([
		Exchange{
			path:     '/me'
			response: '{"id":"42","name":"volt","display_name":"Volt User"}'
		},
		Exchange{
			path:     '/servers'
			response: '[{"id":13,"name":"test","chats":[{"id":10}]}]'
		},
		Exchange{
			path:     '/servers/13'
			response: '{"id":13,"long_name":"Test Server","is_community":true}'
		},
		Exchange{
			path:     '/servers/13/chats'
			response: '[{"id":10,"name":"general","server_id":13}]'
		},
		Exchange{
			path:     '/chats/10'
			response: '{"id":10,"server_id":13}'
		},
		Exchange{
			path:     '/me/chats'
			response: '[{"id":11,"contact_nickname":"Volt"}]'
		},
		Exchange{
			path:     '/allchats'
			response: '{"servers":[{"id":13}],"all_chats":[{"id":10},{"id":11}],"conversations":[{"chat_id":11,"cleared_id":99}]}'
		},
		Exchange{
			path:     '/servers/13/chats'
			response: '[{"id":10}]'
		},
		Exchange{
			path:     '/chats/11/messages'
			response: '[]'
		},
		Exchange{
			path:     '/chats/10/messages'
			response: '[{"id":101,"time":2147483648,"reactions":[{"name":"⚡","count":1,"user_ids":[42]}]}]'
		},
		Exchange{
			path:     '/chats/10/messages?before=101'
			response: '[]'
		},
		Exchange{
			path:     '/chats/10/messages?after=101'
			response: '[]'
		},
		Exchange{
			method:   .post
			path:     '/chats/10/messages'
			request:  r'{"text":"A \"quoted\" Volt ⚡\nmessage","client_id":"send-1","reply_to_id":101}'
			response: '{"id":102,"chat_id":10,"client_id":"send-1","reply_to_id":101}'
		},
	])!
	client := new('fixture-session', base_url: base_url + '/')!
	me := client.me()!
	assert me.id == '42'
	servers := client.servers()!
	assert servers[0].name == 'test'
	server := client.server(13)!
	assert server.is_community
	channels := server.chats()!
	assert channels[0].id == 10
	chat := client.chat(10)!
	assert chat.server_id == 13
	dms := me.chats()!
	assert dms[0].contact_nickname == 'Volt'
	all := me.all_chats()!
	assert all.servers[0].id == 13
	assert all.all_chats.len == 2
	assert all.conversations[0].cleared_id == 99
	assert !'${all}'.contains(client.session_token())
	assert !json2.encode(all).contains('"client":')
	assert all.servers[0].chats()![0].id == chat.id
	assert dms[0].messages()!.len == 0
	messages := channels[0].messages()!
	assert messages[0].time == i64(2147483648)
	assert messages[0].reactions[0].user_ids == [42]
	assert chat.messages(before: 101)!.len == 0
	assert all.all_chats[0].messages(after: 101, before: 999)!.len == 0
	sent := servers[0].chats[0].send_message('A "quoted" Volt ⚡\nmessage',
		client_id:   'send-1'
		reply_to_id: 101
	)!
	assert sent.id == 102
	assert sent.reply_to_id == 101
	done.wait()
}

fn test_authentication_and_errors() {
	base_url, done := mock_server([
		Exchange{
			method:   .post
			path:     '/auth'
			cookie:   ''
			request:  '{"username":"volt","password":"good-password"}'
			response: '{"token":"fixture-session"}'
		},
		Exchange{
			path:     '/me/encryption'
			response: '{}'
		},
		Exchange{
			method:   .post
			path:     '/auth'
			cookie:   ''
			request:  '{"username":"volt","password":"bad-password"}'
			response: '{"error":"bad credentials"}'
		},
		Exchange{
			path:     '/me'
			status:   '401 Unauthorized'
			response: '{"status":"fail","text":"not authorized"}'
		},
		Exchange{
			path:     '/chats/10'
			response: '{"id":10,"bot_id":7,"user1_id":42,"user2_id":-7}'
		},
		Exchange{
			method:   .post
			path:     '/chats/10/messages'
			request:  '{"text":"hello"}'
			status:   '429 Too Many Requests'
			response: '{"chat_id":10,"remaining_ms":1234}'
		},
		Exchange{
			path:     '/me'
			status:   '302 Found'
			location: 'http://127.0.0.1:1/'
		},
		Exchange{
			path:     '/me'
			response: '<html>Unexpected page</html>'
		},
		Exchange{
			path:     '/emotes'
			cookie:   ''
			response: '["wave"]'
		},
	])!
	client := login('volt', 'good-password', base_url: base_url)!
	assert client.session_token() == 'fixture-session'
	if _ := login('volt', 'bad-password', base_url: base_url) {
		assert false, 'accepted failed login'
	} else {
		assert err is ApiError
		assert err.code() == 200
		assert err.msg().contains('bad credentials')
	}
	if _ := client.me() {
		assert false, 'accepted unauthorized request'
	} else {
		assert err.code() == 401
		assert err.msg().contains('not authorized')
	}
	chat := client.chat(10)!
	if _ := chat.send_message('hello') {
		assert false, 'accepted rate-limited send'
	} else {
		assert err.code() == 429
		assert (err as ApiError).remaining_ms == 1234
	}
	if _ := client.me() {
		assert false, 'accepted redirect'
	} else {
		assert err.code() == 302
	}
	if _ := client.me() {
		assert false, 'accepted invalid JSON'
	} else {
		assert err.msg().contains('/api/me')
	}
	assert new('', base_url: base_url)!.emotes()! == ['wave']
	done.wait()
}

struct EncryptionVectors {
	password        string
	salt            string
	enc_private_key string
	enc_public_key  string
	wrapped         string
	raw             string
	message         string
}

// This fixture was generated with WebCrypto for the Volt native-client tests.
fn encryption_vectors() !EncryptionVectors {
	return json2.decode[EncryptionVectors](os.read_file(os.join_path(@DIR, 'testdata',
		'e2ee_vectors.json'))!)
}

fn test_webcrypto_message_and_private_key() {
	vectors := encryption_vectors()!
	private_key := unlock_private_key(vectors.password, vectors.salt, vectors.enc_private_key)!
	raw := private_key.unwrap(vectors.wrapped)!
	assert base64.encode(raw) == vectors.raw
	envelope := parse_message_envelope(vectors.message)!
	assert envelope.epoch == 3
	assert envelope.open(raw)! == 'Привет, Volt! 👋'
	assert parse_message_envelope(encrypt_text('hello ⚡', raw, 3)!)!.open(raw)! == 'hello ⚡'
	legacy := parse_message_envelope(vectors.message.replace(',"epoch":3', '').replace('"', '&quot;'))!
	assert legacy.epoch == 0
	assert legacy.open(raw)! == 'Привет, Volt! 👋'
	if _ := envelope.open([]u8{len: aes_key_size}) {
		assert false, 'accepted ciphertext with the wrong key'
	}
	if _ := unlock_private_key(vectors.password + 'x', vectors.salt, vectors.enc_private_key) {
		assert false, 'unlocked account with the wrong password'
	}
}

fn test_encrypted_chat_initialization_and_rotation() {
	vectors := encryption_vectors()!
	private_key := unlock_private_key(vectors.password, vectors.salt, vectors.enc_private_key)!
	raw := base64.decode(vectors.raw)
	keys := json2.encode({
		'42': vectors.wrapped
		'43': vectors.wrapped
	})
	recipients := [
		EncryptionRecipient{ id: 42, enc_public_key: vectors.enc_public_key },
		EncryptionRecipient{ id: 43, enc_public_key: vectors.enc_public_key },
	]
	info := ChatEncryption{ chat_id: 12, enc_epoch: 3, enc_keys: keys, users: recipients }
	current := ChatEncryption{
		...info
		enc_epoch:       4
		enc_key_history: json2.encode({
			'3': keys
		})
	}
	confirmed := Message{ id: 5, text: encrypt_text('Original confirmation', raw, 4)! }
	page := [
		Message{ id: 3, text: 'Older plaintext' },
		Message{ id: 4, text: vectors.message },
		confirmed,
		Message{ id: 6, text: encrypt_text('future key', raw, 5)! },
		Message{ id: 7, text: 'enc:v1:broken' },
	]
	base_url, done := mock_server([
		Exchange{
			method:   .post
			path:     '/auth'
			cookie:   ''
			response: '{"token":"fixture-session"}'
		},
		Exchange{
			path:     '/me/encryption'
			response: json2.encode(AccountEncryption{
				user_id:         42
				enc_private_key: vectors.enc_private_key
				enc_key_salt:    vectors.salt
			})
		},
		Exchange{
			path:     '/chats/12'
			response: '{"id":12,"user1_id":42,"user2_id":43}'
		},
		Exchange{
			path:     '/chats/12/encryption'
			response: json2.encode(ChatEncryption{ ...info, enc_keys: '' })
		},
		Exchange{
			method:        .post
			path:          '/chats/12/encryption'
			check_request: fn [private_key] (req http.Request) {
				body := json2.decode[SaveChatKeys](req.data) or { panic(err) }
				assert req.data.contains('"expected_keys":""')
				assert body.expected_keys == ''
				assert body.enc_epoch == 3
				created := decode_key_map(body.enc_keys) or { panic(err) }
				assert created.len == 2
				assert created['42'] != created['43']
				assert private_key.unwrap(created['42'])! == private_key.unwrap(created['43'])!
			}
			status:        '409 Conflict'
			response:      '{"status":"fail","text":"Chat keys changed; retry"}'
		},
		Exchange{
			path:     '/chats/12/encryption'
			response: json2.encode(info)
		},
		Exchange{
			method:        .post
			path:          '/chats/12/messages'
			check_request: fn [raw] (req http.Request) {
				assert !req.data.contains('Hello DM')
				body := json2.decode[SendMessageRequest](req.data) or { panic(err) }
				assert body.client_id == 'fixture-send'
				assert body.text.starts_with(encrypted_prefix)
				envelope := parse_message_envelope(body.text) or { panic(err) }
				assert envelope.epoch == 3
				assert envelope.open(raw)! == 'Hello DM'
			}
			status:        '409 Conflict'
			response:      '{"status":"fail","code":"CHAT_KEY_CHANGED","text":"Channel encryption changed; retry"}'
		},
		Exchange{
			path:     '/chats/12/encryption'
			response: json2.encode(current)
		},
		Exchange{
			method:        .post
			path:          '/chats/12/messages'
			check_request: fn [raw] (req http.Request) {
				body := json2.decode[SendMessageRequest](req.data) or { panic(err) }
				assert body.client_id == 'fixture-send'
				envelope := parse_message_envelope(body.text) or { panic(err) }
				assert envelope.epoch == 4
				assert envelope.open(raw)! == 'Hello DM'
			}
			response:      json2.encode(confirmed)
		},
		Exchange{
			path:     '/chats/12/messages'
			response: json2.encode(page)
		},
		Exchange{
			path:     '/chats/12/encryption'
			response: json2.encode(current)
		},
		Exchange{
			path:     '/chats/12/messages'
			response: json2.encode(page)
		},
	])!
	client := login('volt', vectors.password, base_url: base_url)!
	assert client.encryption_unlocked()
	assert !json2.encode(client).contains('fixture-session')
	assert !json2.encode(client).contains('"encryption"')
	chat := client.chat(12)!
	sent := chat.send_message('Hello DM', client_id: 'fixture-send')!
	assert sent.id == 5
	assert sent.text == 'Original confirmation'
	messages := chat.messages()!
	assert messages[0].text == 'Older plaintext'
	assert messages[1].text == 'Привет, Volt! 👋'
	assert messages[2].text == 'Original confirmation'
	assert messages[3].text == page[3].text
	assert messages[3].decryption_error.contains('no key')
	assert messages[4].decryption_error.contains('Invalid')
	assert chat.raw_messages()![1].text == vectors.message
	done.wait()
}

fn test_unlock_separate_encryption_key() {
	vectors := encryption_vectors()!
	info := json2.encode(AccountEncryption{
		user_id:               42
		enc_private_key:       vectors.enc_private_key
		enc_key_salt:          vectors.salt
		enc_uses_separate_key: true
	})
	base_url, done := mock_server([
		Exchange{ method: .post, path: '/auth', cookie: '', response: '{"token":"fixture-session"}' },
		Exchange{ path: '/me/encryption', response: info },
		Exchange{ path: '/me/encryption', response: info },
		Exchange{ path: '/chats/12/messages', response: json2.encode([Message{ text: vectors.message }]) },
	])!
	locked := login('volt', 'sign-in-password', base_url: base_url)!
	assert !locked.encryption_unlocked()
	chat := Chat{ client: locked, id: 12, user1_id: 42, user2_id: 43 }
	if _ := chat.send_message('must stay local') {
		assert false, 'sent a DM without unlocking encryption'
	} else {
		assert err.msg().contains('Unlock')
	}
	unlocked := locked.unlock_encryption(vectors.password)!
	assert unlocked.encryption_unlocked()
	messages := chat.messages()!
	assert messages[0].text == vectors.message
	assert messages[0].decryption_error.contains('Unlock')
	done.wait()
}

const fixture_bot_token = 'voltbot_fixture'

fn bot_exchange(path string, request string, response string) Exchange {
	return Exchange{
		method:        .post
		prefix:        '/bot'
		path:          path
		cookie:        ''
		authorization: 'Bearer ' + fixture_bot_token
		request:       request
		response:      response
	}
}

fn test_direct_bot_chats() {
	bot_chat := '{"id":42,"type":"private","first_name":"Volt User","username":"volt"}'
	user := '{"id":8,"username":"volt","first_name":"Volt User","is_bot":false}'
	incoming := '{"message_id":123,"date":1710000000,"from":${user},"chat":${bot_chat},"text":"Hello bot"}'
	bot_user := '{"id":9,"username":"examplebot","first_name":"Example","is_bot":true}'
	outgoing := '{"message_id":124,"from":${bot_user},"chat":${bot_chat},"text":"Hello from the bot","reply_to_message_id":123}'
	edited := '{"message_id":124,"from":${bot_user},"chat":${bot_chat},"text":"Edited","edit_date":1710000001}'
	base_url, done := mock_server([
		Exchange{
			method:   .post
			path:     '/bots/examplebot/chat'
			response: '{"id":42,"bot_id":9,"user1_id":8}'
		},
		Exchange{
			method:   .post
			path:     '/chats/42/messages'
			request:  '{"text":"Hello bot"}'
			response: '{"id":123,"text":"Hello bot"}'
		},
		bot_exchange('/getUpdates', '{"offset":0,"limit":10}',
			'{"ok":true,"result":[{"update_id":3000000000,"inline_query":{"id":"3000000000","from":${user},"query":"find","offset":"next"}},{"update_id":3000000001,"message":${incoming}},{"update_id":3000000002,"callback_query":{"id":"3000000002","from":${user},"message":${outgoing},"chat_instance":"42","data":"confirm"}}]}'),
		bot_exchange('/sendMessage',
			'{"chat_id":42,"text":"Hello from the bot","client_id":"answer-123","reply_parameters":{"message_id":123},"reply_markup":{"inline_keyboard":[[{"text":"Confirm","callback_data":"confirm"}]]}}',
			'{"ok":true,"result":${outgoing}}'),
		bot_exchange('/getChat', '{"chat_id":42}', '{"ok":true,"result":${bot_chat}}'),
		bot_exchange('/editMessageText', '{"chat_id":42,"message_id":124,"text":"Edited"}',
			'{"ok":true,"result":${edited}}'),
		bot_exchange('/deleteMessage', '{"chat_id":42,"message_id":124}', '{"ok":true,"result":true}'),
		bot_exchange('/getUpdates', '{"offset":3000000003,"limit":100}', '{"ok":true,"result":[]}'),
	])!
	client := new('fixture-session', base_url: base_url)!
	user_chat := client.open_bot_chat('ExampleBot')!
	assert user_chat.bot_id == 9
	assert user_chat.send_message('Hello bot')!.id == 123
	bot := new_bot(fixture_bot_token, base_url: base_url)!
	assert !'${bot}'.contains(fixture_bot_token)
	assert !json2.encode(bot).contains(fixture_bot_token)
	updates := bot.updates(limit: 10)!
	assert updates.len == 3
	assert updates[0].inline_query?.query == 'find'
	message := updates[1].message?
	assert message.sender.username == 'volt'
	assert message.date == 1710000000
	assert message.chat.type == 'private'
	callback := updates[2].callback_query?
	assert callback.data == 'confirm'
	assert callback.message.chat.id == message.chat.id
	reply := message.chat.send_message('Hello from the bot',
		reply_to_message_id: message.message_id
		client_id:           'answer-123'
		reply_markup:        BotReplyMarkup{
			inline_keyboard: [[BotKeyboardButton{ text: 'Confirm', callback_data: 'confirm' }]]
		}
	)!
	assert reply.sender.is_bot
	assert reply.reply_to_message_id == message.message_id
	assert bot.chat(message.chat.id)!.first_name == 'Volt User'
	result := reply.edit_text('Edited')!
	assert result.edit_date == 1710000001
	assert result.delete()!
	assert bot.updates(offset: updates.last().update_id + 1)!.len == 0
	done.wait()
}

fn test_bot_api_errors() {
	closed := bot_exchange('/getChat', '{"chat_id":42}',
		'{"ok":false,"error_code":403,"description":"Chat is closed"}')
	base_url, done := mock_server([
		Exchange{ ...closed, status: '403 Forbidden' },
		bot_exchange('/getUpdates', '{"offset":0,"limit":100}',
			'{"ok":false,"error_code":429,"description":"Try again later"}'),
		bot_exchange('/getUpdates', '{"offset":0,"limit":100}', '{"ok":true}'),
	])!
	bot := new_bot(fixture_bot_token, base_url: base_url)!
	if _ := bot.chat(42) {
		assert false, 'accepted a closed bot chat'
	} else {
		assert err is BotApiError
		assert (err as BotApiError).status_code == 403
		assert (err as BotApiError).description == 'Chat is closed'
	}
	if _ := bot.updates() {
		assert false, 'accepted a failed bot response'
	} else {
		assert err.code() == 429
		assert (err as BotApiError).status_code == 200
	}
	if _ := bot.updates() {
		assert false, 'accepted a missing bot result'
	} else {
		assert err.msg().contains('Missing result')
	}
	if _ := new_bot('token with spaces') {
		assert false, 'accepted an invalid bot token'
	}
	if _ := new('fixture-session')!.open_bot_chat('../examplebot') {
		assert false, 'accepted an invalid bot username'
	}
	done.wait()
}
