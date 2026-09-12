"""Benchmarks `LCRSTree` against two other ways to hold an n-ary tree.

Baselines:

- `ChildListTree` -- parallel arrays like `LCRSTree`, except every node owns a
  `List` of its child indices. Indexed child access is O(1) instead of O(k),
  paid for with one heap allocation per node that has children.
- `ArcTree` -- a node per element on the heap, each owning a `List` of
  `ArcPointer` children. The shape most people write first.

Shapes matter more than size for this structure, so each build benchmark runs
over a bushy tree (fan-out 8) and a wide one (a root with thousands of direct
children), which is where the sibling-chain append shows up.

Every number is nanoseconds per node. Lower is better.
"""

from mm_lcrs_tree import LCRSTree
from std.benchmark import Unit, keep, run
from std.memory import ArcPointer


comptime DEPTH = 5
comptime FANOUT = 8
"""A bushy tree: 8^5 leaves, 37449 nodes."""

comptime WIDTH = 4_000
"""A wide tree: one root with this many direct children."""


# ===-----------------------------------------------------------------------===#
# Baseline 1: every node owns a List of child indices
# ===-----------------------------------------------------------------------===#


struct ChildListTree[T: Copyable & Deinitable](Copyable, Movable, Sized):
    """Parallel arrays, but each node owns a `List` of its children.

    Parameters:
        T: The element type.
    """

    var elements: List[Self.T]
    var children: List[List[Int]]
    var parent: List[Int]

    def __init__(out self, root: Self.T):
        self.elements = [root.copy()]
        self.children = [List[Int]()]
        self.parent = [0]

    def __len__(self) -> Int:
        return len(self.elements)

    def add_child(mut self, element: Self.T, parent: Int = 0) -> Int:
        var index = len(self.elements)
        self.elements.append(element.copy())
        self.children.append(List[Int]())
        self.parent.append(parent)
        self.children[parent].append(index)
        return index

    def dfs_indices(self) -> List[Int]:
        var result = List[Int]()
        var stack: List[Int] = [0]
        while len(stack) > 0:
            var node = stack.pop()
            result.append(node)
            for i in range(len(self.children[node]) - 1, -1, -1):
                stack.append(self.children[node][i])
        return result^

    def bfs_indices(self) -> List[Int]:
        var result: List[Int] = [0]
        var cursor = 0
        while cursor < len(result):
            var node = result[cursor]
            cursor += 1
            for child in self.children[node]:
                result.append(child)
        return result^


# ===-----------------------------------------------------------------------===#
# Baseline 2: a heap node per element
# ===-----------------------------------------------------------------------===#


struct ArcNode[T: Copyable & Deinitable](Copyable, Movable):
    """A tree node owning its children through reference-counted pointers.

    Parameters:
        T: The element type.
    """

    var value: Self.T
    var children: List[ArcPointer[ArcNode[Self.T]]]

    def __init__(out self, value: Self.T):
        self.value = value.copy()
        self.children = []


def build_arc(depth: Int, fanout: Int, mut counter: Int) -> ArcNode[Int]:
    var node = ArcNode[Int](counter)
    counter += 1
    if depth > 0:
        for _ in range(fanout):
            node.children.append(
                ArcPointer(build_arc(depth - 1, fanout, counter))
            )
    return node^


def sum_arc(root: ArcNode[Int]) -> Int:
    """Walks a pointer tree with an explicit stack.

    Copying an `ArcPointer` onto the stack touches its refcount, which is part
    of what this design costs and what the benchmark is meant to show.
    """
    var total = root.value
    var stack = List[ArcPointer[ArcNode[Int]]]()
    for i in range(len(root.children)):
        stack.append(root.children[i])
    while len(stack) > 0:
        var node = stack.pop()
        total += node[].value
        for i in range(len(node[].children)):
            stack.append(node[].children[i])
    return total


# ===-----------------------------------------------------------------------===#
# Builders and reporting
# ===-----------------------------------------------------------------------===#


def build_lcrs(depth: Int, fanout: Int) -> LCRSTree[Int]:
    var tree = LCRSTree[Int](0)
    var frontier: List[Int] = [0]
    var counter = 1
    for _ in range(depth):
        var next = List[Int]()
        for parent in frontier:
            for _ in range(fanout):
                next.append(tree.add_child(counter, parent))
                counter += 1
        frontier = next^
    return tree^


def build_child_list(depth: Int, fanout: Int) -> ChildListTree[Int]:
    var tree = ChildListTree[Int](0)
    var frontier: List[Int] = [0]
    var counter = 1
    for _ in range(depth):
        var next = List[Int]()
        for parent in frontier:
            for _ in range(fanout):
                next.append(tree.add_child(counter, parent))
                counter += 1
        frontier = next^
    return tree^


def measure(f: Some[ImplicitlyCopyable & (def() raises)]) raises -> Float64:
    return run(f, min_runtime_secs=0.05, max_runtime_secs=1.0).mean(Unit.ns)


def fmt(nanos: Float64) -> String:
    var tenths = Int(nanos * 10.0 + 0.5)
    return String(tenths // 10, ".", tenths % 10)


def header(title: String):
    print("")
    print(title)
    print("  container            ns/node")
    print("  -----------------------------")


def report(name: String, nanos: Float64):
    var padded = name
    while padded.byte_length() < 20:
        padded += " "
    print("  ", padded, fmt(nanos))


def per_node(total_ns: Float64, nodes: Int) -> Float64:
    return total_ns / Float64(nodes)


# ===-----------------------------------------------------------------------===#
# Benchmarks
# ===-----------------------------------------------------------------------===#


def bench_build_bushy() raises:
    var nodes = len(build_lcrs(DEPTH, FANOUT))
    header(
        String("build a bushy tree, fan-out ", FANOUT, ", ", nodes, " nodes")
    )

    def lcrs() raises:
        keep(len(build_lcrs(DEPTH, FANOUT)))

    def child_list() raises:
        keep(len(build_child_list(DEPTH, FANOUT)))

    def arc() raises:
        var counter = 0
        var root = build_arc(DEPTH, FANOUT, counter)
        keep(len(root.children))

    report("LCRSTree", per_node(measure(lcrs), nodes))
    report("ChildListTree", per_node(measure(child_list), nodes))
    report("ArcTree", per_node(measure(arc), nodes))


def bench_build_wide() raises:
    header(String("build a wide tree, one root with ", WIDTH, " children"))

    def lcrs() raises:
        var tree = LCRSTree[Int](0)
        for i in range(WIDTH):
            _ = tree.add_child(i)
        keep(len(tree))

    def child_list() raises:
        var tree = ChildListTree[Int](0)
        for i in range(WIDTH):
            _ = tree.add_child(i)
        keep(len(tree))

    report("LCRSTree", per_node(measure(lcrs), WIDTH))
    report("ChildListTree", per_node(measure(child_list), WIDTH))
    print("   (both append in constant time)")


def bench_traversal() raises:
    var tree = build_lcrs(DEPTH, FANOUT)
    var list_tree = build_child_list(DEPTH, FANOUT)
    var counter = 0
    var arc_root = build_arc(DEPTH, FANOUT, counter)
    var nodes = len(tree)

    header(String("depth-first walk, ", nodes, " nodes"))

    def lcrs_dfs() raises {imm tree}:
        var total = 0
        for index in tree.dfs():
            total += index
        keep(total)

    def list_dfs() raises {imm list_tree}:
        var total = 0
        for index in list_tree.dfs_indices():
            total += index
        keep(total)

    def arc_dfs() raises {imm arc_root}:
        keep(sum_arc(arc_root))

    report("LCRSTree", per_node(measure(lcrs_dfs), nodes))
    report("ChildListTree", per_node(measure(list_dfs), nodes))
    report("ArcTree", per_node(measure(arc_dfs), nodes))

    header(String("breadth-first walk, ", nodes, " nodes"))

    def lcrs_bfs() raises {imm tree}:
        var total = 0
        for index in tree.bfs():
            total += index
        keep(total)

    def list_bfs() raises {imm list_tree}:
        var total = 0
        for index in list_tree.bfs_indices():
            total += index
        keep(total)

    report("LCRSTree", per_node(measure(lcrs_bfs), nodes))
    report("ChildListTree", per_node(measure(list_bfs), nodes))


def bench_children() raises:
    var tree = build_lcrs(DEPTH, FANOUT)
    var list_tree = build_child_list(DEPTH, FANOUT)
    var nodes = len(tree)

    header(String("enumerate every node's children, ", nodes, " nodes"))

    def lcrs_children() raises {imm tree, imm nodes}:
        var total = 0
        for node in range(nodes):
            for child in tree.children(node):
                total += child
        keep(total)

    def list_children() raises {imm list_tree, imm nodes}:
        var total = 0
        for node in range(nodes):
            for child in list_tree.children[node]:
                total += child
        keep(total)

    report("LCRSTree", per_node(measure(lcrs_children), nodes))
    report("ChildListTree", per_node(measure(list_children), nodes))


def bench_nth_child() raises:
    var tree = LCRSTree[Int](0)
    for i in range(WIDTH):
        _ = tree.add_child(i)
    var list_tree = ChildListTree[Int](0)
    for i in range(WIDTH):
        _ = list_tree.add_child(i)

    header(String("read the k-th child of a node with ", WIDTH, " children"))

    def lcrs_nth() raises {imm tree}:
        var total = 0
        for k in range(0, WIDTH, 64):
            var seen = 0
            for child in tree.children(0):
                if seen == k:
                    total += child
                    break
                seen += 1
        keep(total)

    def list_nth() raises {imm list_tree}:
        var total = 0
        for k in range(0, WIDTH, 64):
            total += list_tree.children[0][k]
        keep(total)

    var probes = WIDTH // 64
    report("LCRSTree", per_node(measure(lcrs_nth), probes))
    report("ChildListTree", per_node(measure(list_nth), probes))
    print("   (per lookup, not per node)")


def bench_remove_wide() raises:
    """Removing from a wide node, with and without backward sibling links.

    Children are removed back to front, which is the worst case for the
    forward scan `_detach` falls back on: every removal walks almost the whole
    chain. Removing front to back would barely show a difference.
    """
    header(
        String(
            "remove ",
            WIDTH // 2,
            " children of a wide node, back to front (build included)",
        )
    )

    def without() raises:
        var tree = LCRSTree[Int](0)
        var kids = List[Int]()
        for i in range(WIDTH):
            kids.append(tree.add_child(i))
        for i in range(WIDTH - 1, -1, -2):
            tree.remove(kids[i])
        keep(len(tree))

    def with_links() raises:
        var tree = LCRSTree[Int, DType.uint32, True](0)
        var kids = List[Int]()
        for i in range(WIDTH):
            kids.append(tree.add_child(i))
        for i in range(WIDTH - 1, -1, -2):
            tree.remove(kids[i])
        keep(len(tree))

    report("backward links off", per_node(measure(without), WIDTH // 2))
    report("backward links on", per_node(measure(with_links), WIDTH // 2))


def bench_compaction() raises:
    # Build breadth-first, then remove half the nodes, so the live nodes are
    # scattered across the slot array -- the state compaction exists to fix.
    var scattered = build_lcrs(DEPTH, FANOUT)
    var doomed = List[Int]()
    for node in scattered.dfs():
        if node % 2 == 1 and not scattered.is_root(node):
            doomed.append(node)
    for node in doomed:
        if node < scattered.capacity():
            scattered.remove(node)

    var compacted = scattered.copy()
    compacted.compact_dfs()
    var nodes = len(compacted)

    header(String("depth-first walk after removals, ", nodes, " nodes"))

    def before() raises {imm scattered}:
        var total = 0
        for index in scattered.dfs():
            total += index
        keep(total)

    def after() raises {imm compacted}:
        var total = 0
        for index in compacted.dfs():
            total += index
        keep(total)

    report("as built", per_node(measure(before), nodes))
    report("after compact_dfs", per_node(measure(after), nodes))
    print(
        "   slots: ",
        scattered.capacity(),
        "before, ",
        compacted.capacity(),
        "after",
    )


def report_memory() raises:
    var tree = build_lcrs(DEPTH, FANOUT)
    var nodes = len(tree)
    # Four arrays: one element plus three indices per node.
    var lcrs_bytes = nodes * (8 + 4 * 4)
    # Elements, parents, and a List header per node, plus its child slots.
    var list_bytes = nodes * (8 + 8 + 24 + 8)
    print("")
    print("approximate bytes per node (Int elements, uint32 indices)")
    print("   LCRSTree           ", lcrs_bytes // nodes)
    print(
        "   ChildListTree      ",
        list_bytes // nodes,
        "plus one allocation per parent",
    )
    print("   ArcTree            ", "a heap node and refcount per element")


def main() raises:
    print("LCRSTree benchmarks -- times are ns per node")
    bench_build_bushy()
    bench_build_wide()
    bench_traversal()
    bench_children()
    bench_nth_child()
    bench_remove_wide()
    bench_compaction()
    report_memory()
