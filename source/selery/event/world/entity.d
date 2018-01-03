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
module selery.event.world.entity;

import selery.entity.entity : Entity;
import selery.entity.living : Living;
import selery.event.event : Cancellable;
import selery.event.world.damage : EntityDamageEvent;
import selery.event.world.world;
import selery.lang : Translation;
import selery.world.world : World;

interface EntityEvent : WorldEvent {

	public pure nothrow @property @safe @nogc Entity entity();

	public static mixin template Implementation() {

		private Entity n_entity;

		public final override pure nothrow @property @safe @nogc Entity entity() {
			return this.n_entity;
		}

		// implements WorldEvent
		public final override pure nothrow @property @safe @nogc World world() {
			return this.entity.world;
		}

	}
	
}

final class EntityHealEvent : EntityEvent, Cancellable {

	mixin Cancellable.Implementation;

	mixin EntityEvent.Implementation;

	private uint n_amount;

	public pure nothrow @safe @nogc this(Living entity, uint amount) {
		this.n_entity = entity;
		this.n_amount = amount;
	}

	public pure nothrow @property @safe @nogc uint amount() {
		return this.n_amount;
	}

}

class EntityDeathEvent : EntityEvent {

	mixin EntityEvent.Implementation;

	private EntityDamageEvent n_damage;

	private Translation m_message;
	private string[] m_args;

	public pure nothrow @safe @nogc this(Living entity, EntityDamageEvent damage) {
		this.n_entity = entity;
		this.n_damage = damage;
	}

	public pure nothrow @property @safe @nogc EntityDamageEvent damageEvent() {
		return this.n_damage;
	}

	public pure nothrow @property @safe @nogc const(Translation) message() {
		return this.m_message;
	}

	public pure nothrow @property @safe @nogc const(Translation) message(Translation message) {
		return this.m_message = message;
	}

	public pure nothrow @property @safe @nogc const(Translation) message(bool display) {
		if(display) {
			this.m_message = this.damageEvent.message;
			this.m_args = this.damageEvent.args;
		} else {
			this.m_message = Translation.init;
			this.m_args = [];
		}
		return this.message;
	}

	public pure nothrow @property @safe @nogc string[] args() {
		return this.m_args;
	}

	public pure nothrow @property @safe string[] args(string[] args) {
		return this.m_args = args is null ? [] : args;
	}

}
