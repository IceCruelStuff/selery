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
 * Copyright: Copyright (c) 2017-2018 sel-project
 * License: MIT
 * Authors: Kripth
 * Source: $(HTTP github.com/sel-project/selery/source/selery/event/event.d, selery/event/event.d)
 */
module selery.event.event;

import std.algorithm : sort, canFind;
import std.conv : to;
import std.string : indexOf;
import std.typetuple : TypeTuple;
import std.traits : isAbstractClass, BaseClassesTuple, InterfacesTuple, Parameters;

import selery.util.tuple : Tuple;

alias class_t = size_t;

private enum dictionary = " abcdefghijklmonpqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.".dup;

private enum hash(T) = hashImpl(T.mangleof);

//TODO find out whether this is slow during CT
private class_t hashImpl(string mangle) {
	size_t result = 1;
	foreach(c ; mangle) {
		result ^= (result >> 8) ^ ~(size_t.max / dictionary.indexOf(c)); 
	}
	return result;
}

/*
 * Storage for event's delegates with the event casted
 * to a generic void pointer.
 */
private alias Delegate = Tuple!(void delegate(void*), "del", size_t, "count");

/*
 * Storage for callable events (already casted to the right
 * type) ready to be ordered and called.
 */
private alias Callable = Tuple!(void delegate(), "call", size_t, "count");

/*
 * Count variable shared between every event listener to
 * maintain a global registration order.
 */
private size_t count = 0;

private alias Implementations(T) = TypeTuple!(T, BaseClassesTuple!T[0..$-1], InterfacesTuple!T);

/**
 * Generic event listener.
 */
class EventListener(O:Event, Children...) if(areValidChildren!(O, Children)) {

	protected Delegate[][class_t] listeners;

	/**
	 * Adds an event through a delegate.
	 * Returns: an id that can be used to unregister the event
	 */
	public @trusted size_t addEventListener(T)(void delegate(T) listener) if(is(T == class) && is(T : O) || is(T == interface)) {
		this.listeners[hash!T] ~= Delegate(cast(void delegate(void*))listener, count);
		return count++;
	}

	/// ditto
	public @safe opOpAssign(string op : "+", T)(void delegate(T) listener) {
		return this.addEventListener(listener);
	}

	public @safe void setListener(E...)(EventListener!(O, E) listener) {
		foreach(hash, listeners; listener.listeners) {
			foreach(del ; listeners) {
				this.listeners[hash] ~= Delegate(del.del, del.count);
			}
		}
	}

	/**
	 * Removes an event listener using its delegate pointer.
	 * Returns: true if one or more event have been removed, false otherwise
	 * Example:
	 * ---
	 * // add
	 * example.addEventListener(&event);
	 * 
	 * // remove
	 * assert(example.removeEventListener(&event));
	 * ---
	 */
	public @trusted bool removeEventListener(T)(void delegate(T) listener) {
		bool removed = false;
		auto ptr = hash!T in this.listeners;
		if(ptr) {
			foreach(i, del; *ptr) {
				if(cast(void delegate(T))del.del == listener) {
					removed = true;
					if((*ptr).length == 1) {
						this.listeners.remove(hash!T);
						break;
					} else {
						*ptr = (*ptr)[0..i] ~ (*ptr)[i+1..$];
					}
				}
			}
		}
		return removed;
	}

	/// ditto
	public @safe bool opOpAssign(string op : "-", T)(void delegate(T) listener) {
		return this.removeEventListener(listener);
	}

	/**
	 * Removes an event listener using its assigned id.
	 * Returns: true if the event has been removed, false otherwise
	 * Example:
	 * ---
	 * // add
	 * auto id = example.addEventListener(&event);
	 * 
	 * // remove
	 * assert(example.removeEventListener(id));
	 * ---
	 */
	public @safe bool removeEventListener(size_t count) {
		foreach(i, listeners; this.listeners) {
			foreach(j, del; listeners) {
				if(del.count == count) {
					if(listeners.length == 1) {
						this.listeners.remove(i);
					} else {
						this.listeners[i] = listeners[0..j] ~ listeners[j+1..$];
					}
					return true;
				}
			}
		}
		return false;
	}

	/// ditto
	public @safe bool opOpAssign(string op : "-")(size_t count) {
		return this.removeEventListener(count);
	}
	
	/**
	 * Calls an event.
	 * Events are always called in the order they are registered, even 
	 * in the inheritance.
	 */
	public void callEvent(T:O)(ref T event) if(is(T == class) && !isAbstractClass!T) {
		Callable[] callables = this.callablesOf(event);
		if(callables.length) {
			sort!"a.count < b.count"(callables);
			foreach(callable ; callables) {
				callable.call();
				static if(is(T : Cancellable)) {
					if(event.cancelled) break;
				}
			}
		}
	}

	protected Callable[] callablesOf(T:O)(ref T event) if(is(T == class) && !isAbstractClass!T) {
		Callable[] callables;
		foreach_reverse(E ; Implementations!T) {
			auto ptr = hash!E in this.listeners;
			if(ptr) {
				foreach(i, del; *ptr) {
					callables ~= this.createCallable!E(event, del.del, del.count);
				}
			}
		}
		static if(staticDerivateIndexOf!(T, Children) >= 0) {
			callables ~= mixin("event." ~ Children[staticDerivateIndexOf!(T, Children)+1] ~ ".callablesOf(event)");
		}
		return callables;
	}
	
	private Callable createCallable(E, T)(ref T event, void delegate(void*) del, size_t count) {
		return Callable((){(cast(void delegate(E))del)(event);}, count);
	}

	/**
	 * Calls an event only if it exists.
	 * This should be used when a event is used only to notify
	 * the plugin of it.
	 * Returns: the instance of the event or null if the event hasn't been called
	 */
	public T callEventIfExists(T:O)(lazy Parameters!(T.__ctor) args) if(is(T == class) && !isAbstractClass!T) {
		T callImpl() {
			T event = new T(args);
			this.callEvent(event);
			return event;
		}
		foreach_reverse(E ; Implementations!T) {
			if(hash!E in this.listeners) return callImpl();
		}
		static if(staticDerivateIndexOf!(T, Children) >= 0) {
			alias C = Children[staticDerivateIndexOf!(T, Children)];
			static assert(is(typeof(args[0]) : EventListener!O), T.stringof ~ ".__ctor[0] must extend " ~ (EventListener!O).stringof);
			foreach_reverse(E ; Implementations!T) {
				if(hash!E in args[0].listeners) return callImpl();
			}
		}
		return null;
	}

	/**
	 * Calls a cancellable event using callEventIfExists.
	 * Returns: true if the event has been called and cancelled, false otherwise
	 */
	public bool callCancellableIfExists(T:O)(lazy Parameters!(T.__ctor) args) if(is(T == class) && !isAbstractClass!T && is(T : Cancellable)) {
		T event = this.callEventIfExists!T(args);
		return event !is null && event.cancelled;
	}

}

private bool areValidChildren(T, C...)() {
	static if(C.length % 2 != 0) return false;
	foreach(immutable i, E; C) {
		static if(i % 2 == 0) {
			static if(!is(E : T) || !is(E == interface)) return false;
		} else {
			static if(!__traits(hasMember, C[i-1], E)) return false;
		}
	}
	return true;
}

alias staticDerivateIndexOf(T, E...) = staticDerivateIndexOfImpl!(0, T, E);

private template staticDerivateIndexOfImpl(size_t index, T, E...) {
	static if(E.length == 0) {
		enum ptrdiff_t staticDerivateIndexOfImpl = -1;
	} else static if(is(E[0] == interface) && is(T : E[0])) {
		enum ptrdiff_t staticDerivateIndexOfImpl = index;
	} else {
		alias staticDerivateIndexOfImpl = staticDerivateIndexOfImpl!(index+1, T, E[1..$]);
	}
}

/**
 * Base interface of the event. Every valid event instance (that is not an interface)
 * must implement this interface.
 */
interface Event {}

/**
 * Indicates that the event is cancellable and its propagation
 * can be stopped by plugins.
 */
interface Cancellable {

	/**
	 * Cancels the event.
	 * A cancelled event is not propagated further to the next listeners,
	 * if there's any.
	 * Example:
	 * ---
	 * example += (ExampleEvent event){ log("1"); };
	 * example += (ExampleEvent event){ log("2"); event.cancel(); };
	 * example += (ExampleEvent event){ log("3"); };
	 * assert(event.callCancellableIfExists!ExampleEvent());
	 * ---
	 * The example will print
	 * ---
	 * 1
	 * 2
	 * ---
	 */
	public pure nothrow @safe @nogc void cancel();

	/**
	 * Indicates whether the event has been cancelled.
	 * A cancelled event cannot be uncancelled.
	 */
	public pure nothrow @property @safe @nogc bool cancelled();

	/// ditto
	alias canceled = cancelled;

	public static mixin template Implementation() {

		private bool _cancelled;

		public override pure nothrow @safe @nogc void cancel() {
			this._cancelled = true;
		}

		public override pure nothrow @property @safe @nogc bool cancelled() {
			return this._cancelled;
		}

	}

	public static mixin template FinalImplementation() {

		public final override pure nothrow @safe @nogc void cancel() {
			super.cancel();
		}

		public final override pure nothrow @property @safe @nogc bool cancelled() {
			return super.cancelled();
		}

	}

}

/// ditto
alias Cancelable = Cancellable;

class CancellableOf {

	static CancellableOf instance;

	static this() {
		instance = new CancellableOf();
	}

	void createCancellable(T:Cancellable)(T event) {
		event.cancel();
	}

}
