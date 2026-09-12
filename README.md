# mm_lcrs_tree

[![CI](https://github.com/Mojo-Mania/mm_lcrs_tree/actions/workflows/ci.yml/badge.svg)](https://github.com/Mojo-Mania/mm_lcrs_tree/actions/workflows/ci.yml)

An n-ary tree for [Mojo](https://mojolang.org), stored as left-child /
right-sibling links in parallel arrays.

Every node keeps two tree links — its **first child** and its **next sibling** —
which encodes a tree of arbitrary arity as a binary one. A node's children are
its first child followed by that child's sibling chain, so a node costs the same
whether it has one child or a thousand, and no node owns a list. The price is
that reaching the k-th child is O(k).

Nodes are addressed by index, and a link pointing at its own node means "none",
so no index value is reserved as a sentinel. Every index the tree needs — child,
sibling, tail, parent and the free list — lives in **one** buffer divided into
regions, with the elements in another, so a whole tree is two allocations and a
40-byte handle. Growth relocates the elements in one bulk move and each link
region in one `memcpy`. Alongside the
two tree links this implementation keeps a `parent` array — which makes upward
walks, removal and node swaps possible — a `last_child` array, which is the tail
of each child chain and makes appending a child O(1), and a free list, so slots
released by `remove` are reused.

This is the 2023 `mojo-trees` experiment ported to current Mojo; see
[`docs/migration.md`](docs/migration.md), which also covers the five
correctness bugs the port fixed.

## Install

```bash
pixi add --git https://github.com/Mojo-Mania/mm_lcrs_tree.git mm_lcrs_tree
```

Needs `preview = ["pixi-build"]` in the consuming workspace and pixi 0.80+.
Or vendor the `mm_lcrs_tree/` directory and compile with
`mojo -I path/to/mm_lcrs_tree`.

## Usage

```mojo
from mm_lcrs_tree import LCRSTree, print_tree

var fs = LCRSTree[String]("/")
var etc = fs.add_child("etc")
_ = fs.add_child("hosts", etc)
_ = fs.add_child("usr")

for index in fs.dfs():          # depth first, allocation free
    print(fs[index])

for child in fs.children(etc):  # one node's children
    print(fs[child])

print(fs.depth(etc))            # 1
fs.remove(etc)                  # drops the subtree, frees its slots
```

Or describe the shape top down:

```mojo
from mm_lcrs_tree import LCRSTreeBuilder

var menu = (
    LCRSTreeBuilder[String]("menu")
    .node("file")
        .leaf("open")
        .leaf("save")
        .up()
    .node("edit")
        .leaf("copy")
    .tree()
)
```

### Index width

```mojo
LCRSTree[Int]                   # uint32 indices (default): ~4.3B nodes
LCRSTree[Int, DType.uint16]     # quarter the link memory, 65535 nodes max
```

### Trees that do not own their elements

`tree[i]` returns a reference rather than a copy, so reading a node whose
element owns heap storage costs nothing and can be mutated in place:

```mojo
tree[node] += "-suffix"       # no copy, no allocation
```

If the values live somewhere else entirely, make the element type a reference
to them. The tree then stores only structure:

```mojo
# Indices into storage you own -- simplest, and nothing to get wrong.
var tree = LCRSTree[Int](0)
for index in tree.dfs():
    print(my_values[tree[index]])

# Or pointers, when an index is not natural.
var tree = LCRSTree[Pointer[String, MutUntrackedOrigin]](
    Pointer(to=words[0]).unsafe_origin_cast[MutUntrackedOrigin]()
)
```

**Prefer the index form.** The pointer form erases the origin, and Mojo
destroys a value after its last use — so a `List` you took pointers into is
destroyed as soon as you stop mentioning it, leaving the tree pointing at freed
storage, with no compile error. Keeping it alive is then your job. Indices have
no such hazard.

### Growth

```mojo
LCRSTree[Int]                                  # doubles when it fills
LCRSTree[Int, DType.uint32, False, 150]        # grows by half instead
var tree = LCRSTree[Int](root, capacity=10_000)   # or skip growing entirely
tree.reserve(50_000)
```

`growth_percent` is the fourth parameter. One buffer holds every link region,
so over-allocating costs `_REGIONS` times what it would for a plain array —
150 with an honest `capacity` wastes far less than doubling on a large tree.

### Backward sibling links

Sibling links only point forward, so detaching a node has to find what precedes
it by scanning its parent's child chain — which makes `remove` and `swap_nodes`
O(number of siblings). If that matters, ask for a backward link too:

```mojo
LCRSTree[Int, DType.uint32, True]   # track_previous_sibling
```

Both become O(1), for one more index per node (28 → 32 bytes). It is off by
default because most trees are not wide and most workloads do not remove much:
when it is off the array stays empty and every line maintaining it compiles
away, so you pay nothing but an empty `List` header per tree.

| remove 2000 children of a 4000-child node, back to front | ns per removal |
| --- | --- |
| `LCRSTree[Int]` | 1718.4 |
| `LCRSTree[Int, DType.uint32, True]` | **110.9** |

Front to back the two are close; the scan is only expensive when what you
remove sits far along the chain.

## API

| Member | Meaning |
| --- | --- |
| `LCRSTree[T](root, capacity=8)` | A tree always has a root, so it is never empty. Pass the eventual node count as `capacity` to skip every reallocation. |
| `reserve(slots)` | Make room for `slots` nodes up front. |
| `add_child(element, parent=0) -> Int` | Append as the last child, in constant time. |
| `add_tree(other, parent=0) -> Int` | Graft a copy of another tree in. |
| `prepend_root(element) -> Int` | Insert a new root above the current one. |
| `remove(index)` | Drop a node and its subtree; slots go on the free list. Removing something already gone does nothing. O(siblings) unless backward links are on. |
| `tree[i]` | A **reference** to the element: no copy on read, mutable in place, and `tree[i] = x` assigns through it. |
| `len(tree)`, `capacity()` | Live nodes, slot count. |
| `for index in tree` / `tree.dfs(root=0)` | Depth-first preorder; uses parent links, so no stack and no recursion. |
| `tree.bfs(root=0)` | Breadth-first. |
| `tree.children(index)` | A node's children, without allocating. |
| `get_dfs_indices()`, `get_bfs_indices()`, `children_indices()`, `ancestor_indices()` | The same as lists. |
| `children_count()`, `depth()`, `parent_of()` | O(children), O(depth), O(1). |
| `is_leaf/is_root/has_sibling/are_siblings/is_free` | Shape predicates; `is_free` reports a released slot. |
| `swap_elements(a, b)` / `swap_nodes(a, b) -> Bool` | Exchange contents / exchange nodes with their subtrees. Also O(siblings) unless backward links are on. |
| `compact_dfs(root=0)` / `compact_bfs(root=0)` | Renumber into traversal order, dropping free slots. |
| `print_tree(tree)` | Free function; needs `Writable` elements. |

## Performance

Bushy tree of 37449 nodes (fan-out 8), Apple M-series, nanoseconds per node.
Reproduce with `pixi run bench`.

Measured in a release build, which is what `pixi run bench` passes
(`-D ASSERT=none`). Bounds checks cost this structure about 2× on build while
being noise for the allocation-heavy baselines, so default-mode numbers
understate it.

| Operation | LCRSTree | Nodes owning a `List` | `ArcPointer` nodes |
| --- | --- | --- | --- |
| build | **3.4** | 25.7 | 83.6 |
| depth-first walk | 1.8 | **1.4** | 2.6 |
| breadth-first walk | **0.8** | 1.0 | — |
| enumerate all children | **0.7** | **0.7** | — |
| create + destroy 20000 8-node trees | **91.0** | 661.9 | — |
| bytes per node | **28** | 48 + an allocation per parent | a heap node + refcount each |
| bytes per tree handle | **40** | 72 | — |

Where the shape is wide rather than bushy:

| Operation (4000 direct children) | LCRSTree | Nodes owning a `List` |
| --- | --- | --- |
| build | **2.9** | 6.5 |
| read the k-th child | 676.3 | **0.3** |

Reading the tables:

- **Building is where LCRS wins** — 2.5× a child-list tree and 7× a pointer
  tree, because adding a node is three array appends and no allocation at all.
  It also holds a node in 20 bytes against 48 plus a per-parent allocation.
- **Depth-first traversal is a wash**, and it is the traversal this layout is
  built for: the parent-link walk needs no stack, so it cannot overflow on a
  deep tree and allocates nothing.
- **Breadth-first and child enumeration cost about 2× a child list**, which is
  the sibling chain doing its job.
- **Wide fan-out used to be the weak spot.** `add_child` appended by walking to
  the end of the sibling chain, making a node with 4000 children quadratic to
  build — 1224 ns per node. Caching the tail of each child chain in a
  `last_child` array brought that to 12.2, at the cost of four bytes a node.
- **Indexed child access is O(k) by design.** If you need the k-th child of a
  wide node in a loop, this is the wrong structure.
- **Small trees are cheap.** Creating and destroying 20000 eight-node trees
  costs 91 ns each against a child-list tree's 662, because a whole tree is two
  allocations: one for the elements, one for every index region together.
- **`compact_dfs()` is worth calling** after a batch of removals: a depth-first
  walk goes from 3.8 to 2.5 ns per node, and in the benchmark it returned
  37449 slots to 1365.

## Development

```bash
pixi run test     # the test suite (60 tests)
pixi run bench    # the benchmarks above
pixi run main     # the example
pixi run format   # mojo format
pixi run docs     # docstring check
pixi build        # build the conda package (needs pixi >= 0.80)
```

## License

MIT. See [LICENSE](LICENSE).
