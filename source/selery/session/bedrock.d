/*
 * Copyright (c) 2017-2018 SEL
 * 
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU Lesser General Public License for more details.
 * 
 */
module selery.session.bedrock;

import core.atomic : atomicOp;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;

import std.algorithm : canFind, min;
static import std.array;
import std.base64 : Base64, Base64URL;
import std.bitmanip : read;
import std.conv : to, ConvException;
import std.datetime : dur;
import std.json;
import std.math : ceil;
import std.path : dirSeparator;
import std.random : uniform;
import std.regex : matchFirst, ctRegex;
import std.socket : Socket, UdpSocket, Address, InternetAddress, Internet6Address;
import std.string;
import std.system : Endian;
import std.uuid : UUID;
import std.zlib;

import sel.hncom.about;
import sel.hncom.login : HubInfo;
import sel.hncom.player : HncomAdd = Add;

import selery.about;
import selery.constants;
import selery.hub.server : HubServer;
import selery.network.handler : UnconnectedHandler;
import selery.network.session;
import selery.session.player : PlayerSession, Skin;
import selery.util.thread : SafeThread;
import selery.util.util : milliseconds;

import sul.utils.var : varuint;

import Types = sul.protocol.raknet8.types;
import Control = sul.protocol.raknet8.control;
import Unconnected = sul.protocol.raknet8.unconnected;
import Encapsulated = sul.protocol.raknet8.encapsulated;

mixin("import sul.protocol.bedrock" ~ newestBedrockProtocol.to!string ~ ".play : Login, PlayStatus, Disconnect;"); //TODO disconnect packet may change between different protocols

private __gshared pure ubyte[] function(string)[uint] _create_disconnect;
private __gshared pure uint function(ubyte[])[uint] _handle_request_chunk_radius;
private __gshared uint[uint] _request_chunk_radius_id;

shared static this() {

	foreach(protocol ; SupportedBedrockProtocols) {
		mixin("import sul.protocol.bedrock" ~ protocol.to!string ~ ".play : Disconnect, RequestChunkRadius;");
		_create_disconnect[protocol] = (string message) pure { return new Disconnect(false, message).encode(); };
		_handle_request_chunk_radius[protocol] = (ubyte[] buffer) pure { return RequestChunkRadius.fromBuffer(buffer).radius; };
		_request_chunk_radius_id[protocol] = RequestChunkRadius.ID;
	}

}

enum ubyte[16] magic = [0x00, 0xFF, 0xFF, 0x00, 0xFE, 0xFE, 0xFE, 0xFE, 0xFD, 0xFD, 0xFD, 0xFD, 0x12, 0x34, 0x56, 0x78];

@property Types.Address raknetAddress(Address address) {
	auto ret = Types.Address(4);
	if(cast(InternetAddress)address) {
		auto v4 = cast(InternetAddress)address;
		ret.type = 4;
		ret.ipv4 = v4.addr ^ uint.max;
		ret.port = v4.port;
	} else if(cast(Internet6Address)address) {
		// not yet supported by the client
		auto v6 = cast(Internet6Address)address;
		ret.type = 6;
		ret.ipv6 = v6.addr;
	}
	return ret;
}

class BedrockHandler : UnconnectedHandler {
	
	private shared string* socialJson;
	
	private shared string[2] status; // ["MCPE;motd;protocol;version;", ";server_id;world_name;gametype;"]

	private shared int[session_t]* querySessions;
	
	private shared ubyte[]* shortQuery, longQuery;

	private shared BedrockSession[session_t] sessions;
	
	private __gshared Mutex mutex;
	private __gshared Condition condition;
	
	public this(shared HubServer server, shared string* socialJson, shared int[session_t]* querySessions, shared ubyte[]* shortQuery, shared ubyte[]* longQuery) {
		with(server.config.hub.bedrock) super(server, createSockets!UdpSocket(server, "bedrock", addresses, port, -1), POCKET_BUFFER_SIZE);
		this.socialJson = socialJson;
		this.querySessions = querySessions;
		this.shortQuery = shortQuery;
		this.longQuery = longQuery;
		(cast(shared)this).reload();
	}
		
	protected override void run() {
		this.condition = new Condition(this.mutex = new Mutex());
		new SafeThread(this.server.config.lang, &this.timeout).start();
		//new SafeThread(this.server.config.lang, &this.decompression).start();
		super.run();
	}
	
	protected override void onReceived(Socket socket, Address address, ubyte[] payload) {
		session_t code = Session.code(address);
		shared BedrockSession* session = code in this.sessions;
		if(session) {
			(*session).handle(payload);
		} else {
			switch(payload[0]) {
				case Unconnected.Ping.ID:
					auto ping = Unconnected.Ping.fromBuffer(payload);
					this.sendTo(socket, new Unconnected.Pong(ping.pingId, this.server.id, magic, this.status[0] ~ to!string(this.server.onlinePlayers) ~ ";" ~ (this.server.maxPlayers==HubInfo.UNLIMITED ? "9999999" : to!string(this.server.maxPlayers)) ~ this.status[1]).encode(), address);
					break;
				case Unconnected.OpenConnectionRequest1.ID:
					auto ocr = Unconnected.OpenConnectionRequest1.fromBuffer(payload);
					//TODO check magic and protocol
					this.sendTo(socket, new Unconnected.OpenConnectionReply1(magic, this.server.id, false, cast(ushort)ocr.mtu.length).encode(), address);
					break;
				case Unconnected.OpenConnectionRequest2.ID:
					auto ocr = Unconnected.OpenConnectionRequest2.fromBuffer(payload);
					if(ocr.mtuLength < POCKET_BUFFER_SIZE && ocr.mtuLength > 500) {
						this.sendTo(socket, new Unconnected.OpenConnectionReply2(magic, this.server.id, raknetAddress(address), ocr.mtuLength, false).encode(), address);
						this.sessions[code] = new shared BedrockSession(this.server, code, this, socket, address, ocr.mtuLength);
					}
					break;
				case 253:
					// social json!
					this.sendTo(socket, *this.socialJson, address);
					break;
				case 254:
					// query
					if(this.server.config.hub.query && payload.length >= 7 && payload[1] == 253) {
						switch(payload[2]) {
							case 0:
								// query
								ubyte[] header = payload[2..7]; // id, session
								if(payload.length >= 11 && code in (*this.querySessions)) {
									payload = payload[7..$];
									if((*this.querySessions)[code] == read!int(payload)) {
										this.sendTo(socket, header ~ (payload.length == 4 ? (*this.longQuery) : (*this.shortQuery)), address);
									}
								}
								break;
							case 9:
								// login
								int s = uniform(0, 16777216);
								(*this.querySessions)[code] = s;
								this.sendTo(socket, payload[2..7] ~ cast(ubyte[])to!string(s) ~ cast(ubyte[])[0], address);
								break;
							default:
								break;
						}
					}
					break;
				default:
					//TODO do something bad to it
					break;
			}
		}
	}
	
	private void timeout() {
		Thread.getThis().name = "bedrockHandler" ~ dirSeparator ~ "timeout";
		while(true) {
			Thread.sleep(dur!"seconds"(1));
			foreach(shared BedrockSession session ; this.sessions) {
				session.checkTimeout();
			}
		}
	}
	
	private shared BedrockSession[] toDecompress;
	
	public shared void decompress(shared BedrockSession session) {
		this.toDecompress ~= session;
		synchronized(this.mutex) {
			this.condition.notify();
		}
	}
	
	private void decompression() {
		Thread.getThis().name = "bedrockHandler" ~ dirSeparator ~ "decompression";
		while(true) {
			if(this.toDecompress.length) {
				shared BedrockSession session = this.toDecompress[0];
				this.toDecompress = this.toDecompress[1..$];
				session.decompressQueue();
			} else {
				synchronized(this.mutex) {
					this.condition.wait();
				}
			}
		}
	}
	
	public shared void removeSession(shared BedrockSession session) {
		this.sessions.remove(session.code);
		delete session;
	}

	public override shared void reload() {
		with(this.server.config.hub.bedrock) {
			this.status = [
				std.array.join([
					"MCPE",
					motd,
					to!string(protocols[$-1]),
					supportedBedrockProtocols[protocols[$-1]][0],
					""
				], ";"),
				std.array.join([
					"",
					to!string(this.server.id),
					Software.display,
					Software.lname,
					""
				], ";")
			];
		}
	}
	
}

final class BedrockSession : PlayerSession {

	public immutable session_t code;

	private shared BedrockHandler handler;
	private shared Socket socket;

	private shared size_t timeoutTicks = 0;

	private ushort mtu;

	private void delegate(ubyte[]) shared functionHandler;

	private bool edu = false;

	private JSONValue additional_data;

	private shared ubyte nextUpdate;

	private shared uint[] pings;
	private shared int pingPacket = -1;
	private shared ulong pingTime = 0;

	private shared float n_packet_loss = 0f;
	private shared size_t lostPackets;
	private shared size_t totalPackets;

	// only used for the login packet
	private shared bool acceptSplit;
	private shared ubyte[][] splits;
	private shared size_t splitsCount;

	private shared uint sendCount = 0;

	private shared uint receiveCount; // expecting packet with id $receiveCount
	private shared uint[] missedPackets;

	private shared ubyte[][uint] waitingAcks;

	private shared ushort sendSplits;

	private shared ubyte[][] decompressionQueue;
	private shared Thread decompressionThread;

	public shared this(shared HubServer server, session_t code, BedrockHandler handler, Socket socket, Address address, ushort mtu) {
		super(server);
		this.code = code;
		this.handler = cast(shared)handler;
		this.socket = cast(shared)socket;
		this.n_address = cast(shared)address;
		this.mtu = mtu;
		this.functionHandler = &this.handleClientConnect;
	}

	public override shared nothrow @property @safe @nogc immutable(ubyte) type() {
		return __BEDROCK__;
	}

	public override shared nothrow @property @safe @nogc immutable(uint) latency() {
		uint num = 0;
		if(this.pings.length) {
			foreach(uint ping ; this.pings) {
				num += ping;
			}
			num /= this.pings.length;
		}
		return num;
	}

	public override shared nothrow @property @safe @nogc immutable(float) packetLoss() {
		return this.n_packet_loss;
	}

	public override shared JSONValue hncomAddData() {
		return this.additional_data;
	}

	public shared void checkTimeout() {
		atomicOp!"+="(this.timeoutTicks, 1);
		if(this.timeoutTicks >= POCKET_TIMEOUT) {
			this.encapsulate(new Disconnect(false, "disconnect.timeout"));
			this.onTimedOut();
		}
		atomicOp!"+="(this.nextUpdate, 1);
		if(this.nextUpdate == 10) {
			this.nextUpdate = 0;
			this.n_packet_loss = this.lostPackets.to!float / this.totalPackets * 100;
			this.lostPackets = 0;
			this.totalPackets = 0;
			this.sendLatency();
			this.sendPacketLoss();
		}
	}

	/**
	 * Handles raw data received from the client.
	 * The only packets that could be received are
	 * acks, nacks and encapsulated packets.
	 */
	public shared void handle(ubyte[] payload) {
		// handle ACKs, NACKs and encapsulated
		switch(payload[0]) {
			case Control.Ack.ID:
				this.handle(Control.Ack.fromBuffer(payload));
				break;
			case Control.Nack.ID:
				this.handle(Control.Nack.fromBuffer(payload));
				break;
			case 128:..case 143:
				this.handle(Control.Encapsulated.fromBuffer(payload));
				break;
			default:
				// disconnect or something (add fail)
				// this could also happen when two clients are using
				// the same ip:port combination
				break;
		}
	}

	private shared void handle(Control.Ack ack) {
		uint[] packets = acknowledgePackets(ack.packets);
		atomicOp!"+="(this.totalPackets, packets.length);
		foreach(uint packet ; packets) {
			this.waitingAcks.remove(packet);
			if(packet == this.pingPacket) {
				this.pings ~= cast(uint)(milliseconds - this.pingTime);
				if(this.pings.length > 16) this.pings = this.pings[1..$];
				this.pingPacket = -1;
				break;
			}
		}
	}

	private shared void handle(Control.Nack nack) {
		uint[] packets = acknowledgePackets(nack.packets);
		atomicOp!"+="(this.lostPackets, packets.length);
		atomicOp!"+="(this.totalPackets, packets.length);
		foreach(uint packet ; packets) {
			auto ptr = packet in this.waitingAcks;
			if(ptr) {
				this.send(cast(ubyte[])*ptr);
			}
		}
	}

	private shared void handle(Control.Encapsulated encapsulated) {
		
		// send ack, even if the packet is duplicated
		this.send(new Control.Ack([Types.Acknowledge(true, encapsulated.count)]).encode());

		if(encapsulated.count < this.receiveCount) {
			if(this.missedPackets.canFind(encapsulated.count)) {
				// remove it from missed packets
				foreach(i, missed; this.missedPackets) {
					if(missed == encapsulated.count) {
						this.missedPackets = this.missedPackets[0..i] ~ this.missedPackets[i+1..$];
						break;
					}
				}
			} else {
				// duplicated
				return;
			}
		} else {
			if(this.receiveCount != encapsulated.count) {
				// missed some packets
				foreach(uint missed ; this.receiveCount..encapsulated.count) {
					this.missedPackets ~= missed;
				}
				this.send(new Control.Nack([Types.Acknowledge(this.receiveCount==encapsulated.count-1, this.receiveCount, encapsulated.count-1)]).encode());
			}
			this.receiveCount = encapsulated.count + 1;
		}
		
		ubyte[] payload = encapsulated.encapsulation.payload;

		if(encapsulated.encapsulation.info & 16) {
			auto split = encapsulated.encapsulation.split;
			if(this.acceptSplit && split.id == 0) {
				// only a splitted packet should be sent in the whole session (login)
				if(this.splits.length == 0) {
					this.splits.length = split.count;
				} else if(split.count != this.splits.length) {
					this.addFail();
					return;
				}
				if(this.splits[split.order].length == 0) {
					this.splits[split.order] = cast(shared ubyte[])payload;
					payload.length = 0;
					atomicOp!"+="(this.splitsCount, 1);
					if(this.splitsCount == this.splits.length) {
						foreach(s ; this.splits) {
							payload ~= s;
						}
					}
				} else {
					// duplicated?
					payload.length = 0;
				}
			} else {
				this.addFail();
				return;
			}
		}

		if(payload.length) {
			switch(payload[0]) {
				case Encapsulated.Ping.ID:
					this.timeoutTicks = 0;
					this.encapsulate(new Encapsulated.Pong(Encapsulated.Ping.fromBuffer(payload).time), false);
					this.pingPacket = this.sendCount - 1;
					this.pingTime = milliseconds;
					break;
				case Encapsulated.ClientCancelConnection.ID:
					this.onClosedByClient();
					break;
				default:
					this.functionHandler(payload);
					break;
			}
		}
	}

	private shared void handleFail(ubyte[] payload) {
		this.addFail();
	}

	private shared void handleClientConnect(ubyte[] payload) {
		if(payload[0] == Encapsulated.ClientConnect.ID) {
			auto cc = Encapsulated.ClientConnect.fromBuffer(payload);
			auto sh = new Encapsulated.ServerHandshake(raknetAddress(cast()this.address), this.mtu);
			sh.pingId = cc.pingId;
			sh.serverId = this.server.id;
			this.encapsulate(sh, false);
			this.functionHandler = &this.handleClientHandshake;
		} else {
			this.addFail();
		}
	}

	private shared void handleClientHandshake(ubyte[] payload) {
		if(payload[0] == Encapsulated.ClientHandshake.ID) {
			this.functionHandler = &this.handleLogin;
			this.acceptSplit = true;
		} else {
			this.addFail();
		}
	}

	private shared void handleLogin(ubyte[] payload) {
		switch(payload[0]) {
			case Encapsulated.Mcpe.ID: // 0.15+ container
				if(payload.length) {
					// from 1.1 it's always compressed
					try {
						auto p = readBatch(payload[1..$]);
						if(p.length == 1) {
							auto login = p[0];
							if(login.length > 0 && login[0] == Login.ID) {
								this.handleLogin(Login.fromBuffer(login));
							}
						}
					} catch(ZlibException e) {
						// before 1.1, disconnect as outdated client
						this.encapsulate(cast(ubyte[])[254, 2, 0, 0, 0, 1], false);
						this.close();
					}
				} else {
					this.close();
				}
				break;
			case 142: // 0.14 container
				this.encapsulate(cast(ubyte[])[142, 144, 0, 0, 0, 1], false);
				this.close();
				break;
			case 143: // 0.12 and 0.13 login
			case 146: // 0.12 and 0.13 batch
				this.encapsulate(cast(ubyte[])[144, 0, 0, 0, 1], false);
				this.close();
				break;
			case 130: // 0.8, 0.9 and 0.10 login
			case 177: // 0.11 login
				this.encapsulate(cast(ubyte[])[131, 0, 0, 0, 1], false);
				this.close();
				break;
			default:
				this.close();
				break;
		}
	}

	private shared void handlePlay(ubyte[] payload) {
		if(payload[0] == Encapsulated.Mcpe.ID && payload.length > 1) {
			try {
				//TODO decompress in another thread
				foreach(packet ; readBatch(payload[1..$])) {
					this.handleUncompressedPlay(packet);
				}
			} catch(ZlibException) {
				this.close();
			}
		} else {
			this.addFail();
		}
	}

	private shared void handleUncompressedPlay(ubyte[] payload) {
		if(payload.length && this.n_node !is null) {
			this.n_node.sendTo(this, payload);
		}
	}

	public shared void decompressQueue() {
		while(this.decompressionQueue.length) {
			//TODO handle exception
			shared ubyte[] scompressed = this.decompressionQueue[0];
			ubyte[] compressed = cast(ubyte[])scompressed;
			this.decompressionQueue = this.decompressionQueue[1..$];
			try {
				UnCompress uc = new UnCompress(HeaderFormat.determineFromData);
				ubyte[] packet = cast(ubyte[])uc.uncompress(compressed);
				packet ~= cast(ubyte[])uc.flush();
				while(packet.length) {
					size_t length = varuint.fromBuffer(packet);
					if(length && length <= packet.length) {
						this.handleUncompressedPlay(packet[0..length]);
						packet = packet[length..$];
					}
				}
			} catch(ZlibException) {}
		}
	}

	private shared void handleLogin(Login login) {
		bool accepted = false;
		//this.edu = login.vers == Login.EDUCATION;
		this.n_protocol = login.protocol;
		auto protocols = this.server.config.hub.bedrock.protocols;
		if(this.n_protocol > protocols[$-1]) this.encapsulateUncompressed(new PlayStatus(PlayStatus.OUTDATED_SERVER));
		else if(!protocols.canFind(this.n_protocol)) this.encapsulateUncompressed(new PlayStatus(PlayStatus.OUTDATED_CLIENT));
		else {
			this.n_version = supportedBedrockProtocols[this.n_protocol][0];
			this.functionHandler = &this.handleFail;
			this.acceptSplit = false;
			// kick if the server is edu and the client is not
			if(this.server.config.hub.edu) { //TODO optimise this control
				auto error = (){
					if(!this.edu && !this.server.config.hub.allowVanillaPlayers) return PlayStatus.EDITION_MISMATCH_EDU_TO_VANILLA;
					//TODO implement invalidTenant
					else return PlayStatus.OK;
				}();
				if(error != PlayStatus.OK) {
					this.encapsulateUncompressed(new PlayStatus(error));
					this.close();
					return;
				}
			}
			// valid version and protocol
			accepted = true;
			this.encapsulateUncompressed(new PlayStatus(PlayStatus.OK));
			// the skin decoding is kinda slow (~8 ms) and it needs to be done in a dedicated thread
			new Thread({
				bool valid = false;
				try {

					JSONValue[] chain = parseJSON(cast(string)login.body_.chain).object["chain"].array;
					auto info = decodeJwt(chain[$-1].str.split(".")[1]);

					/*static if(__onlineMode) {
						if(chain.length != 3) throw new Exception("disconnectionScreen.notAuthenticated");
						//TODO validate JWTs using Mojang's public key and kick if invalid
						throw new Exception("disconnect.loginFailed");
					}*/

					// basic info
					string username = info.object["extraData"].object["displayName"].str;
					UUID uuid = UUID(info.object["extraData"].object["identity"].str);

					// check username (even if it's authenticated through XBOX live)
					if(username.length < 1 || username.length > 15 || username.matchFirst(ctRegex!"[^a-zA-Z0-9 ]") || username[0] == ' ' || username[$-1] == ' ') throw new Exception("disconnectionScreen.invalidName");
					
					// skin
					auto cd = decodeJwt((cast(string)login.body_.clientData).split(".")[1]).object;
					string skinName = cd["SkinId"].str;
					ubyte[] skinData = Base64.decode(cd["SkinData"].str);
					if(!skinName.length || (skinData.length != 8192 && skinData.length != 16384)) throw new Exception("disconnectionScreen.invalidSkin");
					auto capeData = "CapeData" in cd;
					auto geometryName = "SkinGeometryName" in cd;
					auto geometryData = "SkinGeometry" in cd;
					this.n_skin = cast(shared)new Skin(skinName, skinData, geometryName ? geometryName.str : "", geometryData ? Base64.decode(geometryData.str) : [], capeData ? Base64.decode(capeData.str) : []);

					cd.remove("SkinId");
					cd.remove("SkinData");
					cd.remove("CapeData");
					cd.remove("SkinGeometryName");
					cd.remove("SkinGeometry");

					auto serverAddress = "ServerAddress" in cd;
					auto vers = "GameVersion" in cd;
					auto lang = "LanguageCode" in cd;
					// TenantId for edu

					if(serverAddress && serverAddress.type == JSON_TYPE.STRING) {
						auto spl = serverAddress.str.split(":");
						if(spl.length >= 2) {
							try {
								this.n_server_address = spl[0..$-1].join(":");
								this.n_server_port = to!ushort(spl[$-1]);
							} catch(ConvException) {}
						}
					}
					if(vers && vers.type == JSON_TYPE.STRING) {
						// verify major.minor.patch[.build]
						auto spl = vers.str.split(".");
						if(spl.length >= 3) {
							spl.length = 3;
							try {
								foreach(num ; spl) to!ubyte(num);
								// verify that the client's version exists
								immutable playerVersion = spl.join(".");
								foreach(v ; supportedBedrockProtocols[this.protocol]) {
									if(v.startsWith(playerVersion) || playerVersion.startsWith(v)) {
										this.n_version = playerVersion;
										break;
									}
								}
							} catch(ConvException) {}
						}
					}
					with(this.server.config.hub) this.language = acceptedLanguages.canFind(lang.str) ? lang.str : "en_GB";

					cd.remove("ServerAddress");
					cd.remove("LanguageCode");

					cd["edu"] = this.edu;

					this.additional_data = JSONValue(cd);

					// check whitelist and blacklist with username and UUID (if authenticated)
					if(this.server.config.hub.whitelist) {
						with(this.server.whitelist) {
							bool v = contains(username);
							//static if(__onlineMode) v = v || contains(PE, uuid);
							if(!v) throw new Exception("disconnectionScreen.notAllowed"); // You're not invited to play on this server
						}
					}
					if(this.server.config.hub.blacklist) {
						with(this.server.blacklist) {
							bool v = !contains(username);
							//static if(__onlineMode) v = v && contains(PE, uuid);
							if(!v) throw new Exception("You're not allowed to play on this server.");
						}
					}

					// check if there's free space in the server
					if(this.server.full) {
						throw new Exception("disconnectionScreen.serverFull.title");
					}

					// check if it's already online
					/*static if(__onlineMode) {
						ubyte[] idf = this.suuid.dup;
					} else {*/
						ubyte[] idf = cast(ubyte[])username.toLower;
					//}
					if(this.server.playerFromIdentifier(idf) !is null) {
						throw new Exception("disconnectionScreen.loggedinOtherLocation");
					}

					this.n_username = this.m_display_name = username.idup;
					cast()this.n_uuid = uuid;

					this.n_game_name = "Minecraft" ~ (this.edu ? ": Education Edition" : "");

					// try to connect a node
					valid = true;
					this.functionHandler = &this.handlePlay;
					this.firstConnect();

				} catch(Throwable t) {
					this.encapsulateUncompressed(new Disconnect(false, t.msg));
				}
				if(!valid) this.close();
				
			}).start();
		}
		if(!accepted) this.close();
	}

	private shared void addFail() {
	}

	public shared override ptrdiff_t send(const(void)[] data) {
		return this.handler.sendTo(cast()this.socket, data, this.n_address);
	}

	public shared void encapsulate(ubyte[] payload, bool play=true) {
		if(play) payload = [cast(ubyte)254] ~ payload;
		if(payload.length > this.mtu) {
			uint count = ceil(payload.length.to!float / this.mtu).to!uint;
			uint sizes = ceil(payload.length.to!float / count).to!uint;
			foreach(uint order ; 0..count) {
				ubyte[] buffer = payload[order*sizes..min((order+1)*sizes, $)];
				auto split = Types.Split(count, this.sendSplits, order);
				auto encapsulation = Types.Encapsulation(16 + 64, cast(ushort)(buffer.length * 8), this.sendCount, 0, ubyte.init, split, buffer);
				ubyte[] packet = new Control.Encapsulated(this.sendCount, encapsulation).encode();
				packet[0] = 140;
				this.waitingAcks[this.sendCount] = cast(shared ubyte[])packet;
				this.send(packet);
				atomicOp!"+="(this.sendCount, 1);
			}
			atomicOp!"+="(this.sendSplits, 1);
		} else {
			ubyte[] packet = new Control.Encapsulated(this.sendCount, Types.Encapsulation(64, cast(ushort)(payload.length * 8), this.sendCount, 0, ubyte.init, Types.Split.init, payload)).encode();
			this.waitingAcks[this.sendCount] = cast(shared ubyte[])packet;
			this.send(packet);
			atomicOp!"+="(this.sendCount, 1);
		}
	}

	public shared void encapsulate(T)(T packet, bool play=true) if(is(typeof(T.encode))) {
		this.encapsulate(packet.encode(), play);
	}

	public shared void encapsulateUncompressed(T)(T packet) {
		this.encapsulate(writeBatch([packet.encode()]), true);
	}

	/**
	 * The node only uses packets that are in Protocol.Play.
	 * These packets are encapsulated into an MCPE container and
	 * sent to the client.
	 */
	public override shared void sendFromNode(ubyte[] payload) {
		this.encapsulate(payload);
	}

	protected override shared void endOfStream() {
		this.encapsulateUncompressed(new Disconnect(false, "disconnect.endOfStream"));
		this.close();
	}

	public override shared void kick(string reason, bool translation, string[] params) {
		this.encapsulateUncompressed(new Disconnect(false, reason));
		this.close();
	}

	protected override shared void close() {
		super.close();
		this.handler.removeSession(this);
	}

	public shared string toString() {
		return "PocketSession(" ~ to!string(this.id) ~ ", " ~ to!string(cast()this.address) ~ ", " ~ to!string(this.mtu) ~ ")";
	}

}

private ubyte[][] readBatch(ubyte[] data) {
	auto u = new UnCompress(HeaderFormat.deflate);
	data = cast(ubyte[])u.uncompress(data);
	data ~= cast(ubyte[])u.flush();
	ubyte[][] ret;
	size_t length, index;
	while((length = varuint.decode(data, &index)) >= 3 && length <= data.length - index) {
		ret ~= (data[index..index+1] ~ data[index+3..index+length]); // the id is a little-endian triad now?
		index += length;
	}
	return ret;
}

private ubyte[] writeBatch(ubyte[][] packets) {
	ubyte[] ret;
	foreach(packet ; packets) {
		packet = packet[0] ~ new ubyte[2] ~ packet[1..$];
		ret ~= varuint.encode(to!uint(packet.length)) ~ packet;
	}
	// packet compressed using this function should be small
	auto c = new Compress(1, HeaderFormat.deflate);
	ret = cast(ubyte[])c.compress(ret);
	ret ~= cast(ubyte[])c.flush();
	return ret;
}

private uint[] acknowledgePackets(Types.Acknowledge[] acks) {
	uint[] packets;
	foreach(ack ; acks) {
		if(ack.unique) {
			packets ~= ack.first;
		} else {
			foreach(packet ; ack.first..ack.last+1) {
				packets ~= packet;
			}
		}
	}
	return packets;
}

private JSONValue decodeJwt(string encoded) {
	while(encoded.length % 4 != 0) encoded ~= "=";
	return parseJSON(cast(string)Base64URL.decode(encoded));
}
