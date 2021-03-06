/*
 * Copyright (c) 2017-2019 sel-project
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
module init;

import std.algorithm : sort, canFind, clamp;
import std.array : join, split;
import std.ascii : newline;
import std.conv : ConvException, to;
import std.file;
import std.json;
import std.path : dirSeparator, buildNormalizedPath, absolutePath, relativePath;
import std.process : environment, executeShell;
import std.regex : matchFirst, ctRegex;
import std.stdio : writeln;
import std.string;
import std.zip;

import selery.about;

import toml;
import toml.json;

enum Type {

	default_ = "default",
	hub = "hub",
	node = "node"

}

int main(string[] args) {

	string libraries;
	if(exists(".selery/libraries")) {
		// should be an absolute normalised path
		libraries = cast(string)read(".selery/libraries");
	} else {
		// assuming this file is executed in ../
		libraries = buildNormalizedPath(absolutePath(".."));
	}
	if(!libraries.endsWith(dirSeparator)) libraries ~= dirSeparator;
	
	bool portable = false;
	bool plugins = true;
	
	Type type = Type.default_;
	
	// generate files
	{
		// clear
		if(exists("views")) {
			try {
				foreach(file ; dirEntries("views", SpanMode.breadth)) {
					if(file.isFile) remove(file);
				}
			} catch(Exception) {}
		} else {
			mkdirRecurse("views");
		}
		write("views/version.txt", Software.displayVersion);
		string[] notes;
		string changelog = cast(string)read("../.github/changelog.md");
		immutable v = "### " ~ Software.displayVersion;
		auto start = changelog.indexOf(v);
		if(start != -1) {
			start += v.length;
			changelog = changelog[start..$];
			immutable end = changelog.indexOf("##");
			write("views/notes.txt", changelog[0..(end==-1?$:end)].strip.replace("\r", "").replace("\n", "\\n"));
		} else {
			write("views/notes.txt", "There are no release notes for this version.");
		}
		write("views/is_release.txt", to!string(environment.get("APPVEYOR_REPO_COMMIT_MESSAGE", "").indexOf("[release]") != -1));
		// ci info
		JSONValue[string] ci;
		if(environment.get("TRAVIS", "") == "true") {
			ci["name"] = "travis-ci";
			ci["repo"] = environment["TRAVIS_REPO_SLUG"];
			ci["job"] = environment["TRAVIS_JOB_NUMBER"];
		} else if(environment.get("APPVEYOR", "").toLower == "true") {
			ci["name"] = "appveyor";
			ci["repo"] = environment["APPVEYOR_REPO_NAME"];
			ci["job"] = environment["APPVEYOR_BUILD_NUMBER"] ~ "." ~ environment["APPVEYOR_JOB_NUMBER"];
		}
		if(ci.length) write("views/build_ci.json", JSONValue(ci).toString());
		// git info
		JSONValue[string] git;
		if(exists("../.git/")) {
			git["remote"] = executeShell("git config --get remote.origin.url").output.strip;
			git["branch"] = executeShell("git rev-parse --abbrev-ref HEAD").output.strip;
			git["head"] = executeShell("git rev-parse HEAD").output.strip;
		}
		write("views/build_git.json", JSONValue(git).toString());
	}
	
	foreach(arg ; args) {
		switch(arg.toLower()) {
			case "--no-plugins":
				plugins = false;
				break;
			case "--portable":
				portable = true;
				break;
			case "default":
			case "classic":
			case "allinone":
			case "all-in-one":
				type = Type.default_;
				break;
			case "hub":
				type = Type.hub;
				break;
			case "node":
				type = Type.node;
				break;
			default:
				break;
		}		
	}
	
	bool[string] active_plugins;
	
	if(exists("../build-plugins.toml")) {
		try {
			foreach(key, value; parseTOML(cast(string)read("../build-plugins.toml"))) {
				active_plugins[key] = value.type == TOML_TYPE.TRUE;
			}
		} catch(TOMLException) {}
	}

	TOMLDocument[string] plugs; // plugs[location] = settingsfile

	if(plugins) {

		bool loadPlugin(string path) {
			if(!path.endsWith(dirSeparator)) path ~= dirSeparator;
			foreach(pack ; ["plugin.toml", "plugin.json"]) {
				if(exists(path ~ pack)) {
					if(pack.endsWith(".toml")) {
						auto toml = parseTOML(cast(string)read(path ~ pack));
						toml["single"] = false;
						plugs[path] = toml;
						return true;
					} else {
						auto json = parseJSON(cast(string)read(path ~ pack));
						if(json.type == JSON_TYPE.OBJECT) {
							json["single"] = false;
							plugs[path] = TOMLDocument(toTOML(json).table);
							return true;
						}
					}
				}
			}
			return false;
		}
		
		void loadZippedPlugin(string path) {
			// unzip and load as normal plugin
			auto data = read(path);
			auto zip = new ZipArchive(data);
			immutable name = path[path.lastIndexOf("/")+1..$-4];
			immutable dest = ".selery/plugins/" ~ name ~ "/";
			bool update = true;
			if(exists(dest)) {
				if(exists(dest ~ "crc32.json")) {
					update = false;
					auto json = parseJSON(cast(string)read(dest ~ "crc32.json")).object;
					// compare file names
					if(sort(json.keys).release() != sort(zip.directory.keys).release()) update = true;
					else {
						// compare file's crc32
						foreach(name, member; zip.directory) {
							if(member.crc32 != json[name].integer) {
								update = true;
								break;
							}
						}
					}
				}
				if(update) {
					foreach(string file ; dirEntries(dest, SpanMode.breadth)) {
						if(file.isFile) remove(file);
					}
				}
			} else {
				mkdirRecurse(dest);
			}
			if(update) {
				JSONValue[string] files;
				foreach(name, member; zip.directory) {
					files[name] = member.crc32;
					if(!name.endsWith("/")) {
						zip.expand(member);
						if(name.indexOf("/") != -1) mkdirRecurse(dest ~ name[0..name.lastIndexOf("/")]);
						write(dest ~ name, member.expandedData);
					}
				}
				write(dest ~ "crc32.json", JSONValue(files).toString());
			}
			if(!loadPlugin(dest)) loadPlugin(dest ~ name);
		}

		void loadSinglePlugin(string location) {
			immutable name = location[location.lastIndexOf("/")+1..$-2].replace("-", "_");
			foreach(line ; split(cast(string)read(location), "\n")) {
				if(line.strip.startsWith("module") && line[6..$].strip.startsWith(name ~ ";")) {
					string main = name ~ ".";
					bool uppercase = true;
					foreach(c ; name) {
						if(c == '_') {
							uppercase = true;
						} else {
							if(uppercase) main ~= toUpper("" ~ c);
							else main ~= c;
							uppercase = false;
						}
					}
					plugs[location] = TOMLDocument(["name": TOMLValue(name.replace("_", "-")), "main": TOMLValue(main)]);
					break;
				}
			}
		}

		writeln("Generating dub package for ", Software.name, " ", Software.displayVersion, ".");

		// load plugins in plugins folder
		if(exists("../plugins")) {
			foreach(string ppath ; dirEntries("../plugins/", SpanMode.shallow)) {
				if(ppath.isDir) {
					loadPlugin(ppath);
				} else if(ppath.isFile && ppath.endsWith(".zip")) {
					loadZippedPlugin(ppath);
				} else if(ppath.isFile && ppath.endsWith(".d")) {
					loadSinglePlugin(ppath);
				}
			}
		}

	}

	Plugin[string] info;
	
	foreach(path, value; plugs) {
		Plugin plugin;
		plugin.name = value["name"].str;
		checkName(plugin.name);
		if(path.isFile) {
			plugin.single = buildNormalizedPath(absolutePath(path));
		}
		plugin.path = buildNormalizedPath(absolutePath(path));
		if(plugin.name !in info) {
			plugin.toml = value;
			if(!plugin.path.endsWith(dirSeparator)) plugin.path ~= dirSeparator;
			auto priority = "priority" in value;
			if(priority) {
				if(priority.type == TOML_TYPE.STRING) {
					immutable p = priority.str.toLower;
					plugin.priority = (p == "high" || p == "🔥") ? 10 : (p == "medium" || p == "normal" ? 5 : 1);
				} else if(priority.type == TOML_TYPE.INTEGER) {
					plugin.priority = clamp(priority.integer.to!size_t, 1, 10);
				}
			}
			auto authors = "authors" in value;
			auto author = "author" in value;
			if(authors && authors.type == TOML_TYPE.ARRAY) {
				foreach(a ; authors.array) {
					if(a.type == TOML_TYPE.STRING) {
						plugin.authors ~= a.str;
					}
				}
			} else if(author && author.type == TOML_TYPE.STRING) {
				plugin.authors = [author.str];
			}
			auto target = "target" in value;
			if(target && target.type == TOML_TYPE.STRING) {
				switch(target.str.toLower) {
					case "default":
						plugin.target = Type.default_;
						break;
					case "hub":
						plugin.target = Type.hub;
						break;
					case "node":
						plugin.target = Type.node;
						break;
					default:
						break;
				}
			}
			foreach(mname, mvalue; (plugin.target == Type.default_ ? ["hub-main": Type.hub, "node-main": Type.node] : ["main": plugin.target])) {
				auto mptr = mname in value;
				if(mptr && mptr.type == TOML_TYPE.STRING) {
					Main main;
					string[] spl = mptr.str.split(".");
					if(plugin.single.length) {
						main.module_ = spl[0];
						main.main = mptr.str;
					} else {
						immutable m = mptr.str.lastIndexOf(".");
						if(m != -1) {
							main.module_ = mptr.str[0..m];
							main.main = mptr.str;
						}
					}
					plugin.main[mvalue] = main;
				}
			}
			if(plugin.single.length) {
				plugin.version_ = "~single";
			} else {
				foreach(string file ; dirEntries(plugin.path ~ "src", SpanMode.breadth)) {
					if(file.isFile && file.endsWith(dirSeparator ~ "api.d")) {
						plugin.api = true;
						break;
					}
				}
				if(exists(plugin.path ~ ".git") && isDir(plugin.path ~ ".git")) {
					// try to get version using git
					immutable tag = executeShell("cd " ~ plugin.path ~ " && git describe --tags").output.strip; //TODO do not use &&
					if(tag.startsWith("v")) plugin.version_ = tag;
				}
			}
			info[plugin.name] = plugin;
		} else {
			throw new Exception("Plugin '" ~ plugin.name ~ "' at " ~ plugin.path ~ " conflicts with a plugin with the same name at " ~ info[plugin.name].path);
		}
	}
	
	// remove plugins disabled in plugins.toml
	foreach(plugin, enabled; active_plugins) {
		if(!enabled) {
			auto p = plugin in info;
			if(p) p.enabled = false;
		}
	}

	auto ordered = info.values;

	// sort by priority (or alphabetically)
	sort!"a.priority == b.priority ? a.name < b.name : a.priority > b.priority"(ordered);

	// control api version
	foreach(ref inf ; ordered) {
		long[] api;
		auto ptr = "api" in inf.toml;
		if(ptr) {
			if((*ptr).type == TOML_TYPE.INTEGER) {
				api ~= (*ptr).integer;
			} else if((*ptr).type == TOML_TYPE.ARRAY) {
				foreach(v ; (*ptr).array) {
					if(v.type == TOML_TYPE.INTEGER) api ~= v.integer;
				}
			} else if((*ptr).type == TOML_TYPE.TABLE) {
				auto from = "from" in *ptr;
				auto to = "to" in *ptr;
				if(from && (*from).type == TOML_TYPE.INTEGER && to && (*to).type == TOML_TYPE.INTEGER) {
					foreach(a ; (*from).integer..(*to).integer+1) {
						api ~= a;
					}
				}
			}
		}
		if(api.length == 0 /*|| api.canFind(Software.api)*/) {
			writeln(inf.name, " ", inf.version_, ": loaded");
		} else {
			writeln(inf.name, " ", inf.version_, ": cannot load due to wrong api ", api);
			return 1;
		}
	}
	
	JSONValue[string] builder;
	builder["name"] = "selery-builder";
	builder["targetName"] = "selery" ~ (type!=Type.default_ ? "-" ~ type : "") ~ (portable ? "-" ~ Software.displayVersion : "");
	builder["targetType"] = "executable";
	builder["targetPath"] = "..";
	builder["workingDirectory"] = "..";
	builder["sourceFiles"] = ["main/" ~ type ~ ".d", ".selery/builder.d"];
	builder["dependencies"] = [
		"selery": ["path": ".."],
		"toml": ["version": "~>1.0.0-rc.3"],
		"toml:json": ["version": "~>1.0.0-rc.3"]
	];
	builder["configurations"] = [["name": cast(string)type]];
	builder["subPackages"] = new JSONValue[0];
		
	string loads = "";
	
	if(!exists(".selery")) mkdir(".selery");
	
	string[] pluginsFile;
	
	JSONValue[] json;

	foreach(ref value ; ordered) {
		pluginsFile ~= value.name ~ " = " ~ value.enabled.to!string;
		if(value.enabled) {
			if(value.single.length) {
				builder["sourceFiles"].array ~= JSONValue(relativePath(value.single));
			} else {
				JSONValue[string] sub;
				sub["name"] = value.name;
				sub["targetType"] = "library";
				sub["targetPath"] = ".." ~ dirSeparator ~ "libs";
				sub["configurations"] = [["name": "plugin"]];
				sub["dependencies"] = ["selery": ["path": ".."]],
				sub["sourcePaths"] = [relativePath(value.path ~ "src")];
				sub["importPaths"] = [relativePath(value.path ~ "src")];
				auto dptr = "dependencies" in value.toml;
				if(dptr && dptr.type == TOML_TYPE.TABLE) {
					foreach(name, d; dptr.table) {
						if(name.startsWith("dub:")) {
							sub["dependencies"][name[4..$]] = toJSON(d);
						} else if(name == "dub" && d.type == TOML_TYPE.TABLE) {
							foreach(dname, dd; d.table) {
								sub["dependencies"][dname] = toJSON(dd);
							}
						} else {
							//TODO depends on another plugin
							sub["dependencies"][":" ~ name] = "*";
						}
					}
				}
				auto subConfigurations = "subConfigurations" in value.toml;
				if(subConfigurations && subConfigurations.type == TOML_TYPE.TABLE) {
					sub["subConfigurations"] = toJSON(*subConfigurations);
				}
				builder["subPackages"].array ~= JSONValue(sub);
				builder["dependencies"][":" ~ value.name] = "*";
			}
			foreach(string mname; value.target==Type.default_ ? [Type.hub, Type.node] : [value.target]) {
				auto main = mname in value.main;
				string load = "ret ~= new PluginOf!(" ~ (main ? main.main : "Object") ~ ")(`" ~ value.name ~ "`, `" ~ value.path ~ "`, " ~ value.authors.to!string ~ ", `" ~ value.version_ ~ "`);";
				auto when = "when" in value.toml;
				if(when && when.type == TOML_TYPE.STRING) {
					load = "if(" ~ when.str ~ "){ " ~ load ~ " }";
				}
				if(value.single.length) load = "static if(is(" ~ value.main[Type.default_].main ~ " == class)){ " ~ load ~ " }";
				if(main) load = "static import " ~ main.module_ ~ "; " ~ load;
				auto staticWhen = "static-when" in value.toml;
				if(staticWhen && staticWhen.type == TOML_TYPE.STRING) {
					load = "static if(" ~ staticWhen.str ~ "){ " ~ load ~ " }";
				}
				load = "static if(target == `" ~ mname ~ "`){ " ~ load ~ " }";
				loads ~= "\t" ~ load ~ "\n";
			}
			json ~= value.toJSON();
			if(portable) {
				// copy plugins/$plugin/assets into assets/plugins/$plugin
				immutable assets = value.path ~ "assets" ~ dirSeparator;
				if(exists(assets) && assets.isDir) {
					foreach(file ; dirEntries(assets, SpanMode.breadth)) {
						immutable dest = "../assets/plugins" ~ dirSeparator ~ value.name ~ dirSeparator ~ file[assets.length..$];
						if(file.isFile) {
							mkdirRecurse(dest[0..dest.lastIndexOf(dirSeparator)]);
							write(dest, read(file));
						}
					}
				}
			}
		}
	}

	writeDiff(".selery/builder.d", "module pluginloader;\n\nimport selery.about : Software;\nimport selery.config : Config;\nimport selery.plugin : Plugin;\n\nPlugin[] loadPlugins(alias PluginOf, string target)(inout Config config){\n\tPlugin[] ret;\n" ~ loads ~ "\treturn ret;\n}\n\nenum info = `" ~ JSONValue(json).toString() ~ "`;\n");
	
	writeDiff("dub.json", JSONValue(builder).toString());
	
	write("../build-plugins.toml", pluginsFile.join(newline) ~ newline);

	if(portable) {

		auto zip = new ZipArchive();

		// get all files in assets
		foreach(string file ; dirEntries("../assets/", SpanMode.breadth)) {
			immutable name = file[10..$].replace("\\", "/");
			if(file.isFile && !name.startsWith(".") && !name.endsWith(".ico") && (!name.startsWith("web/") || name.endsWith("/main.css") || name.indexOf("/res/") != -1)) {
				//TODO optimise .lang files by removing empty lines, windows' line endings and comments
				auto data = read(file);
				auto member = new ArchiveMember();
				member.name = name;
				member.expandedData(cast(ubyte[])(file.endsWith(".json") ? parseJSON(cast(string)data).toString() : data));
				member.compressionMethod = CompressionMethod.deflate;
				zip.addMember(member);
			}
		}
		mkdirRecurse("views");
		write("views/portable.zip", zip.build());

	} else if(exists("views/portable.zip")) {

		remove("views/portable.zip");

	}
	
	return 0;

}

enum invalid = ["selery", "sel", "toml", "default", "lite", "hub", "node", "builder", "condition", "config", "starter", "pluginloader"];

void checkName(string name) {
	void error(string message) {
		throw new Exception("Cannot load plugin '" ~ name ~ "': " ~ message);
	}
	if(name.matchFirst(ctRegex!`[^a-z0-9\-]`)) error("Name contains characters outside the range a-z0-9-");
	if(name.length == 0 || name.length > 64) error("Invalid name length: " ~ name.length.to!string ~ " is not between 1 and 64");
	if(invalid.canFind(name)) error("Name is reserved");
}

void writeDiff(string location, const void[] data) {
	if(!exists(location) || read(location) != data) write(location, data);
}

struct Plugin {

	bool enabled = true;
	bool api = false;

	TOMLDocument toml;
	
	string single;
	
	size_t priority = 5;
	string path;

	string name;
	string[] authors;
	string version_ = "~local";
	
	Type target = Type.default_;
	Main[Type] main;
	
	JSONValue toJSON() {
		JSONValue[string] ret;
		ret["path"] = path;
		ret["name"] = name;
		ret["authors"] = authors;
		ret["version"] = version_;
		ret["target"] = target;
		if(main.length) {
			JSONValue[string] mret;
			foreach(key, value; main) {
				mret[key] = value.toJSON();
			}
			ret["main"] = mret;
		}
		return JSONValue(ret);
	}
	
}

struct Main {

	string module_;
	string main;
	
	JSONValue toJSON() {
		return JSONValue([
			"module": module_,
			"main": main
		]);
	}

}
