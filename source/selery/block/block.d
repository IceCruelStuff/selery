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
 * Source: $(HTTP github.com/sel-project/selery/source/selery/block/block.d, selery/block/block.d)
 */
module selery.block.block;

import std.algorithm : canFind;
import std.conv : to;
import std.math : ceil;
import std.string : split, join, capitalize;

import selery.about : block_t, item_t, tick_t;
import selery.entity.entity : Entity;
import selery.event.event : EventListener;
import selery.event.world.world : WorldEvent;
import selery.item.item : Item;
import selery.item.slot : Slot;
import selery.math.vector : BlockAxis, BlockPosition, entityPosition;
import selery.player.player : Player;
import selery.world.chunk : Chunk;
import selery.world.world : World;

public import selery.math.vector : Faces = Face;

static import sul.blocks;

enum Update {

	placed,
	nearestChanged,

}

enum Remove {

	broken,
	creativeBroken,
	exploded,
	burnt,
	enderDragon,
	unset,

}

private enum double m = 1.0 / 16.0;

/**
 * Base class for every block.
 */
class Block {

	private const sul.blocks.Block _data;

	private immutable bool has_bounding_box;
	private BlockAxis bounding_box;

	public this(sul.blocks.Block data) {
		this._data = data;
		if(data.boundingBox) {
			this.has_bounding_box = true;
			with(data.boundingBox) this.bounding_box = new BlockAxis(m * min.x, m * min.y, m * min.z, m * max.x, m * max.y, m * max.z);
			//TODO calculate shapes
		} else {
			this.has_bounding_box = false;
		}
	}

	/**
	 * Gets the block's sul data.
	 */
	public pure nothrow @property @safe @nogc const sul.blocks.Block data() {
		return this._data;
	}

	/**
	 * Gets the block's SEL id.
	 */
	public pure nothrow @property @safe @nogc block_t id() {
		return this.data.id;
	}

	/**
	 * Indicates whether the block exists in Minecraft.
	 */
	public pure nothrow @property @safe @nogc bool java() {
		return this.data.java.exists;
	}

	public pure nothrow @property @safe @nogc ubyte javaId() {
		return this.data.java.id;
	}

	public pure nothrow @property @safe @nogc ubyte javaMeta() {
		return this.data.java.meta;
	}

	/**
	 * Indicates whether the block exists in Minecraft.
	 */
	public pure nothrow @property @safe @nogc bool bedrock() {
		return this.data.bedrock.exists;
	}

	public pure nothrow @property @safe @nogc ubyte bedrockId() {
		return this.data.bedrock.id;
	}

	public pure nothrow @property @safe @nogc ubyte bedrockMeta() {
		return this.data.bedrock.meta;
	}

	/**
	 * Indicates whether a block is solid (can sustain another block or
	 * an entity) or not.
	 */
	public pure nothrow @property @safe @nogc bool solid() {
		return this.data.solid;
	}

	/**
	 * Indicates whether the block is a fluid.
	 */
	public pure nothrow @property @safe @nogc bool fluid() {
		return false;
	}

	/**
	 * Indicates the block's hardness, used to calculate the mining
	 * time of the block's material.
	 */
	public pure nothrow @property @safe @nogc double hardness() {
		return this.data.hardness;
	}

	/**
	 * Indicates whether the block can be mined.
	 */
	public pure nothrow @property @safe @nogc bool indestructible() {
		return this.hardness < 0;
	}
	
	/**
	 * Indicates whether the block can be mined or it's destroyed
	 * simply by a left-click.
	 */
	public pure nothrow @property @safe @nogc bool instantBreaking() {
		return this.hardness == 0;
	}

	/**
	 * Gets the blast resistance, used for calculate
	 * the resistance at the explosion of solid blocks.
	 */
	public pure nothrow @property @safe @nogc double blastResistance() {
		return this.data.blastResistance;
	}

	/**
	 * Gets the block's opacity, in a range from 0 to 15, where 0 means
	 * that the light propagates like in the air and 15 means that the
	 * light is totally blocked.
	 */
	public pure nothrow @property @safe @nogc ubyte opacity() {
		return this.data.opacity;
	}

	/**
	 * Indicates the level of light emitted by the block in a range from
	 * 0 to 15.
	 */
	public pure nothrow @property @safe @nogc ubyte luminance() {
		return this.data.luminance;
	}

	/**
	 * Boolean value indicating whether or not the block is replaced
	 * when touched with a placeable item.
	 */
	public pure nothrow @property @safe @nogc bool replaceable() {
		return this.data.replaceable;
	}

	/**
	 * Boolean value indicating whether or not the block can be burnt.
	 */
	public pure nothrow @property @safe @nogc bool flammable() {
		return this.encouragement > 0;
	}

	public pure nothrow @property @safe @nogc ubyte encouragement() {
		return this.data.encouragement;
	}

	public pure nothrow @property @safe @nogc ubyte flammability() {
		return this.data.flammability;
	}

	/**
	 * Modifies an entity's damage. The value should be higher than 0.
	 * Example:
	 * ---
	 * 0 = no damage
	 * .5 = half damage
	 * 1 = normal damage
	 * 2 = double damage
	 * ---
	 */
	public pure nothrow @property @safe @nogc float fallDamageModifier() {
		return 1f;
	}

	/**
	 * Indicates whether the block has a bounding box which entities
	 * can collide with, even if the block is not solid.
	 */
	public pure nothrow @property @safe @nogc bool hasBoundingBox() {
		return this.has_bounding_box;
	}

	/**
	 * If hasBoundingBox is true, returns the bounding box of the block
	 * as an Axis instance.
	 * Values are from 0 to 1
	 */
	public pure nothrow @property @safe @nogc BlockAxis box() {
		return this.bounding_box;
	}

	public pure nothrow @property @safe @nogc bool fullUpperShape() {
		return false;
	}

	public void onCollide(World world, Entity entity) {}

	/**
	 * Get the dropped items as a slot array.
	 * Params:
	 * 		world = the world where the block has been broken
	 * 		player = the player who broke the block, can be null (e.g. explosion, fire...)
	 * 		item = item used to break the block, is null if player is null or the player broke the block with his hand
	 * Returns: a slot array with the dropped items
	 */
	public Slot[] drops(World world, Player player, Item item) {
		return [];
	}

	/**
	 * Get the amount of dropped xp when the block is broken
	 * Params:
	 * 		world = the world where the block has been broken
	 * 		player = the player who broke the block, can be null (e.g. explosion, fire...)
	 * 		item = item used to break the block, is null if player is null or the player broke the block with his hand
	 * Returns: an integer, indicating the amount of xp that will be spawned
	 */
	public uint xp(World world, Player player, Item item) {
		return 0;
	}

	public tick_t miningTime(Player player, Item item) {
		return 0;
	}

	/**
	 * Function called when a player right-click the block.
	 * Blocks like tile should use this function for handle
	 * the interaction.
	 * N.B. That this function will no be called if the player shifts
	 *	 while performing the right-click/screen-tap.
	 * Params:
	 * 		player = the player who tapped the block
	 * 		item = the item used, is the same as player.inventory.held
	 * 		position = 
	 * 		face = the face tapped
	 * Returns: false is a block should be placed, true otherwise
	 */
	public bool onInteract(Player player, Item item, BlockPosition position, ubyte face) {
		return false;
	}

	/**
	 * Called when an entity is inside the block (or part of it).
	 */
	public void onEntityInside(Entity entity, BlockPosition position, bool headInside) {}

	/**
	 * Called when an entity falls on walks on the block.
	 */
	public void onEntityStep(Entity entity, BlockPosition position, float fallDistance) {}

	/**
	 * Called when an entity collides with the block's side (except top).
	 */
	public void onEntityCollide(Entity entity, BlockPosition position) {}

	/**
	 * Boolean value indicating whether or not the block can receive a
	 * random tick. This property is only requested when the block is placed.
	 */
	public pure nothrow @property @safe @nogc bool doRandomTick() {
		return false;
	}

	/**
	 * If the property doRandomTick is true, this function could be called
	 * undefined times duraing the chunk's random ticks.
	 */
	public void onRandomTick(World world, BlockPosition position) {}

	/** 
	 * Function called when the block is receives an update.
	 * Redstone mechanism should be handled from this function.
	 */
	public void onUpdated(World world, BlockPosition position, Update type) {}

	public void onRemoved(World world, BlockPosition position, Remove type) {}

	/**
	 * Function called by the world after a requets made
	 * by the block using World.scheduleBlockUpdate if
	 * the rule in the world is activated.
	 */
	public void onScheduledUpdate(World world, BlockPosition position) {}

	/**
	 * Boolean value indicating whether or not the upper
	 * block is air or isn't solid.
	 * Params:
	 * 		world = the world there the block is placed
	 * 		position = position in the world where the block is placed
	 * 		checkFluid = boolean value indicating whether or not the fluid should be considered as a solid block
	 * Example:
	 * ---
	 * // farmlands become when dirt when they can't breathe
	 * world[0, 0, 0] = Blocks.FARMLAND;
	 * 
	 * world[0, 1, 0] = Blocks.BEETROOT_BLOCK;
	 * assert(world[0, 0, 0] == Blocks.FARMLAND);
	 * 
	 * world[0, 1, 0] = Blocks.DIRT;
	 * assert(world[0, 0, 0] != Blocks.FARMLAND);
	 * ---
	 */
	public final bool breathe(World world, BlockPosition position, bool checkFluid=true) {
		Block up = world[position + [0, 1, 0]];
		return up.blastResistance == 0 && (!checkFluid || !up.fluid);
	}

	/**
	 * Compare the block names.
	 * Example:
	 * ---
	 * // one block
	 * assert(new Blocks.Dirt() == Blocks.dirt);
	 * 
	 * // a group of blocks
	 * assert(new Blocks.Grass() == [Blocks.dirt, Blocks.grass, Blocks.grassPath]);
	 * ---
	 */
	public bool opEquals(block_t block) {
		return this.id == block;
	}

	/// ditto
	public bool opEquals(block_t[] blocks) {
		return blocks.canFind(this.id);
	}

	/// ditto
	public bool opEquals(Block[] blocks) {
		foreach(block ; blocks) {
			if(this.opEquals(block)) return true;
		}
		return false;
	}

	/// ditto
	public bool opEquals(Block* block) {
		if(block) return this.opEquals(*block);
		else return this.id == 0;
	}

	public override bool opEquals(Object o) {
		return cast(Block)o && this.opEquals((cast(Block)o).id);
	}

}

public bool compareBlock(block_t[] blocks)(Block block) {
	return compareBlock!blocks(block.id);
}

public bool compareBlock(block_t[] blocks)(block_t block) {
	//TODO better compile time cmp
	return blocks.canFind(block);
}

private bool compareBlockImpl(block_t[] blocks)(block_t block) {
	static if(blocks.length == 1) return block == blocks[0];
	else static if(blocks.length == 2) return block == blocks[0] || block == blocks[1];
	else return block >= blocks[0] && block <= blocks[$-1];
}

/**
 * Placed block in a world, used when a position is needed
 * but the block can be null.
 */
struct PlacedBlock {

	private BlockPosition n_position;
	private sul.blocks.Block n_block;

	public @safe @nogc this(BlockPosition position, sul.blocks.Block block) {
		this.n_position = position;
		this.n_block = block;
	}

	public pure nothrow @property @safe @nogc BlockPosition position() {
		return this.n_position;
	}

	public pure nothrow @property @safe @nogc sul.blocks.Block block() {
		return this.n_block;
	}

	alias block this;

}

public @property @safe int blockInto(float value) {
	if(value < 0) return (-value).ceil.to!int * -1;
	else return value.to!int;
}
