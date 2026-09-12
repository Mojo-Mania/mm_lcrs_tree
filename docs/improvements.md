# Improvements

What has been done, what is still worth doing, and one idea the measurements
killed. All numbers are release builds (`-D ASSERT=none`), which is what
`pixi run bench` uses; figures quoted in older commits were taken with bounds
checking on and read roughly 2× slower.

## Done

### Appending a child is O(1)

`add_child` used to put the new node last by walking from the first child to
the end of the sibling chain, so building a node with k children cost O(k²) — a
root with 4000 direct children took 1224 ns per node. A `last_child` array
caches the tail of each chain, and appending now points the current tail's
sibling at the new node and updates the tail.

| build, one root with 4000 children | LCRSTree | nodes owning a `List` |
| --- | --- | --- |
| before | 1224 ns/node | 7.2 |
| now | **2.9 ns/node** | 6.8 |

Every operation that can change which node ends a chain maintains the tail:
`_append_child`, `_detach`, `prepend_root`, `add_tree`, `swap_nodes` and
`_compact`. `assert_consistent` checks the cached tail against the real chain
for every node, so a missed site fails whichever test touches it.

### Removal is O(1) when you ask for it

`_detach` had to find what precedes a node by scanning its parent's child
chain, leaving `remove` and `swap_nodes` O(number of siblings). A backward link
fixes that, and is opt in because it is only worth four bytes a node to trees
that actually remove from wide chains:

```mojo
LCRSTree[Int, DType.uint32, True]   # track_previous_sibling
```

| remove 2000 children of a 4000-child node, back to front | ns per removal |
| --- | --- |
| off (the default) | 732.4 |
| on | **91.1** |

With the parameter off, the backward region is not reserved at all — the link
buffer has five regions instead of six — and every line maintaining it compiles
away inside a `comptime if`. Direction matters: removing front to back barely
notices, because the forward scan stops immediately. The number above is the
worst case.

### One allocation for every index, and no `List` anywhere

The tree used to hold each index array in its own `List`: seven allocations,
seven lengths and capacities that were always equal, and a 168-byte handle.
Every index now lives in one buffer divided into regions, the elements in
another, and both are owned directly rather than through `List`.

| | seven `List`s | one `List` | raw buffers |
| --- | --- | --- | --- |
| create and destroy 20000 eight-node trees | 872.6 ns | 219.1 ns | **98.2 ns** |
| build a 37449-node bushy tree | 5.3 ns/node | 4.8 ns/node | **3.5 ns/node** |
| `sizeof(LCRSTree[Int])` | 168 bytes | 64 bytes | **40 bytes** |

Growth is bulk: the elements relocate with one `unsafe_uninit_move_n`, each
link region with one `unsafe_memcpy`. `capacity` is a constructor argument,
`growth_percent` a compile-time parameter, and `reserve()` is public.

Indexing was never the reason — in a release build, pointer and `List` indexing
are indistinguishable (2.03 vs 2.04 ns per node on a preorder walk, 0.226 vs
0.230 on a sequential sum). The win is the smaller handle, the bulk growth and
the control. The cost is hand-written copy, move and destroy, covered by tests
over `String` elements; the suite reports 0 leaks under macOS `leaks`.

One trap worth remembering: the first raw-pointer version was 20% *slower* to
build, because `_reserve` had grown big enough that its early return stopped
inlining into `add_child`. Splitting it into an `@always_inline` check and a
`@no_inline` `_grow` took the bushy build from 5.8 to 3.4 ns per node.

### Postorder, leaves, and the editing operations

Preorder and breadth-first were exposed; postorder was not, though it is what
most tree-shaped work wants — evaluating, laying out, folding upwards, freeing.
It walks on the parent links like `dfs()`, so it needs no stack and cannot
overflow: a test walks a 50000-node chain. `leaves()` and `subtree_size()` came
with it, along with `first_child()`/`next_sibling()` so callers can write their
own walks.

A tree could also only be built top-down and appended to. It now supports
ordered insertion — `insert_child_at`, `insert_before`, `insert_after` — and
`move_node`, which re-parents a node with its subtree and refuses to make a
cycle or move the root. All of them maintain the cached tail and, when enabled,
the backward links; the both-settings mutation exercise covers them, and every
test ends in `assert_consistent`.

A per-node subtree count would make `subtree_size` O(1) at four bytes a node,
but it has to be maintained by every structural operation, so it waits until
something needs it.

### A compaction policy

Compaction is worth 2.8× on traversal plus the memory — a depth-first walk over
a half-freed tree drops from 3.7 to 1.3 ns per node, and the slot array shrinks
to the live node count — but nothing triggered it, and it cannot be triggered
silently: it **renumbers every node**, so any index the caller holds goes stale.

`compact_if_fragmented(threshold=0.5)` is the shape that respects that. The
caller invokes it, and the `Bool` it returns says whether the renumbering
happened:

```mojo
if tree.compact_if_fragmented():
    # every index you were holding is now stale
```

`fragmentation()` and `free_slots()` expose the same information for callers
who want their own policy. A generation counter on indices would make silent
compaction safe, and costs more than it is worth here.

### Elements are borrowed, not copied

`tree[i]` returns a reference, so reading a node whose element owns heap storage
costs no copy (2.16 → 1.16 ns per `String` element) and can be mutated in
place. `__setitem__` is gone, since assignment flows through the same
reference.

That also makes a tree which does not own its elements expressible.
`BorrowedTree[T, origin]` — a `comptime` alias for `LCRSTree[Pointer[T,
origin]]` with a `borrowed_tree(span)` constructor — threads the storage's
origin through the tree's own type, so the compiler keeps the storage alive as
long as the tree needs it and rejects a tree that would outlive it. The borrow
is necessarily immutable: with a mutable origin the tree's type embeds a
mutable reference to the storage, so `add_child` is rejected for passing it
mutably twice.

The pointers have to come from a `Span`; `Pointer(to=collection[i])` carries an
interior origin that will not match the collection's own.

## Killed by measurement

### Breadth-first traversal and child enumeration were *not* 2× slower

This document used to claim BFS cost 4.1 ns per node against a child-list
tree's 1.4, and child enumeration 1.5 against 0.8, as an inherent cost of
walking sibling chains. Both numbers predated the storage work and were taken
with bounds checking on. Measured now:

| | LCRSTree | nodes owning a `List` |
| --- | --- | --- |
| breadth-first walk | **0.9** | 1.0 |
| enumerate every node's children | **0.7** | 0.7 |

Sibling chains are not the liability they looked like: the links are dense
`uint32` regions, and walking one is a sequential scan. Nothing to fix.

### An intrusive free list

Storing "next free slot" inside a freed slot's own link would drop the free
region entirely. It makes claiming a slot a serially dependent pointer chase
instead of a dense LIFO scan:

| claim 500k freed slots | ns per slot |
| --- | --- |
| separate free region | **0.49** |
| intrusive, freed in address order | 0.55 |
| intrusive, freed in scattered order | **7.89** |

16× worse in the case that matters, since subtrees removed over a tree's life
do not free slots in address order.

## Open

### Smaller items

- **`shrink_to_fit`.** `remove` frees slots but never returns memory; only
  compaction does, and only as a side effect. Cheap now that the buffers are
  owned directly.
- **The free region is reserved at full capacity** even by a tree that never
  removes anything, which is why a node costs 28 bytes rather than 24. It could
  be allocated lazily on the first `remove`, at the price of a branch in
  `_grow`.
- **`add_tree` copies the source's free list** along with its nodes, so
  grafting a tree that has had removals carries the holes over. Compacting the
  source first avoids it; `add_tree` could do that itself.
- **`Writable` on the tree**, so `print(tree)` works and `print_tree` becomes a
  thin wrapper.
- **`children_count` is O(k)**, and it is the kind of call that ends up in a
  loop. Document it loudly, or keep a per-node child count — the same four
  bytes as the subtree size above, and the same argument for waiting.
- **The index-overflow `debug_assert` disappears in release builds.** For
  `uint16` indices a real check is cheap next to the work `_claim_slot` already
  does.
