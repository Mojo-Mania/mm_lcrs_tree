# mm_lcrs_tree

[![CI](https://github.com/Mojo-Mania/mm_lcrs_tree/actions/workflows/ci.yml/badge.svg)](https://github.com/Mojo-Mania/mm_lcrs_tree/actions/workflows/ci.yml)

An n-ary tree for [Mojo](https://mojolang.org), stored as left-child /
right-sibling links in parallel arrays.

Every node keeps two tree links — its **first child** and its **next sibling** —
which encodes a tree of arbitrary arity as a binary one. A node's children are
its first child followed by that child's sibling chain, so a node costs the same
whether it has one child or a thousand, and no node owns a list. The price is
that reaching the k-th child is O(k).

Nodes live in `List`s and are addressed by index; a link pointing at its own
node means "none", so no index value is reserved as a sentinel. Alongside the
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

## API

| Member | Meaning |
| --- | --- |
| `LCRSTree[T](root)` | A tree always has a root, so it is never empty. |
| `add_child(element, parent=0) -> Int` | Append as the last child, in constant time. |
| `add_tree(other, parent=0) -> Int` | Graft a copy of another tree in. |
| `prepend_root(element) -> Int` | Insert a new root above the current one. |
| `remove(index)` | Drop a node and its subtree; slots go on the free list. |
| `tree[i]`, `tree[i] = x`, `len(tree)`, `capacity()` | Element access, live nodes, slot count. |
| `for index in tree` / `tree.dfs(root=0)` | Depth-first preorder; uses parent links, so no stack and no recursion. |
| `tree.bfs(root=0)` | Breadth-first. |
| `tree.children(index)` | A node's children, without allocating. |
| `get_dfs_indices()`, `get_bfs_indices()`, `children_indices()`, `ancestor_indices()` | The same as lists. |
| `children_count()`, `depth()`, `parent_of()` | O(children), O(depth), O(1). |
| `is_leaf/is_root/has_sibling/are_siblings` | Shape predicates. |
| `swap_elements(a, b)` / `swap_nodes(a, b) -> Bool` | Exchange contents / exchange nodes with their subtrees. |
| `compact_dfs(root=0)` / `compact_bfs(root=0)` | Renumber into traversal order, dropping free slots. |
| `print_tree(tree)` | Free function; needs `Writable` elements. |

## Performance

Bushy tree of 37449 nodes (fan-out 8), Apple M-series, nanoseconds per node.
Reproduce with `pixi run bench`.

| Operation | LCRSTree | Nodes owning a `List` | `ArcPointer` nodes |
| --- | --- | --- | --- |
| build | **10.3** | 24.7 | 79.1 |
| depth-first walk | 2.4 | **2.3** | 2.8 |
| breadth-first walk | 4.0 | **1.4** | — |
| enumerate all children | 1.5 | **0.8** | — |
| bytes per node | **24** | 48 + an allocation per parent | a heap node + refcount each |

Where the shape is wide rather than bushy:

| Operation (4000 direct children) | LCRSTree | Nodes owning a `List` |
| --- | --- | --- |
| build | 12.2 | **7.1** |
| read the k-th child | 2177.4 | **0.9** |

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
- **`compact_dfs()` is worth calling** after a batch of removals: a depth-first
  walk goes from 3.8 to 2.5 ns per node, and in the benchmark it returned
  37449 slots to 1365.

## Development

```bash
pixi run test     # the test suite (49 tests)
pixi run bench    # the benchmarks above
pixi run main     # the example
pixi run format   # mojo format
pixi run docs     # docstring check
pixi build        # build the conda package (needs pixi >= 0.80)
```

## License

MIT. See [LICENSE](LICENSE).
