module voltlib

import io
import json2
import net
import net.http
import time

struct Exchange {
	method   http.Method = .get
	path     string
	cookie   string = 'token=fixture-session'
	request  string
	status   string = '200 OK'
	location string
	response string
}

fn serve_exchanges(mut listener net.TcpListener, exchanges []Exchange) {
	defer { listener.close() or {} }
	for exchange in exchanges {
		mut connection := listener.accept() or { panic(err) }
		connection.set_read_timeout(5 * time.second)
		mut reader := io.new_buffered_reader(reader: connection)
		req := http.parse_request(mut reader) or { panic(err) }
		assert req.method == exchange.method
		assert req.url == '/api' + exchange.path
		assert (req.header.get(.cookie) or { '' }) == exchange.cookie
		assert (req.header.get(.accept) or { '' }) == 'application/json'
		if exchange.request != '' {
			assert (req.header.get(.content_type) or { '' }) == 'application/json'
			actual := json2.decode[map[string]json2.Any](req.data) or { panic(err) }
			expected := json2.decode[map[string]json2.Any](exchange.request) or { panic(err) }
			assert actual == expected
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

fn test_documented_api() {
	base_url, done := mock_server([
		Exchange{
			path:     '/me'
			response: '{"id":"42","name":"volt","display_name":"Volt User"}'
		},
		Exchange{
			path:     '/servers'
			response: '[{"id":13,"name":"test"}]'
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
	assert client.me()!.id == '42'
	assert client.servers()![0].name == 'test'
	assert client.server(13)!.is_community
	assert client.server_chats(13)![0].id == 10
	assert client.chat(10)!.server_id == 13
	assert client.dm_chats()![0].contact_nickname == 'Volt'
	all := client.all_chats()!
	assert all.servers[0].id == 13
	assert all.all_chats.len == 2
	assert all.conversations[0].cleared_id == 99
	messages := client.messages(10)!
	assert messages[0].time == i64(2147483648)
	assert messages[0].reactions[0].user_ids == [42]
	assert client.messages(10, before: 101)!.len == 0
	assert client.messages(10, after: 101, before: 999)!.len == 0
	sent := client.send_message(10, 'A "quoted" Volt ⚡\nmessage',
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
	if _ := client.send_message(10, 'hello') {
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
