﻿/*
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
module selery.command.command;

import std.algorithm : all;
import std.conv : ConvException, to;
static import std.math;
import std.meta : staticIndexOf, Reverse;
import std.string : toLower, startsWith;
import std.traits : Parameters, ParameterDefaults, ParameterIdentifierTuple, hasUDA, getUDAs, isIntegral, isFloatingPoint;

import selery.command.args : StringReader, CommandArg;
import selery.command.util : PocketType, CommandSender, WorldCommandSender, Ranged, isRanged, Target, Position;
import selery.entity.entity : Entity;
import selery.event.node.command : CommandNotFoundEvent, CommandFailedEvent;
import selery.lang : Translation;
import selery.log : Format, Message;
import selery.node.server : ServerCommandSender;
import selery.player.player : Player;
import selery.plugin : Description;
import selery.util.messages : Messages;
import selery.util.tuple : Tuple;

struct CommandResult {

	// defaults
	enum SUCCESS = CommandResult(success);
	enum UNIMPLEMENTED = CommandResult(unimplemented);
	enum NOT_FOUND = CommandResult(notFound);
	enum INVALID_SYNTAX = CommandResult(invalidSyntax);

	enum : ubyte {

		success,

		notFound,

		unimplemented,
		invalidSyntax,
		invalidParameter,
		invalidNumber,
		invalidBoolean,
		targetNotPlayer,
		playerNotFound,
		targetNotFound,
		invalidRangeDown,
		invalidRangeUp

	}

	ubyte result = success;
	string[] args;

	string command;

	inout pure nothrow @property @safe @nogc bool successful() {
		return result == success;
	}

	/**
	 * Returns: whether the commands was successfully executed
	 */
	inout bool trigger(CommandSender sender) {
		if(this.result != success) {
			if(this.result == notFound) {
				//TODO call event with actual used command
				if(!(cast()sender.server).callCancellableIfExists!CommandNotFoundEvent(sender, this.command)) {
					if(cast(Player)sender) sender.sendMessage(Format.red, Translation(Messages.generic.notFound));
					else sender.sendMessage(Format.red, Translation(Messages.generic.notFoundConsole));
				}
			} else {
				//TODO call event with actual used command
				if(!(cast()sender.server).callCancellableIfExists!CommandFailedEvent(sender, sender.availableCommands.get(this.command, null))) {
					const message = (){
						final switch(result) with(Messages) {
							case unimplemented: return generic.notImplemented;
							case invalidSyntax: return generic.invalidSyntax;
							case invalidParameter: return generic.invalidParameter;
							case invalidNumber: return generic.numInvalid;
							case invalidBoolean: return generic.invalidBoolean;
							case targetNotPlayer: return generic.targetNotPlayer;
							case playerNotFound: return generic.playerNotFound;
							case targetNotFound: return generic.targetNotFound;
							case invalidRangeDown: return generic.numTooSmall;
							case invalidRangeUp: return generic.numTooBig;
						}
					}();
					sender.sendMessage(Format.red, Translation(message, this.args));
				}
			}
			return false;
		} else {
			return true;
		}
	}

}

class Command {

	/**
	 * Command's overload.
	 */
	public class Overload {

		enum : string {

			TARGET = "target",
			ENTITIES = "entities",
			PLAYERS = "players",
			PLAYER = "player",
			POSITION = "x y z",
			BOOL = "bool",
			INT = "int",
			FLOAT = "float",
			STRING = "string",
			UNKNOWN = "unknown"

		}

		/**
		 * Name of the parameters (name of the variables if not specified
		 * by the user).
		 */
		public string[] params;

		public abstract @property size_t requiredArgs();

		public abstract string typeOf(size_t i);

		public abstract PocketType pocketTypeOf(size_t i);

		public abstract string[] enumMembers(size_t i);

		public abstract bool callableBy(CommandSender sender);
		
		public abstract CommandResult callArgs(CommandSender sender, string args);
		
	}
	
	private class OverloadOf(C:CommandSender, bool implemented, E...) : Overload if(areValidArgs!(C, E[0..$/2])) {

		private alias Args = E[0..$/2];
		private alias Params = E[$/2..$];

		private enum size_t minArgs = staticIndexOf!(void, Params) != -1 ? (Params.length - staticIndexOf!(void, Reverse!Params)) : 0;

		public void delegate(C, Args) del;
		
		public this(void delegate(C, Args) del, string[] params) {
			this.del = del;
			this.params = params;
		}

		public override @property size_t requiredArgs() {
			return minArgs;
		}

		public override string typeOf(size_t i) {
			switch(i) {
				foreach(immutable j, T; Args) {
					case j:
						static if(is(T == Target)) return TARGET;
						else static if(is(T == Entity[])) return ENTITIES;
						else static if(is(T == Player[])) return PLAYERS;
						else static if(is(T == Player)) return PLAYER;
						else static if(is(T == Position)) return POSITION;
						else static if(is(T == bool)) return BOOL;
						else static if(is(T == enum)) return T.stringof;
						else static if(isIntegral!T || isRanged!T && isIntegral!(T.Type)) return INT;
						else static if(isFloatingPoint!T || isRanged!T && isFloatingPoint!(T.Type)) return FLOAT;
						else return STRING;
				}
				default:
					return UNKNOWN;
			}
		}

		public override PocketType pocketTypeOf(size_t i) {
			switch(i) {
				foreach(immutable j, T; Args) {
					case j:
						static if(is(T == Target) || is(T == Entity) || is(T == Entity[]) || is(T == Player[]) || is(T == Player)) return PocketType.target;
						else static if(is(T == Position)) return PocketType.blockpos;
						else static if(is(T == bool)) return PocketType.boolean;
						else static if(is(T == enum)) return PocketType.stringenum;
						else static if(is(T == string)) return j == Args.length - 1 ? PocketType.rawtext : PocketType.string;
						else static if(isIntegral!T || isRanged!T && isIntegral!(T.Type)) return PocketType.integer;
						else static if(isFloatingPoint!T || isRanged!T && isFloatingPoint!(T.Type)) return PocketType.floating;
						else goto default;
				}
				default:
					return PocketType.rawtext;
			}
		}
		
		public override string[] enumMembers(size_t i) {
			switch(i) {
				foreach(immutable j, T; E) {
					static if(is(T == enum)) {
						case j: return [__traits(allMembers, T)];
					}
				}
				default: return [];
			}
		}

		public override bool callableBy(CommandSender sender) {
			static if(is(C == CommandSender)) return true;
			else return cast(C)sender !is null;
		}
		
		public override CommandResult callArgs(CommandSender _sender, string args) {
			static if(!is(C == CommandSender)) {
				C sender = cast(C)_sender;
				// assuming that the control has already been done
				//if(senderc is null) return CommandResult.NOT_FOUND;
			} else {
				alias sender = _sender;
			}
			StringReader reader = StringReader(args);
			Args cargs;
			foreach(immutable i, T; Args) {
				if(!reader.eof()) {
					static if(is(T == Target) || is(T == Entity[]) || is(T == Player[]) || is(T == Player) || is(T == Entity)) {
						immutable selector = reader.readQuotedString();
						auto target = Target.fromString(sender, selector);
						static if(is(T == Player) || is(T == Player[])) {
							//TODO this control can be done before querying the entities
							if(!target.player) return CommandResult(CommandResult.targetNotPlayer);
						}
						if(target.entities.length == 0) return CommandResult(selector.startsWith("@") ? CommandResult.targetNotFound : CommandResult.playerNotFound);
						static if(is(T == Player)) {
							cargs[i] = target.players[0];
						} else static if(is(T == Player[])) {
							cargs[i] = target.players;
						} else static if(is(T == Entity)) {
							cargs[i] = target.entities[0];
						} else static if(is(T == Entity[])) {
							cargs[i] = target.entities;
						} else {
							cargs[i] = target;
						}
					} else static if(is(T == Position)) {
						try {
							cargs[i] = Position(Position.Point.fromString(reader.readString()), Position.Point.fromString(reader.readString()), Position.Point.fromString(reader.readString()));
						} catch(Exception) {
							return CommandResult.INVALID_SYNTAX;
						}
					} else static if(is(T == bool)) {
						immutable value = reader.readString();
						if(value == "true") cargs[i] = true;
						else if(value == "false") cargs[i] = false;
						else return CommandResult(CommandResult.invalidBoolean, [value]);
					} else static if(is(T == enum)) {
						immutable value = reader.readString();
						switch(value.toLower) {
							mixin((){
									string ret;
									foreach(immutable member ; __traits(allMembers, T)) {
										ret ~= `case "` ~ member.toLower ~ `": cargs[i]=T.` ~ member ~ `; break;`;
									}
									return ret;
								}());
							default:
								return CommandResult(CommandResult.invalidParameter, [value]);
						}
					} else static if(isIntegral!T || isFloatingPoint!T || isRanged!T) {
						immutable value = reader.readString();
						try {
							static if(isFloatingPoint!T || isRanged!T && isFloatingPoint!(T.Type)) {
								// converted numbers cannot be infinite or nan
								immutable num = to!double(value);
							} else {
								immutable num = to!int(value);
							}
							// control bounds (on integers and ranged numbers)
							static if(!isFloatingPoint!T) {
								enum _min = T.min;
								static if(!isRanged!T || T.type[0] == '[') {
									if(num < _min) return CommandResult(CommandResult.invalidRangeDown, [value, to!string(_min)]);
								} else {
									if(num <= _min) return CommandResult(CommandResult.invalidRangeDown, [value, to!string(_min)]);
								}
								static if(!isRanged!T || T.type[1] == ']') {
									if(num > T.max) return CommandResult(CommandResult.invalidRangeUp, [value, to!string(T.max)]);
								} else {
									if(num >= T.max) return CommandResult(CommandResult.invalidRangeUp, [value, to!string(T.max)]);
								}
							}
							// assign
							static if(isRanged!T) cargs[i] = T(cast(T.Type)num);
							else cargs[i] = cast(T)num;
						} catch(ConvException) {
							return CommandResult(CommandResult.invalidNumber, [value]);
						}
					} else static if(i == Args.length - 1) {
						immutable value = reader.readText();
						if(value.length > 2 && value[0] == '"' && value[$-1] == '"') {
							cargs[i] = value[1..$-1];
						} else {
							cargs[i] = value;
						}
					} else {
						cargs[i] = reader.readQuotedString();
					}
				} else {
					static if(!is(Params[i] == void)) cargs[i] = Params[i];
					else return CommandResult.INVALID_SYNTAX;
				}
			}
			reader.skip();
			if(reader.eof) {
				static if(implemented) {
					this.del(sender, cargs);
					return CommandResult.SUCCESS;
				} else {
					return CommandResult.UNIMPLEMENTED;
				}
			} else {
				return CommandResult.INVALID_SYNTAX;
			}
		}

	}
	
	immutable string name;
	immutable Description description;
	immutable string[] aliases;

	immutable ubyte permissionLevel;
	string[] permissions;
	immutable bool hidden;

	Overload[] overloads;
	
	this(string name, Description description=Description.init, string[] aliases=[], ubyte permissionLevel=0, string[] permissions=[], bool hidden=false) {
		assert(checkCommandName(name));
		assert(aliases.all!(a => checkCommandName(a))());
		this.name = name;
		this.description = description;
		this.aliases = aliases.idup;
		this.permissionLevel = permissionLevel;
		this.permissions = permissions;
		this.hidden = hidden;
	}

	/**
	 * Adds an overload from a function.
	 */
	void add(alias func)(void delegate(Parameters!func) del, bool implemented=true) if(Parameters!func.length >= 1 && is(Parameters!func[0] : CommandSender)) {
		string[] params = [ParameterIdentifierTuple!func][1..$];
		//TODO nameable params
		if(implemented) this.overloads ~= new OverloadOf!(Parameters!func[0], true, Parameters!func[1..$], ParameterDefaults!func[1..$])(del, params);
		else this.overloads ~= new OverloadOf!(Parameters!func[0], false, Parameters!func[1..$], ParameterDefaults!func[1..$])(del, params);
	}

	/**
	 * Removes an overload using a function.
	 */
	bool remove(alias func)() {
		foreach(i, overload; this.overloads) {
			if(cast(OverloadOf!(Parameters!func[0], Parameters!func[1..$], ParameterDefaults!func[1..$]))overload) {
				this.overloads = this.overloads[0..i] ~ this.overloads[i+1..$];
				return true;
			}
		}
		return false;
	}
	
}

private bool checkCommandName(string name) {
	if(name.length) {
		foreach(c ; name) {
			if((c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '_' && c != '?') return false;
		}
	}
	return true;
}

public bool areValidArgs(C:CommandSender, E...)() {
	foreach(T ; E) {
		static if(!areValidArgsImpl!(C, T)) return false;
	}
	return true;
}

private template areValidArgsImpl(C, T) {
	static if(is(T == enum) || is(T == string) || is(T == bool) || isIntegral!T || isFloatingPoint!T || isRanged!T) enum areValidArgsImpl = true;
	else static if(is(T == Target) || is(T == Entity) || is(T == Entity[]) || is(T == Player[]) || is(T == Player) || is(T == Position)) enum areValidArgsImpl = is(C : WorldCommandSender);
	else enum areValidArgsImpl = false;
}
