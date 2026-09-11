from mm_lcrs_tree import LCRSTree, LCRSTreeBuilder
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
)


def sample() -> LCRSTree[Int]:
    """Builds 0:(1:(4, 5), 2, 3:(6))."""
    var tree = LCRSTree[Int](0)
    var a = tree.add_child(1)
    _ = tree.add_child(2)
    var c = tree.add_child(3)
    _ = tree.add_child(4, a)
    _ = tree.add_child(5, a)
    _ = tree.add_child(6, c)
    return tree^


def assert_indices(actual: List[Int], expected: List[Int]) raises:
    assert_equal(len(actual), len(expected))
    for i in range(len(expected)):
        assert_equal(actual[i], expected[i])


def assert_consistent(tree: LCRSTree[Int]) raises:
    """Checks the invariants every structural change has to preserve.

    Children agree with their parent, node 0 is the only root, the reachable
    node count matches `len()`, and the cached tail of each child chain is the
    node the chain actually ends at.
    """
    var seen = 0
    for node in tree.dfs():
        seen += 1
        var last = -1
        for child in tree.children(node):
            assert_equal(
                tree.parent_of(child),
                node,
                String("child ", child, " disagrees about its parent"),
            )
            last = child
        var cached = Int(tree._last_child[node])
        if last == -1:
            assert_equal(
                cached,
                node,
                String("node ", node, " caches a tail but has no children"),
            )
        else:
            assert_equal(
                cached,
                last,
                String("node ", node, " has a stale last_child"),
            )
        if tree.is_root(node):
            assert_equal(node, 0)
    assert_equal(seen, len(tree), "reachable nodes do not match len()")


# ===-----------------------------------------------------------------------===#
# Shape
# ===-----------------------------------------------------------------------===#


def test_root_only() raises:
    var tree = LCRSTree[Int](7)
    assert_equal(len(tree), 1)
    assert_equal(tree[0], 7)
    assert_true(tree.is_root(0))
    assert_true(tree.is_leaf(0))
    assert_false(tree.has_sibling(0))
    assert_equal(tree.children_count(0), 0)
    assert_equal(len(tree.ancestor_indices(0)), 0)
    assert_equal(tree.depth(0), 0)


def test_add_child_order() raises:
    var tree = sample()
    assert_equal(len(tree), 7)
    assert_indices(tree.children_indices(0), [1, 2, 3])
    assert_indices(tree.children_indices(1), [4, 5])
    assert_indices(tree.children_indices(3), [6])
    assert_equal(tree.children_count(0), 3)
    assert_consistent(tree)


def test_element_access() raises:
    var tree = sample()
    assert_equal(tree[4], 4)
    tree[4] = 40
    assert_equal(tree[4], 40)


def test_ancestors_and_depth() raises:
    var tree = sample()
    assert_indices(tree.ancestor_indices(4), [1, 0])
    assert_equal(tree.depth(4), 2)
    assert_equal(tree.depth(1), 1)
    assert_equal(tree.parent_of(4), 1)
    assert_equal(tree.parent_of(0), 0)


def test_predicates() raises:
    var tree = sample()
    assert_true(tree.is_leaf(4))
    assert_false(tree.is_leaf(1))
    assert_true(tree.are_siblings(1, 3))
    assert_false(tree.are_siblings(1, 4))
    assert_true(tree.has_sibling(1))
    assert_false(tree.has_sibling(3))


# ===-----------------------------------------------------------------------===#
# Traversal
# ===-----------------------------------------------------------------------===#


def test_dfs_order() raises:
    assert_indices(sample().get_dfs_indices(), [0, 1, 4, 5, 2, 3, 6])


def test_bfs_order() raises:
    assert_indices(sample().get_bfs_indices(), [0, 1, 2, 3, 4, 5, 6])


def test_dfs_from_subtree() raises:
    assert_indices(sample().get_dfs_indices(1), [1, 4, 5])
    assert_indices(sample().get_dfs_indices(3), [3, 6])
    assert_indices(sample().get_dfs_indices(4), [4])


def test_bfs_from_subtree() raises:
    assert_indices(sample().get_bfs_indices(1), [1, 4, 5])
    assert_indices(sample().get_bfs_indices(4), [4])


def test_iteration_is_dfs() raises:
    var tree = sample()
    var seen = List[Int]()
    for index in tree:
        seen.append(index)
    assert_indices(seen, [0, 1, 4, 5, 2, 3, 6])


def test_children_iterator_on_leaf() raises:
    var tree = sample()
    var count = 0
    for _ in tree.children(4):
        count += 1
    assert_equal(count, 0)


def test_dfs_on_deep_tree_does_not_recurse() raises:
    # A chain deep enough to blow a recursive traversal's stack.
    var tree = LCRSTree[Int](0)
    var parent = 0
    for i in range(1, 50_000):
        parent = tree.add_child(i, parent)
    assert_equal(len(tree), 50_000)
    var count = 0
    var last = -1
    for index in tree.dfs():
        count += 1
        last = index
    assert_equal(count, 50_000)
    assert_equal(tree[last], 49_999)


# ===-----------------------------------------------------------------------===#
# Grafting and roots
# ===-----------------------------------------------------------------------===#


def test_add_tree_to_root() raises:
    var tree = sample()
    var other = LCRSTree[Int](100)
    _ = other.add_child(101)
    var grafted = tree.add_tree(other)
    assert_equal(tree[grafted], 100)
    assert_equal(tree.parent_of(grafted), 0)
    assert_indices(tree.children_indices(0), [1, 2, 3, grafted])
    assert_consistent(tree)


def test_add_tree_to_inner_node() raises:
    """Regression: the 2023 version hard-coded the grafted root's parent to 0.

    Grafting onto anything but the root left `parent` pointing at the root, so
    `ancestor_indices`, `depth` and `remove` all disagreed with the child
    links.
    """
    var tree = sample()
    var other = LCRSTree[Int](100)
    _ = other.add_child(101)
    var grafted = tree.add_tree(other, 1)
    assert_equal(tree.parent_of(grafted), 1)
    assert_equal(tree.depth(grafted), 2)
    assert_indices(tree.ancestor_indices(grafted), [1, 0])
    assert_indices(tree.children_indices(1), [4, 5, grafted])
    assert_consistent(tree)


def test_add_tree_leaves_source_alone() raises:
    var tree = LCRSTree[Int](0)
    var other = LCRSTree[Int](100)
    _ = other.add_child(101)
    _ = tree.add_tree(other)
    assert_equal(len(other), 2)
    assert_indices(other.get_dfs_indices(), [0, 1])


def test_prepend_root() raises:
    var tree = sample()
    var moved = tree.prepend_root(99)
    assert_equal(tree[0], 99)
    assert_equal(tree[moved], 0)
    assert_equal(tree.parent_of(moved), 0)
    assert_equal(len(tree), 8)
    assert_indices(tree.children_indices(0), [moved])
    assert_indices(tree.children_indices(moved), [1, 2, 3])
    assert_equal(tree.depth(4), 3)
    assert_consistent(tree)


def test_prepend_root_twice() raises:
    var tree = LCRSTree[Int](1)
    _ = tree.prepend_root(2)
    _ = tree.prepend_root(3)
    assert_equal(tree[0], 3)
    assert_equal(len(tree), 3)
    assert_equal(len(tree.get_dfs_indices()), 3)
    assert_consistent(tree)


# ===-----------------------------------------------------------------------===#
# Removal
# ===-----------------------------------------------------------------------===#


def test_remove_leaf() raises:
    var tree = sample()
    tree.remove(4)
    assert_equal(len(tree), 6)
    assert_indices(tree.children_indices(1), [5])
    assert_consistent(tree)


def test_remove_middle_child() raises:
    var tree = sample()
    tree.remove(2)
    assert_indices(tree.children_indices(0), [1, 3])
    assert_consistent(tree)


def test_remove_last_child() raises:
    var tree = sample()
    tree.remove(3)
    assert_indices(tree.children_indices(0), [1, 2])
    assert_consistent(tree)


def test_remove_subtree() raises:
    var tree = sample()
    tree.remove(1)
    assert_equal(len(tree), 4)
    assert_indices(tree.get_dfs_indices(), [0, 2, 3, 6])
    assert_consistent(tree)


def test_removed_slots_are_reused() raises:
    var tree = sample()
    var before = tree.capacity()
    tree.remove(1)
    var added = tree.add_child(50)
    assert_true(added < before, "a freed slot should have been reused")
    assert_equal(tree.capacity(), before)
    assert_consistent(tree)


def test_remove_root_empties_the_tree() raises:
    """Regression: the 2023 version cleared the node arrays but kept the free
    list, so the next insert reused an index past the end of the arrays."""
    var tree = sample()
    tree.remove(0)
    assert_equal(len(tree), 1)
    assert_equal(tree.capacity(), 1)
    assert_equal(tree.children_count(0), 0)
    var added = tree.add_child(42)
    assert_equal(added, 1)
    assert_equal(tree[added], 42)
    assert_equal(len(tree), 2)
    assert_consistent(tree)


# ===-----------------------------------------------------------------------===#
# Appending stays correct as the shape changes
#
# `add_child` appends through a cached tail pointer rather than walking the
# sibling chain, so every operation that can change which node ends a chain has
# to maintain it. These pin that down; `assert_consistent` checks the cached
# tail against the real chain for every node.
# ===-----------------------------------------------------------------------===#


def test_append_keeps_order_when_wide() raises:
    var tree = LCRSTree[Int](0)
    for i in range(1000):
        _ = tree.add_child(i)
    var seen = List[Int]()
    for child in tree.children(0):
        seen.append(tree[child])
    assert_equal(len(seen), 1000)
    for i in range(1000):
        assert_equal(seen[i], i)
    assert_consistent(tree)


def test_append_after_removing_last_child() raises:
    var tree = sample()
    tree.remove(3)
    var added = tree.add_child(30)
    assert_indices(tree.children_indices(0), [1, 2, added])
    assert_consistent(tree)


def test_append_after_removing_only_child() raises:
    var tree = sample()
    tree.remove(6)
    assert_true(tree.is_leaf(3))
    var added = tree.add_child(60, 3)
    assert_indices(tree.children_indices(3), [added])
    assert_consistent(tree)


def test_append_after_removing_first_of_two() raises:
    var tree = sample()
    tree.remove(4)
    var added = tree.add_child(40, 1)
    assert_indices(tree.children_indices(1), [5, added])
    assert_consistent(tree)


def test_append_after_swap() raises:
    var tree = sample()
    assert_true(tree.swap_nodes(1, 3))
    var added = tree.add_child(70)
    assert_indices(tree.children_indices(0), [3, 2, 1, added])
    assert_consistent(tree)


def test_append_after_swapping_the_last_child() raises:
    var tree = sample()
    assert_true(tree.swap_nodes(3, 4))
    var added = tree.add_child(80)
    assert_indices(tree.children_indices(0), [1, 2, 4, added])
    assert_consistent(tree)


def test_append_after_prepend_root() raises:
    var tree = sample()
    var moved = tree.prepend_root(99)
    var added = tree.add_child(90, moved)
    assert_indices(tree.children_indices(moved), [1, 2, 3, added])
    assert_consistent(tree)


def test_append_after_add_tree() raises:
    var tree = sample()
    var other = LCRSTree[Int](100)
    _ = other.add_child(101)
    var grafted = tree.add_tree(other)
    var added = tree.add_child(102, grafted)
    assert_indices(tree.children_indices(grafted), [grafted + 1, added])
    assert_consistent(tree)


def test_append_after_compaction() raises:
    var tree = sample()
    tree.remove(2)
    tree.compact_dfs()
    var added = tree.add_child(20)
    assert_equal(tree[added], 20)
    var elements = List[Int]()
    for child in tree.children(0):
        elements.append(tree[child])
    assert_indices(elements, [1, 3, 20])
    assert_consistent(tree)


def test_append_reusing_a_freed_slot() raises:
    var tree = sample()
    tree.remove(1)
    var first = tree.add_child(10)
    var second = tree.add_child(11)
    assert_indices(tree.children_indices(0), [2, 3, first, second])
    assert_consistent(tree)


# ===-----------------------------------------------------------------------===#
# Swapping
# ===-----------------------------------------------------------------------===#


def test_swap_elements() raises:
    var tree = sample()
    tree.swap_elements(1, 3)
    assert_equal(tree[1], 3)
    assert_equal(tree[3], 1)
    assert_indices(tree.get_dfs_indices(), [0, 1, 4, 5, 2, 3, 6])


def test_swap_two_leaves() raises:
    var tree = sample()
    assert_true(tree.swap_nodes(4, 2))
    assert_equal(tree[4], 2)
    assert_equal(tree[2], 4)
    assert_consistent(tree)


def test_swap_siblings_moves_subtrees() raises:
    var tree = sample()
    assert_true(tree.swap_nodes(1, 3))
    assert_indices(tree.children_indices(0), [3, 2, 1])
    assert_indices(tree.children_indices(1), [4, 5])
    assert_indices(tree.children_indices(3), [6])
    assert_consistent(tree)


def test_swap_adjacent_siblings() raises:
    var tree = sample()
    assert_true(tree.swap_nodes(1, 2))
    assert_indices(tree.children_indices(0), [2, 1, 3])
    assert_consistent(tree)


def test_swap_across_parents() raises:
    var tree = sample()
    assert_true(tree.swap_nodes(1, 6))
    assert_indices(tree.children_indices(0), [6, 2, 3])
    assert_indices(tree.children_indices(3), [1])
    assert_indices(tree.children_indices(1), [4, 5])
    assert_equal(tree.parent_of(1), 3)
    assert_equal(tree.parent_of(6), 0)
    assert_consistent(tree)


def test_swap_rejects_root_and_self() raises:
    var tree = sample()
    assert_false(tree.swap_nodes(0, 1))
    assert_false(tree.swap_nodes(2, 2))
    assert_consistent(tree)


def test_swap_rejects_ancestor() raises:
    """Regression: the 2023 version reported False for swaps it had performed,
    and attempted ancestor swaps that corrupted the tree."""
    var tree = sample()
    assert_false(tree.swap_nodes(1, 4))
    assert_false(tree.swap_nodes(4, 1))
    assert_indices(tree.children_indices(1), [4, 5])
    assert_consistent(tree)


# ===-----------------------------------------------------------------------===#
# Compaction
# ===-----------------------------------------------------------------------===#


def test_compact_dfs_renumbers() raises:
    var tree = sample()
    tree.compact_dfs()
    assert_equal(len(tree), 7)
    assert_indices(tree.get_dfs_indices(), [0, 1, 2, 3, 4, 5, 6])
    var elements = List[Int]()
    for index in tree.dfs():
        elements.append(tree[index])
    assert_indices(elements, [0, 1, 4, 5, 2, 3, 6])
    assert_consistent(tree)


def test_compact_bfs_renumbers() raises:
    var tree = sample()
    tree.compact_bfs()
    var elements = List[Int]()
    for index in tree.bfs():
        elements.append(tree[index])
    assert_indices(elements, [0, 1, 2, 3, 4, 5, 6])
    assert_consistent(tree)


def test_compact_reclaims_free_slots() raises:
    var tree = sample()
    tree.remove(1)
    assert_equal(tree.capacity(), 7)
    tree.compact_dfs()
    assert_equal(tree.capacity(), 4)
    assert_equal(len(tree), 4)
    assert_consistent(tree)


def test_compact_to_subtree() raises:
    var tree = sample()
    tree.compact_dfs(1)
    assert_equal(len(tree), 3)
    assert_equal(tree[0], 1)
    assert_true(tree.is_root(0))
    assert_indices(tree.children_indices(0), [1, 2])
    assert_consistent(tree)


# ===-----------------------------------------------------------------------===#
# Builder, generality
# ===-----------------------------------------------------------------------===#


def test_builder() raises:
    var tree = (
        LCRSTreeBuilder[Int](1)
        .node(5)
        .leaf(7)
        .up()
        .node(10)
        .node(15)
        .leaf(13)
        .leaf(17)
        .up()
        .leaf(45)
        .tree()
    )
    assert_equal(len(tree), 8)
    var elements = List[Int]()
    for index in tree.dfs():
        elements.append(tree[index])
    assert_indices(elements, [1, 5, 7, 10, 15, 13, 17, 45])
    assert_consistent(tree)


def test_builder_extra_up_is_harmless() raises:
    var tree = LCRSTreeBuilder[Int](1).leaf(2).up().up().up().leaf(3).tree()
    assert_equal(len(tree), 3)
    assert_indices(tree.children_indices(0), [1, 2])


def test_string_elements() raises:
    var tree = LCRSTree[String]("/")
    var etc = tree.add_child("etc")
    _ = tree.add_child("hosts", etc)
    assert_equal(tree[0], "/")
    assert_equal(tree[etc], "etc")
    assert_equal(len(tree), 3)


def test_narrow_index_type() raises:
    var tree = LCRSTree[Int, DType.uint16](0)
    for i in range(1000):
        _ = tree.add_child(i)
    assert_equal(len(tree), 1001)
    assert_equal(tree.children_count(0), 1000)


def test_copy_is_independent() raises:
    var tree = sample()
    var duplicate = tree.copy()
    _ = duplicate.add_child(9)
    assert_equal(len(tree), 7)
    assert_equal(len(duplicate), 8)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
