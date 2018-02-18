/*
 * Copyright (c) 2017-2018 sel-project
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 */
/**
 * Copyright: 2017-2018 sel-project
 * License: MIT
 * Authors: Kripth
 * Source: $(HTTP github.com/sel-project/selery/source/selery/node/plugin/config.d, selery/node/plugin/config.d)
 */
module selery.node.plugin.config;

import std.ascii : newline;
import std.conv : to, ConvException;
import std.string : split, join, strip, indexOf;
import std.traits : isArray;

import selery.node.plugin.file;

enum _;

struct Value(T) {

	alias Type = T;

	string name;
	T def;

}

Value!T value(T)(string name, T def) {
	return Value!T(name, def);
}

/**
 * Container for configuration files with compile-time format
 * and members.
 * 
 * The file is saved in a text file in format "field: value",
 * one per line, with every value converted into a string.
 * Supported values are the basic numeric types, string and
 * arrays of these two.
 * 
 * Use $(D value) to indicate a field with a static type, $(D _) to
 * insert an empty line and a string to insert a comment.
 * 
 * Example:
 * ---
 * Config!(Value!string("name"), _, Value!uint("players", 0), Value!uint("max", 256), _, Value!(uint[])("array")) example;
 * assert(example.players == 0);
 * assert(example.max == 256);
 * 
 * alias Example = Config!("comment", value("field", "value"), _, value("int", 12u));
 * Example.init.save("example.txt");
 * assert(read("example.txt") == "# comment\nfield: value\n\nint: 12\n"); // with posix's line-endings
 * ---
 */
struct Config(E...) if(areValidArgs!E) {

	private string file;

	mixin((){
		string ret;
		foreach(immutable i, T; E) {
			static if(!is(T == _) && !is(typeof(T) : string)) {
				ret ~= "E[" ~ to!string(i) ~ "].Type " ~ T.name ~ "=E[" ~ to!string(i) ~ "].def;";
			}
		}
		return ret;
	}());

	/**
	 * Loads the values from a file.
	 * Throws:
	 * 		ConvException if one of the value cannot be converted from string to the requested one
	 * 		FileException on file error
	 */
	public void load(string sep=":", string mod=__MODULE__)(string file) {
		if(exists!mod(file)) {
			string[] lines = (cast(string)read!mod(file)).split("\n");
			foreach(string line ; lines) {
				if(line.length && line[0] != '#') {
					auto index = line.indexOf(sep);
					if(index > 0) {
						string name = line[0..index].strip;
						string value = line[index+1..$].strip;
						foreach(immutable i, T; E) {
							static if(!is(T == _) && !is(typeof(T) : string)) {
								if(name == T.name) {
									static if(!isArray!(T.Type) || is(T.Type : string)) {
										try {
											mixin("this." ~ T.name ~ " = to!(T.Type)(value);");
										} catch(ConvException) {}
									} else {
										foreach(el ; value.split(",")) {
											try {
												mixin("this." ~ T.name ~ " ~= to!(typeof(T.Type.init[0]))(el.strip);");
											} catch(ConvException) {}
										}
									}
								}
							}
						}
					}
				}
			}
		}
		this.file = file;
	}

	/**
	 * Saves the field's values into a file. If none is given
	 * the values are saved in the same file they have been
	 * loaded from (if the load method has been called), otherwise
	 * the file is not saved.
	 * Throws:
	 * 		FileException on file error
	 * Example:
	 * ---
	 * example.save("example.txt");
	 * example.save("dir/test.txt");
	 * assert(read("example.txt") == read("dir/test.txt"));
	 * ---
	 */
	public void save(string sep=":", string mod=__MODULE__)(string file) {
		string data;
		foreach(immutable i, T; E) {
			static if(is(T == _)) {
				data ~= newline;
			} else static if(is(typeof(T) : string)) {
				data ~= "# " ~ T ~ newline;
			} else {
				data ~= T.name ~ sep ~ " ";
				static if(!isArray!(T.Type) || is(T.Type : string)) {
					mixin("data ~= to!string(this." ~ T.name ~ ");");
				} else {
					mixin("auto array = this." ~ T.name ~ ";");
					string[] d;
					foreach(a ; array) d ~= to!string(a);
					data ~= d.join(", ");
				}
				data ~= newline;
			}
		}
		write!mod(file, data);
	}

	/// ditto
	public void save(string sep=":", string mod=__MODULE__)() {
		if(this.file.length) this.save!(sep, mod)(this.file);
	}

}

private bool areValidArgs(E...)() {
	foreach(T ; E) {
		static if(!is(T == _) && !is(typeof(T) : string) && !is(T == struct) && !is(typeof(T.name) == string) && !is(typeof(T.def) == T.Type)) return false;
	}
	return true;
}
