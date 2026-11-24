module voltlib

import crypto.rand
import json2

struct EncryptionIdentity {
	user_id int
	key     RsaPrivateKey
}

struct AccountEncryption {
	user_id               int
	enc_private_key       string
	enc_key_salt          string
	enc_uses_separate_key bool
}

// encryption_unlocked reports whether this client can open encrypted messages.
pub fn (client Client) encryption_unlocked() bool {
	return client.encryption != none
}

// unlock_encryption returns a client unlocked with the account's password or
// separate encryption key. Fetch users and chats with the returned client.
pub fn (client Client) unlock_encryption(material string) !Client {
	info := client.account_encryption()!
	return client.unlock_account(info, material)
}

fn (client Client) account_encryption() !AccountEncryption {
	return client.request_json[AccountEncryption](.get, '/me/encryption', '')
}

fn (client Client) unlock_account(info AccountEncryption, material string) !Client {
	if info.user_id <= 0 || info.enc_private_key == '' || info.enc_key_salt == '' {
		return error('Set up account encryption in Volt before unlocking this client')
	}
	if material == '' {
		return error('Enter the Volt encryption password or key')
	}
	key := unlock_private_key(material, info.enc_key_salt, info.enc_private_key)!
	return Client{
		...client
		encryption: EncryptionIdentity{
			user_id: info.user_id
			key:     key
		}
	}
}

struct EncryptionRecipient {
	id             int
	enc_public_key string
}

struct ChatEncryption {
	chat_id         int
	enc_epoch       int
	enc_keys        string
	enc_key_history string
	users           []EncryptionRecipient
}

struct ChatKey {
	epoch int
	bytes []u8
}

struct SaveChatKeys {
	enc_keys      string
	expected_keys string
	enc_epoch     int
}

fn (chat Chat) encryption_snapshot() !ChatEncryption {
	info := chat.client.request_json[ChatEncryption](.get, '/chats/${chat.id}/encryption', '')!
	if info.chat_id != chat.id || info.enc_epoch < 0 {
		return error('Invalid Volt chat encryption snapshot')
	}
	return info
}

fn decode_key_map(serialized string) !map[string]string {
	if serialized == '' {
		return map[string]string{}
	}
	return json2.decode[map[string]string](serialized) or { return error('Invalid Volt encryption key map') }
}

fn (chat Chat) current_chat_key() !ChatKey {
	identity := chat.client.encryption or {
		return error('Unlock Volt encryption to send messages to this chat')
	}
	user_id := identity.user_id.str()
	for attempt in 0 .. 3 {
		info := chat.encryption_snapshot()!
		mut keys := decode_key_map(info.enc_keys)!
		raw := if wrapped := keys[user_id] {
			identity.key.unwrap(wrapped)!
		} else if keys.len == 0 {
			rand.bytes(aes_key_size)!
		} else {
			return error('This Volt chat has not shared its key with your account')
		}
		original_count := keys.len
		for recipient in info.users {
			id := recipient.id.str()
			if recipient.enc_public_key != '' && id !in keys {
				keys[id] = wrap_chat_key(recipient.enc_public_key, raw)!
			}
		}
		if user_id !in keys {
			return error('Your account key is missing from this Volt chat')
		}
		if original_count != keys.len {
			body := json2.encode(SaveChatKeys{
				enc_keys:      json2.encode(keys)
				expected_keys: info.enc_keys
				enc_epoch:     info.enc_epoch
			})
			chat.client.request(.post, '/chats/${chat.id}/encryption', body) or {
				if err.code() == 409 && attempt < 2 {
					continue
				}
				return err
			}
		}
		return ChatKey{
			bytes: raw
			epoch: info.enc_epoch
		}
	}
	return error('Could not resolve the current Volt chat key')
}

struct DecryptionKey {
	bytes   []u8
	failure string
}

// The snapshot and unwrapped keys are shared within one response page.
struct MessageDecryptor {
	chat Chat
mut:
	snapshot       ?ChatEncryption
	snapshot_error string
	keys           map[int]DecryptionKey
}

fn (mut decoder MessageDecryptor) encryption_snapshot() !ChatEncryption {
	if info := decoder.snapshot {
		return info
	}
	if decoder.snapshot_error != '' {
		return error(decoder.snapshot_error)
	}
	info := decoder.chat.encryption_snapshot() or {
		decoder.snapshot_error = err.msg()
		return err
	}
	decoder.snapshot = info
	return info
}

fn (mut decoder MessageDecryptor) load_key(epoch int) ![]u8 {
	identity := decoder.chat.client.encryption or {
		return error('Unlock Volt encryption to read this message')
	}
	info := decoder.encryption_snapshot()!
	serialized := if epoch == info.enc_epoch {
		info.enc_keys
	} else {
		history := decode_key_map(info.enc_key_history)!
		history[epoch.str()] or { '' }
	}
	keys := decode_key_map(serialized)!
	wrapped := keys[identity.user_id.str()] or {
		return error('Your account has no key for this Volt message epoch')
	}
	return identity.key.unwrap(wrapped)
}

fn (mut decoder MessageDecryptor) open(envelope EncryptedEnvelope) !string {
	epoch := envelope.epoch
	if epoch !in decoder.keys {
		raw := decoder.load_key(epoch) or {
			decoder.keys[epoch] = DecryptionKey{ failure: err.msg() }
			return err
		}
		decoder.keys[epoch] = DecryptionKey{ bytes: raw }
	}
	key := decoder.keys[epoch]
	if key.failure != '' {
		return error(key.failure)
	}
	return envelope.open(key.bytes)
}

fn (mut decoder MessageDecryptor) decrypt(message Message) Message {
	if !message.text.starts_with(encrypted_prefix) {
		return message
	}
	plaintext := decoder.decrypt_text(message.text) or {
		return Message{
			...message
			decryption_error: err.msg()
		}
	}
	return Message{
		...message
		text: plaintext
	}
}

fn (mut decoder MessageDecryptor) decrypt_text(text string) !string {
	envelope := parse_message_envelope(text)!
	return decoder.open(envelope)
}
