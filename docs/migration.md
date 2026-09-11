# Porting from 2023 Mojo to current Mojo

The original is in this repository's history at commit `7576f1c`
(`left_child_right_sibling/`), written against a 2023 Mojo.

## Language changes

The same list as the fiby tree port: `fn` → `def`, `let` → `var`, `inout` →
`mut`, `owned` → `var`, `alias` → `comptime`, `@parameter if` → `comptime if`,
`DynamicVector`/`UnsafeFixedVector` → `List`, `push_back` → `append`,
`x.to_int()` → `Int(x)`, and `Self.`-qualifying every struct parameter.

## Interface changes

**Traversal returns iterators.** The original offered index lists
(`get_dfs_indices`) and compile-time visitor parameters
(`traverse_dfs[visitor]`). Iterators subsume both:

```mojo
for index in tree.dfs():        # nothing allocated
    ...
for child in tree.children(n):  # nothing allocated
    ...
```

The index-list forms are kept for when the list itself is wanted; the visitor
forms are gone, since a `for` loop with `break` reads better than a callback
returning `Bool` to stop.

**Depth-first traversal no longer recurses.** The original `_dfs` called itself
per node, so a deep tree could exhaust the stack. Because this structure keeps
parent links, preorder can be walked with no auxiliary state at all: descend to
the first child; failing that take the next sibling; failing that climb until a
sibling appears. `_DfsIter` does exactly that, and a test walks a 50000-node
chain to prove it.

**Printing moved out of the struct.** `print_tree[to_str]` became a free
function constrained to `Writable` elements, so the tree never requires its
elements to be printable.

**Node indices are a parameter**, `I: DType = DType.uint32`, instead of a
hard-coded `UInt16` that capped the tree at 65535 nodes. Indices are plain
`Int` in the API; only the storage is narrowed.

**Renames:** `deleted` → `_free` (it is a free list, not a tombstone count),
and the element/link arrays are private with `capacity()` exposing the slot
count.

## Five bugs the port fixed

Each has a regression test.

### 1. `prepend_root` on a childless root built a cycle

```mojo
self.left_child.push_back(self.left_child[0])
```

`left_child[0] == 0` means "node 0 has no child" — a self-pointer. Copied to
the moved node it stops meaning "none" and starts meaning "my first child is
the new root", closing a cycle: the next traversal never terminates. The
original's sample only ever prepended onto a root that had children, so it
never showed. The port reads the real child first and writes a self-pointer
when there was none.

Covered by `test_prepend_root_twice`.

### 2. `add_tree` gave the grafted root the wrong parent

```mojo
self.parent[new_root] = 0
```

The copied tree's root was attached as a child of `parent_index` but told that
its parent was the root. Grafting onto anything but node 0 left `parent`
disagreeing with the child links, so `ancestor_indices`, `depth` and `remove`
all misbehaved. Covered by `test_add_tree_to_inner_node`.

### 3. `remove(0)` left a stale free list

Removing the root cleared the four node arrays but not `deleted`, so the next
`add_child` popped an index that no longer existed and wrote past the end of
the arrays. Covered by `test_remove_root_empties_the_tree`.

### 4. `swap_nodes` reported failure after succeeding

```mojo
if not self.is_root(index_a) and not self.is_root(index_b):
    self._swap_nodes(index_a, index_b)
return False
```

The cross-parent path performed the swap and then fell through to `return
False`. It also had no ancestor check, so swapping a node with its own
descendant would splice the tree into a cycle. The port returns the truth and
refuses ancestor swaps. Covered by `test_swap_across_parents` and
`test_swap_rejects_ancestor`.

### 5. `_compact` corrupted links that left the kept set

```mojo
var map = DynamicVector[Int](old_len)
for i in range(new_len):
    map[indices[i].to_int()] = i
```

Two problems. `DynamicVector[Int](old_len)` reserves capacity but has length
zero, so every write went past the end. And when compacting to a *subtree*, the
subtree root's `right_sibling` and `parent` point outside the kept set, so they
were mapped through entries that were never assigned.

The port fills the map with -1 and turns any link leaving the kept set into a
self-pointer, which is this structure's spelling of "none". Covered by
`test_compact_to_subtree`.

## Verification

`assert_consistent` runs after most structural tests: it walks the tree and
checks that every child agrees with its parent about who the parent is, that
the only root is node 0, and that the number of reachable nodes equals `len()`.
That invariant is what catches cycles and orphans, and it is what turned bugs
1 and 5 up — both first appeared as a test process killed for running the
machine out of memory while appending to an index list it could never finish.
