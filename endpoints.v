module voltlib

import json2

pub fn (client Client) me() !User {
	user := client.request_json[User](.get, '/me', '')!
	return User{
		...user
		client: client
	}
}

pub fn (client Client) servers() ![]Server {
	servers := client.request_json[[]Server](.get, '/servers', '')!
	return servers.map(it.with_client(client))
}

pub fn (client Client) server(server_id int) !Server {
	server := client.request_json[Server](.get, '/servers/${server_id}', '')!
	return server.with_client(client)
}

fn (server Server) with_client(client Client) Server {
	return Server{
		...server
		client: client
		chats:  bind_chats(server.chats, client)
	}
}

// chats fetches the accessible channels in this server.
pub fn (server Server) chats() ![]Chat {
	chats := server.client.request_json[[]Chat](.get, '/servers/${server.id}/chats', '')!
	return bind_chats(chats, server.client)
}

pub fn (client Client) chat(chat_id int) !Chat {
	chat := client.request_json[Chat](.get, '/chats/${chat_id}', '')!
	return Chat{
		...chat
		client: client
	}
}

fn bind_chats(chats []Chat, client Client) []Chat {
	return chats.map(Chat{
		...it
		client: client
	})
}

// chats fetches the authenticated user's direct message chats.
pub fn (user User) chats() ![]Chat {
	chats := user.client.request_json[[]Chat](.get, '/me/chats', '')!
	return bind_chats(chats, user.client)
}

// all_chats fetches the authenticated user's servers and chats in one request.
pub fn (user User) all_chats() !ChatList {
	list := user.client.request_json[ChatList](.get, '/allchats', '')!
	return ChatList{
		...list
		servers:   list.servers.map(it.with_client(user.client))
		all_chats: bind_chats(list.all_chats, user.client)
	}
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
pub fn (chat Chat) messages(page MessagePage) ![]Message {
	query := if page.after > 0 {
		'?after=${page.after}'
	} else if page.before > 0 {
		'?before=${page.before}'
	} else {
		''
	}
	return chat.client.request_json[[]Message](.get, '/chats/${chat.id}/messages${query}', '')
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
pub fn (chat Chat) send_message(text string, options SendMessageOptions) !Message {
	body := json2.encode(SendMessageRequest{
		text:        text
		client_id:   options.client_id
		reply_to_id: options.reply_to_id
		thread_id:   options.thread_id
		bridge_text: options.bridge_text
	})
	return chat.client.request_json[Message](.post, '/chats/${chat.id}/messages', body)
}
