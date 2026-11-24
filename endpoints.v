module voltlib

import json2

pub fn (client Client) me() !User {
	return client.request_json[User](.get, '/me', '')
}

pub fn (client Client) servers() ![]Server {
	return client.request_json[[]Server](.get, '/servers', '')
}

pub fn (client Client) server(server_id int) !Server {
	return client.request_json[Server](.get, '/servers/${server_id}', '')
}

pub fn (client Client) server_chats(server_id int) ![]Chat {
	return client.request_json[[]Chat](.get, '/servers/${server_id}/chats', '')
}

pub fn (client Client) chat(chat_id int) !Chat {
	return client.request_json[Chat](.get, '/chats/${chat_id}', '')
}

pub fn (client Client) dm_chats() ![]Chat {
	return client.request_json[[]Chat](.get, '/me/chats', '')
}

pub fn (client Client) all_chats() !ChatList {
	return client.request_json[ChatList](.get, '/allchats', '')
}

pub fn (client Client) emotes() ![]string {
	return client.request_json[[]string](.get, '/emotes', '')
}

@[params]
pub struct MessagePage {
pub:
	before int
	after  int
}

// messages returns up to 100 messages in ascending ID order. Cursors are
// exclusive. With both cursors supplied, the server gives after precedence.
pub fn (client Client) messages(chat_id int, page MessagePage) ![]Message {
	query := if page.after > 0 {
		'?after=${page.after}'
	} else if page.before > 0 {
		'?before=${page.before}'
	} else {
		''
	}
	return client.request_json[[]Message](.get, '/chats/${chat_id}/messages${query}', '')
}

@[params]
pub struct SendMessageOptions {
pub:
	client_id   string
	reply_to_id int
	thread_id   int
	bridge_text string
}

struct SendMessageRequest {
	text        string
	client_id   string @[omitempty]
	reply_to_id int    @[omitempty]
	thread_id   int    @[omitempty]
	bridge_text string @[omitempty]
}

// send_message posts text and returns the confirmed message. Provide a stable
// client_id to deduplicate a retry after an ambiguous network failure.
pub fn (client Client) send_message(chat_id int, text string, options SendMessageOptions) !Message {
	body := json2.encode(SendMessageRequest{
		text:        text
		client_id:   options.client_id
		reply_to_id: options.reply_to_id
		thread_id:   options.thread_id
		bridge_text: options.bridge_text
	})
	return client.request_json[Message](.post, '/chats/${chat_id}/messages', body)
}
