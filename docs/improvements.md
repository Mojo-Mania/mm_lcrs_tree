# Suggested improvements

Ordered by effect on the numbers in the README. None of this is implemented;
the port kept the original design apart from the five bug fixes in
[`migration.md`](migration.md).

## 1. Appending a child walks the whole sibling chain

`add_child` puts the new node last, and finding "last" means walking from the
first child:

```mojo
while self.has_sibling(child):
    child = Int(self._right_sibling[child])
```

So building a node with k children costs O(k²). Measured: a root with 4000
direct children takes **1224 ns per node against a child-list tree's 7.2**.
Bushy trees never notice, but a wide one — a directory with thousands of
entries, a parse tree with a long argument list — falls off a cliff.

**Fix: a `last_child` array.** One more index per node (4 bytes with the
default `uint32`, taking a node from 20 to 24 bytes) makes the append O(1):
point the current last child's sibling at the new node and update
`last_child[parent]`. Everything else is unaffected, and `_append_child` is the
only writer that has to maintain it.

**Alternative without the memory:** offer `prepend_child`, which is already
O(1), for callers that do not care about order. Cheap to add, but it changes
the child order, so it cannot be the default.

## 2. Breadth-first traversal and child enumeration cost about 2×

BFS is 4.1 ns per node against a child-list tree's 1.4, and enumerating every
node's children is 1.5 against 0.8. Both walk sibling chains, which is inherent
to the layout — the child-list tree reads a contiguous array instead.

Compaction narrows it (below), and `last_child` would not help here. If a
workload is dominated by breadth-first passes over a wide tree, this is the
wrong structure and the README says so.

## 3. Compaction is worth calling and nothing calls it

After removing half the nodes, a depth-first walk costs 3.8 ns per node; after
`compact_dfs()` it costs 2.5, and the slot array shrank from 37449 to 1365.
That is a 34% traversal win plus the memory, for an O(n) pass.

Nothing triggers it automatically. **Fix:** compact when the free list exceeds
half the slots, the same policy suggested for the fiby tree's rebalance. The
catch is that compaction **renumbers nodes**, so any index the caller is holding
goes stale — it cannot be made implicit without either a generation counter on
indices or an opt-in flag. Worth doing deliberately rather than silently.

## 4. `children_count` walks the chain

It is O(k), and it is the kind of call that ends up inside a loop. Either
document it loudly or keep a per-node child count — another 4 bytes, updated in
`_append_child` and `_detach`. The count also makes `subtree_size` cheap to
maintain, which several of the missing operations below want.

## 5. Missing operations

The structure supports these naturally and does not expose them:

- `move_node(node, new_parent)` — currently a remove plus a rebuild, though the
  links to change are exactly the ones `swap_nodes` already touches.
- `insert_child_at(parent, k, element)` and `insert_before/after(sibling)` —
  ordered insertion, not just append.
- `first_child(index)` / `next_sibling(index)` as public accessors, so callers
  can write their own walks without `children()`.
- `leaves()`, `subtree_size(index)`, `postorder()` — postorder in particular is
  what most tree-shaped algorithms (evaluation, layout, freeing) actually want,
  and the parent links make it as stack-free as preorder.
- `Writable` on the tree itself, so `print(tree)` works and `print_tree` becomes
  a thin wrapper.

## 6. Smaller items

- `remove` frees slots but never shrinks the arrays; only compaction does.
  `capacity()` exposes the gap, but a `shrink_to_fit` would be kinder.
- `__getitem__` returns a copy, so reading a `String` node allocates. Returning
  a reference would avoid it, but `List.__getitem__` vends an interior origin
  that cannot widen to the whole-tree origin an accessor needs — the same
  constraint the stdlib's `_DequeIter` documents.
- `add_tree` copies the source tree's free list along with its nodes, so
  grafting a tree that has had removals carries the holes over. Compacting the
  source first avoids it; `add_tree` could just do that.
- The `debug_assert` guarding index-type overflow disappears in release builds.
  For `uint16` indices a real check is cheap next to the three appends.
