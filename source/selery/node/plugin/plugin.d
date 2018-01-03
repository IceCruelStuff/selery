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
module selery.node.plugin.plugin;

import std.conv : to;
import std.traits : Parameters;

import selery.about;
public import selery.plugin;

import selery.command.util : CommandSender;
import selery.event.node : NodeServerEvent;
import selery.event.world : WorldEvent;
import selery.node.server : NodeServer;
import selery.server : Server;

interface NodePlugin {}

class PluginOf(T) : Plugin if(is(T == Object) || is(T : NodePlugin)) {

	public this(string name, string[] authors, string vers, bool api, string languages, string textures) {
		this.n_name = name;
		this.n_authors = authors;
		this.n_version = vers;
		this.n_api = api;
		this.n_languages = languages;
		this.n_textures = textures;
		static if(!is(T : Object)) this.hasMain = true;
	}

	public override void load(shared Server server) {
		static if(!is(T == Object)) {
			auto node = cast(shared NodeServer)server;
			static if(is(typeof(T.__ctor)) && Parameters!(T.__ctor).length == 1 && is(Parameters!(T.__ctor)[0] == typeof(node))) {
				T main = new T(node);
			} else {
				T main = new T();
			}
			loadPluginAttributes!(true, NodeServerEvent, WorldEvent, false, CommandSender, false)(main, this, cast()node);
		}
	}

}
