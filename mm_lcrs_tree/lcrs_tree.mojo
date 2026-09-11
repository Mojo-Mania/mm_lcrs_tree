"""An n-ary tree stored as left-child / right-sibling links in parallel arrays.

Every node keeps exactly two links -- its *first child* and its *next sibling*
-- which encodes a tree of arbitrary arity as a binary one. A node's children
are its first child followed by that child's sibling chain, so a node costs the
same whether it has one child or a thousand, at the price of O(k) to reach the
k-th child.

Nodes live in parallel `List`s and are addressed by index; a link that points at
its own node means "none", so no index value has to be reserved as a sentinel.
Alongside the two tree links this implementation keeps a `parent` array, which
makes upward walks, removal and node swaps possible, and a free list, so slots
released by `remove` are reused by later inserts.

```mojo
from mm_lcrs_tree import LCRSTree

var tree = LCRSTree[String]("/")
var etc = tree.add_child("etc")
_ = tree.add_child("hosts", etc)
_ = tree.add_child("usr")

for index in tree.dfs():
    print(tree[index])
```
"""


struct LCRSTree[T: Copyable & Deinitable, I: DType = DType.uint32](
    Copyable, Iterable, Movable, Sized
):
    """A tree of arbitrary arity, stored as left-child / right-sibling links.

    Parameters:
        T: The element type stored at each node.
        I: The unsigned integer type used for node indices. The default
            `uint32` allows a little over four billion nodes; `uint16` quarters
            the memory used by the link arrays but caps the tree at 65535
            nodes.

    A tree always has a root, so it is never empty; construct it with the root
    element. Nodes are referred to by index, which stays stable until
    `compact_dfs`/`compact_bfs` renumbers them.
    """

    comptime Index = Scalar[Self.I]
    """The scalar type used for node indices."""

    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = _DfsIter[Self.T, Self.I, iterable_origin]
    """The iterator returned by `__iter__`: depth-first from the root."""

    var _elements: List[Self.T]
    """The element of every node slot."""
    var _left_child: List[Self.Index]
    """First child of every node; a node points at itself when it has none."""
    var _right_sibling: List[Self.Index]
    """Next sibling of every node; a node points at itself when it has none."""
    var _parent: List[Self.Index]
    """Parent of every node; the root points at itself."""
    var _free: List[Self.Index]
    """Slots released by `remove`, reused by later inserts."""

    # ===-------------------------------------------------------------------===#
    # Lifecycle
    # ===-------------------------------------------------------------------===#

    def __init__(out self, root: Self.T):
        """Constructs a tree holding a single root node.

        Args:
            root: The element to store at the root.
        """
        self._elements = [root.copy()]
        self._left_child = [0]
        self._right_sibling = [0]
        self._parent = [0]
        self._free = []

    # ===-------------------------------------------------------------------===#
    # Size and element access
    # ===-------------------------------------------------------------------===#

    @always_inline
    def __len__(self) -> Int:
        """Returns the number of live nodes.

        Returns:
            The node count, excluding slots on the free list.
        """
        return len(self._elements) - len(self._free)

    def __getitem__(self, index: Int) -> Self.T:
        """Returns a copy of the element at `index`.

        Args:
            index: The node index.

        Returns:
            The element stored there.
        """
        return self._elements[index].copy()

    def __setitem__(mut self, index: Int, element: Self.T):
        """Replaces the element at `index`.

        Args:
            index: The node index.
            element: The new element.
        """
        self._elements[index] = element.copy()

    def capacity(self) -> Int:
        """Returns the number of node slots, live and free.

        Node indices are always below this, which is what `compact_dfs` shrinks.

        Returns:
            The slot count.
        """
        return len(self._elements)

    # ===-------------------------------------------------------------------===#
    # Structure queries
    # ===-------------------------------------------------------------------===#

    @always_inline
    def is_leaf(self, index: Int) -> Bool:
        """Returns whether the node has no children.

        Args:
            index: The node index.

        Returns:
            True if the node has no children.
        """
        return Int(self._left_child[index]) == index

    @always_inline
    def is_root(self, index: Int) -> Bool:
        """Returns whether the node has no parent.

        Args:
            index: The node index.

        Returns:
            True if the node is the root.
        """
        return Int(self._parent[index]) == index

    @always_inline
    def has_sibling(self, index: Int) -> Bool:
        """Returns whether the node has a next sibling.

        Args:
            index: The node index.

        Returns:
            True if a sibling follows this node.
        """
        return Int(self._right_sibling[index]) != index

    def are_siblings(self, a: Int, b: Int) -> Bool:
        """Returns whether two nodes share a parent.

        Args:
            a: The first node index.
            b: The second node index.

        Returns:
            True if both nodes have the same parent.
        """
        return self._parent[a] == self._parent[b]

    def parent_of(self, index: Int) -> Int:
        """Returns the parent of `index`, or `index` itself for the root.

        Args:
            index: The node index.

        Returns:
            The parent node index.
        """
        return Int(self._parent[index])

    def children_count(self, index: Int) -> Int:
        """Returns how many children the node has.

        Counting walks the sibling chain, so this is O(number of children).

        Args:
            index: The node index.

        Returns:
            The number of children.
        """
        var count = 0
        for _ in self.children(index):
            count += 1
        return count

    def children_indices(self, index: Int) -> List[Int]:
        """Returns the indices of the node's children, in order.

        Prefer `children()` when the list itself is not needed; it walks the
        same chain without allocating.

        Args:
            index: The node index.

        Returns:
            The child indices, first child first.
        """
        var result = List[Int]()
        for child in self.children(index):
            result.append(child)
        return result^

    def ancestor_indices(self, index: Int) -> List[Int]:
        """Returns the node's ancestors, closest first, ending at the root.

        Args:
            index: The node index.

        Returns:
            The ancestor indices; empty for the root.
        """
        var result = List[Int]()
        var node = index
        while not self.is_root(node):
            node = Int(self._parent[node])
            result.append(node)
        return result^

    def depth(self, index: Int) -> Int:
        """Returns the number of edges between `index` and the root.

        Args:
            index: The node index.

        Returns:
            0 for the root, 1 for its children, and so on.
        """
        var result = 0
        var node = index
        while not self.is_root(node):
            node = Int(self._parent[node])
            result += 1
        return result

    # ===-------------------------------------------------------------------===#
    # Traversal
    # ===-------------------------------------------------------------------===#

    def children(
        self, index: Int
    ) -> _ChildIter[Self.T, Self.I, origin_of(self)]:
        """Returns an iterator over the node's children, in order.

        Args:
            index: The node index.

        Returns:
            An iterator yielding child indices.
        """
        var first = Int(self._left_child[index])
        return {src = Pointer(to=self), node = -1 if first == index else first}

    def dfs(self, root: Int = 0) -> _DfsIter[Self.T, Self.I, origin_of(self)]:
        """Returns a depth-first (preorder) iterator over a subtree.

        The walk uses the parent links instead of a stack, so it allocates
        nothing and cannot overflow on a deep tree.

        Args:
            root: The node to start from; its subtree is what gets visited.

        Returns:
            An iterator yielding node indices, `root` first.
        """
        return {src = Pointer(to=self), root = root}

    def bfs(self, root: Int = 0) -> _BfsIter[Self.T, Self.I, origin_of(self)]:
        """Returns a breadth-first iterator over a subtree.

        Args:
            root: The node to start from; its subtree is what gets visited.

        Returns:
            An iterator yielding node indices level by level.
        """
        return {src = Pointer(to=self), root = root}

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        """Returns a depth-first iterator over the whole tree.

        Returns:
            An iterator yielding every node index, root first.
        """
        return {src = Pointer(to=self), root = 0}

    def get_dfs_indices(self, root: Int = 0) -> List[Int]:
        """Returns every node of a subtree in depth-first (preorder) order.

        Args:
            root: The node to start from.

        Returns:
            The node indices in visit order.
        """
        var result = List[Int]()
        for index in self.dfs(root):
            result.append(index)
        return result^

    def get_bfs_indices(self, root: Int = 0) -> List[Int]:
        """Returns every node of a subtree in breadth-first order.

        Args:
            root: The node to start from.

        Returns:
            The node indices in visit order.
        """
        var result = List[Int]()
        for index in self.bfs(root):
            result.append(index)
        return result^

    @always_inline
    def _dfs_successor(self, node: Int, root: Int) -> Int:
        """Returns the next node in preorder within `root`'s subtree, or -1."""
        if not self.is_leaf(node):
            return Int(self._left_child[node])
        var current = node
        while current != root:
            if self.has_sibling(current):
                return Int(self._right_sibling[current])
            current = Int(self._parent[current])
            if self.is_root(current) and current != root:
                # Walked past the subtree without finding a sibling.
                return -1
        return -1

    # ===-------------------------------------------------------------------===#
    # Mutation
    # ===-------------------------------------------------------------------===#

    def add_child(mut self, element: Self.T, parent: Int = 0) -> Int:
        """Appends a new node as the last child of `parent`.

        Args:
            element: The element to store.
            parent: The index of the node to attach to.

        Returns:
            The index of the new node.
        """
        var index = self._claim_slot(element)
        self._parent[index] = Self.Index(parent)
        self._append_child(parent, index)
        return index

    def add_tree(mut self, other: Self, parent: Int = 0) -> Int:
        """Grafts a copy of `other` in as the last child of `parent`.

        Args:
            other: The tree to copy in. It is left unchanged.
            parent: The index of the node to attach the copy to.

        Returns:
            The index of the copied tree's root.
        """
        var offset = len(self._elements)
        for i in range(len(other._elements)):
            self._elements.append(other._elements[i].copy())
            self._left_child.append(other._left_child[i] + Self.Index(offset))
            self._right_sibling.append(
                other._right_sibling[i] + Self.Index(offset)
            )
            self._parent.append(other._parent[i] + Self.Index(offset))
        for i in range(len(other._free)):
            self._free.append(other._free[i] + Self.Index(offset))

        # The copied root's parent is the node we are attaching it to. The 2023
        # version hard-coded 0 here, which silently corrupted `parent` whenever
        # a tree was grafted onto anything but the root.
        self._parent[offset] = Self.Index(parent)
        self._append_child(parent, offset)
        return offset

    def prepend_root(mut self, element: Self.T) -> Int:
        """Inserts a new root above the current one, which becomes its child.

        Args:
            element: The element for the new root.

        Returns:
            The index the old root moved to.
        """
        var old_root = self._elements[0].copy()
        # A self-pointer means "no child", so the old root's sentinel cannot be
        # copied verbatim: at its new index it would point at the new root and
        # close a cycle. Read the real child before claiming the slot.
        var had_child = not self.is_leaf(0)
        var first_child = Int(self._left_child[0])

        var moved = self._claim_slot(old_root)
        if had_child:
            self._left_child[moved] = Self.Index(first_child)
        self._right_sibling[moved] = Self.Index(moved)
        self._parent[moved] = 0

        self._elements[0] = element.copy()
        self._left_child[0] = Self.Index(moved)
        self._right_sibling[0] = 0
        self._parent[0] = 0

        for child in self.children(moved):
            self._parent[child] = Self.Index(moved)
        return moved

    def remove(mut self, index: Int):
        """Removes a node and its whole subtree.

        Removing the root empties the tree of everything but the root slot,
        whose element is left as it was.

        Args:
            index: The node index to remove.
        """
        if index == 0:
            # The 2023 version cleared the node arrays but left the free list
            # populated, so the next insert reused an out-of-range slot.
            var root_element = self._elements[0].copy()
            self._elements = [root_element^]
            self._left_child = [0]
            self._right_sibling = [0]
            self._parent = [0]
            self._free = []
            return

        self._detach(index)
        for node in self.bfs(index):
            self._free.append(Self.Index(node))

    def swap_elements(mut self, a: Int, b: Int):
        """Exchanges the elements of two nodes, leaving the shape alone.

        Args:
            a: The first node index.
            b: The second node index.
        """
        self._elements.swap_elements(a, b)

    def swap_nodes(mut self, a: Int, b: Int) -> Bool:
        """Exchanges two nodes, moving their subtrees with them.

        Neither node may be the root, and neither may be an ancestor of the
        other.

        Args:
            a: The first node index.
            b: The second node index.

        Returns:
            True if the nodes were exchanged.
        """
        if a == b:
            return False
        if self.is_leaf(a) and self.is_leaf(b):
            self.swap_elements(a, b)
            return True
        if self.is_root(a) or self.is_root(b):
            return False
        for ancestor in self.ancestor_indices(a):
            if ancestor == b:
                return False
        for ancestor in self.ancestor_indices(b):
            if ancestor == a:
                return False

        var parent_a = Int(self._parent[a])
        var parent_b = Int(self._parent[b])
        var sibling_a = Int(self._right_sibling[a])
        var sibling_b = Int(self._right_sibling[b])
        var previous_a = self._previous_sibling(a)
        var previous_b = self._previous_sibling(b)

        # Unhook both, then hook each into the other's place. Order matters
        # when the two are siblings, so the incoming links are read first.
        self._parent[a] = Self.Index(parent_b)
        self._parent[b] = Self.Index(parent_a)

        self._relink(parent_a, previous_a, b)
        self._relink(parent_b, previous_b, a)

        self._right_sibling[b] = Self.Index(b if sibling_a == a else sibling_a)
        self._right_sibling[a] = Self.Index(a if sibling_b == b else sibling_b)

        # If they were adjacent siblings the steps above can leave one pointing
        # at itself through the other; fix the direct link.
        if sibling_a == b:
            self._right_sibling[b] = Self.Index(a)
        elif sibling_b == a:
            self._right_sibling[a] = Self.Index(b)
        return True

    def compact_dfs(mut self, root: Int = 0):
        """Renumbers the nodes into depth-first order, dropping free slots.

        Node indices change. Anything outside `root`'s subtree is discarded.

        Args:
            root: The subtree to keep.
        """
        self._compact(self.get_dfs_indices(root))

    def compact_bfs(mut self, root: Int = 0):
        """Renumbers the nodes into breadth-first order, dropping free slots.

        Node indices change. Anything outside `root`'s subtree is discarded.

        Args:
            root: The subtree to keep.
        """
        self._compact(self.get_bfs_indices(root))

    # ===-------------------------------------------------------------------===#
    # Internals
    # ===-------------------------------------------------------------------===#

    def _claim_slot(mut self, element: Self.T) -> Int:
        """Returns a fresh node slot, reusing a freed one when available."""
        if len(self._free) == 0:
            var index = len(self._elements)
            debug_assert(
                index <= Int(Self.Index.MAX),
                "LCRSTree: node index type is too narrow for this many nodes",
            )
            self._elements.append(element.copy())
            self._left_child.append(Self.Index(index))
            self._right_sibling.append(Self.Index(index))
            self._parent.append(Self.Index(index))
            return index
        var index = Int(self._free.pop())
        self._elements[index] = element.copy()
        self._left_child[index] = Self.Index(index)
        self._right_sibling[index] = Self.Index(index)
        self._parent[index] = Self.Index(index)
        return index

    def _append_child(mut self, parent: Int, node: Int):
        """Hooks `node` on as the last child of `parent`."""
        var child = Int(self._left_child[parent])
        if child == parent:
            self._left_child[parent] = Self.Index(node)
            return
        while self.has_sibling(child):
            child = Int(self._right_sibling[child])
        self._right_sibling[child] = Self.Index(node)

    def _previous_sibling(self, node: Int) -> Int:
        """Returns the sibling before `node`, or -1 if it is the first child."""
        var parent = Int(self._parent[node])
        var child = Int(self._left_child[parent])
        if child == node:
            return -1
        while Int(self._right_sibling[child]) != node:
            child = Int(self._right_sibling[child])
        return child

    def _relink(mut self, parent: Int, previous: Int, node: Int):
        """Puts `node` where a former child of `parent` sat."""
        if previous == -1:
            self._left_child[parent] = Self.Index(node)
        else:
            self._right_sibling[previous] = Self.Index(node)

    def _detach(mut self, index: Int):
        """Unhooks `index` from its parent's child chain."""
        var parent = Int(self._parent[index])
        var previous = self._previous_sibling(index)
        var sibling = Int(self._right_sibling[index])
        if previous == -1:
            self._left_child[parent] = Self.Index(
                parent if sibling == index else sibling
            )
        else:
            self._right_sibling[previous] = Self.Index(
                previous if sibling == index else sibling
            )

    @staticmethod
    def _remap(mapping: List[Int], old: Int, fallback: Int) -> Self.Index:
        """Maps an old node index to its new one, or to `fallback` if dropped.
        """
        var mapped = mapping[old]
        return Self.Index(fallback if mapped == -1 else mapped)

    def _compact(mut self, kept: List[Int]):
        """Rebuilds the arrays so the nodes sit in the order given by `kept`."""
        var size = len(kept)
        var mapping = List[Int](length=len(self._elements), fill=-1)
        for new_index in range(size):
            mapping[kept[new_index]] = new_index

        var elements = List[Self.T](capacity=size)
        var left_child = List[Self.Index](capacity=size)
        var right_sibling = List[Self.Index](capacity=size)
        var parent = List[Self.Index](capacity=size)

        for new_index in range(size):
            var old = kept[new_index]
            elements.append(self._elements[old].copy())
            # A link leaving the kept set becomes "none", i.e. a self-pointer.
            # That is what happens to the subtree root's sibling and parent
            # when compacting to a subtree.
            left_child.append(
                self._remap(mapping, Int(self._left_child[old]), new_index)
            )
            right_sibling.append(
                self._remap(mapping, Int(self._right_sibling[old]), new_index)
            )
            parent.append(
                self._remap(mapping, Int(self._parent[old]), new_index)
            )

        self._elements = elements^
        self._left_child = left_child^
        self._right_sibling = right_sibling^
        self._parent = parent^
        self._free.clear()


# ===-----------------------------------------------------------------------===#
# Iterators
# ===-----------------------------------------------------------------------===#


struct _ChildIter[
    mut: Bool, //, T: Copyable & Deinitable, I: DType, origin: Origin[mut=mut]
](ImplicitlyCopyable, Iterable, Iterator):
    """Yields the indices of one node's children, in order.

    Parameters:
        mut: Whether the borrow of the tree is mutable.
        T: The element type of the tree.
        I: The index type of the tree.
        origin: The origin of the borrowed tree.
    """

    comptime Element = Int
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _src: Pointer[LCRSTree[Self.T, Self.I], Self.origin]
    var _node: Int

    def __init__(
        out self,
        src: Pointer[LCRSTree[Self.T, Self.I], Self.origin],
        node: Int,
    ):
        """Starts a walk of a sibling chain.

        Args:
            src: The tree to walk.
            node: The first child, or -1 when there is none.
        """
        self._src = src
        self._node = node

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        """Returns this iterator.

        Returns:
            A copy of `self`.
        """
        return self.copy()

    def __next__(mut self) raises StopIteration -> Int:
        """Returns the next child index.

        Raises:
            StopIteration: When the sibling chain is exhausted.

        Returns:
            The next child index.
        """
        if self._node == -1:
            raise StopIteration()
        var result = self._node
        self._node = Int(
            self._src[]._right_sibling[result]
        ) if self._src[].has_sibling(result) else -1
        return result


struct _DfsIter[
    mut: Bool, //, T: Copyable & Deinitable, I: DType, origin: Origin[mut=mut]
](ImplicitlyCopyable, Iterable, Iterator):
    """Yields a subtree's node indices in depth-first preorder.

    Parameters:
        mut: Whether the borrow of the tree is mutable.
        T: The element type of the tree.
        I: The index type of the tree.
        origin: The origin of the borrowed tree.
    """

    comptime Element = Int
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _src: Pointer[LCRSTree[Self.T, Self.I], Self.origin]
    var _root: Int
    var _node: Int

    def __init__(
        out self,
        src: Pointer[LCRSTree[Self.T, Self.I], Self.origin],
        root: Int,
    ):
        """Starts a preorder walk of the subtree at `root`.

        Args:
            src: The tree to walk.
            root: The subtree root.
        """
        self._src = src
        self._root = root
        self._node = root if root < len(src[]._elements) else -1

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        """Returns this iterator.

        Returns:
            A copy of `self`.
        """
        return self.copy()

    def __next__(mut self) raises StopIteration -> Int:
        """Returns the next node index in preorder.

        Raises:
            StopIteration: When the subtree is exhausted.

        Returns:
            The next node index.
        """
        if self._node == -1:
            raise StopIteration()
        var result = self._node
        self._node = self._src[]._dfs_successor(result, self._root)
        return result


struct _BfsIter[
    mut: Bool, //, T: Copyable & Deinitable, I: DType, origin: Origin[mut=mut]
](Copyable, Iterable, Iterator):
    """Yields a subtree's node indices level by level.

    Parameters:
        mut: Whether the borrow of the tree is mutable.
        T: The element type of the tree.
        I: The index type of the tree.
        origin: The origin of the borrowed tree.
    """

    comptime Element = Int
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _src: Pointer[LCRSTree[Self.T, Self.I], Self.origin]
    var _queue: List[Int]
    var _cursor: Int

    def __init__(
        out self,
        src: Pointer[LCRSTree[Self.T, Self.I], Self.origin],
        root: Int,
    ):
        """Starts a breadth-first walk of the subtree at `root`.

        Args:
            src: The tree to walk.
            root: The subtree root.
        """
        self._src = src
        self._queue = []
        if root < len(src[]._elements):
            self._queue.append(root)
        self._cursor = 0

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        """Returns this iterator.

        Returns:
            A copy of `self`.
        """
        return self.copy()

    def __next__(mut self) raises StopIteration -> Int:
        """Returns the next node index in breadth-first order.

        Raises:
            StopIteration: When the subtree is exhausted.

        Returns:
            The next node index.
        """
        if self._cursor >= len(self._queue):
            raise StopIteration()
        var result = self._queue[self._cursor]
        self._cursor += 1
        for child in self._src[].children(result):
            self._queue.append(child)
        return result


# ===-----------------------------------------------------------------------===#
# Printing
# ===-----------------------------------------------------------------------===#


def print_tree[
    T: Copyable & Deinitable & Writable, I: DType, //
](tree: LCRSTree[T, I], root: Int = 0):
    """Prints the shape of a tree, one node per line.

    Parameters:
        T: The element type, which must also be printable.
        I: The index type of the tree.

    Args:
        tree: The tree to print.
        root: The node to print from.
    """
    for index in tree.dfs(root):
        var indentation = String()
        for _ in range(tree.depth(index) - tree.depth(root)):
            indentation += "  "
        print(indentation, "-", tree[index])
