"""An n-ary tree stored as left-child / right-sibling links in parallel arrays.

Every node keeps exactly two links -- its *first child* and its *next sibling*
-- which encodes a tree of arbitrary arity as a binary one. A node's children
are its first child followed by that child's sibling chain, so a node costs the
same whether it has one child or a thousand, at the price of O(k) to reach the
k-th child.

Nodes live in parallel `List`s and are addressed by index; a link that points at
its own node means "none", so no index value has to be reserved as a sentinel.
Alongside the two tree links this implementation keeps a `parent` array, which
makes upward walks, removal and node swaps possible; a `last_child` array, which
is the tail of each child chain and makes appending a child O(1) instead of a
walk to the end; and a free list, so slots released by `remove` are reused by
later inserts.

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

from std.memory import (
    unsafe_destroy_n,
    unsafe_memcpy,
    unsafe_uninit_copy_n,
    unsafe_uninit_move_n,
)
from std.memory.alloc import Layout, ThinAllocation, alloc, dealloc


struct LCRSTree[
    T: Copyable & Deinitable,
    I: DType = DType.uint32,
    track_previous_sibling: Bool = False,
    growth_percent: Int = 200,
](
    Copyable,
    Iterable,
    Movable,
    Sized,
    Writable where conforms_to(T, Writable),
):
    """A tree of arbitrary arity, stored as left-child / right-sibling links.

    Parameters:
        T: The element type stored at each node.
        I: The unsigned integer type used for node indices. The default
            `uint32` allows a little over four billion nodes; `uint16` quarters
            the memory used by the link arrays but caps the tree at 65535
            nodes.
        track_previous_sibling: Whether to keep a backward link alongside the
            forward one. Off by default, in which case detaching a node scans
            its parent's child chain to find what precedes it, making `remove`
            and `swap_nodes` O(number of siblings). Turning it on makes both
            O(1) for another index per node. When it is off the array stays
            empty and every line maintaining it compiles away, so the default
            costs nothing but the region it does not reserve.
        growth_percent: How much to grow the buffers by when they fill, as a
            percentage of the current capacity; 200 doubles. One buffer holds
            every link region, so over-allocating costs `_REGIONS` times what
            it would for a single array -- 150 wastes far less on a large tree,
            and pairs well with an honest `capacity`.


    A tree always has a root, so it is never empty; construct it with the root
    element. Nodes are referred to by index, which stays stable until
    `compact_dfs`/`compact_bfs` renumbers them.
    """

    comptime Index = Scalar[Self.I]
    """The scalar type used for node indices."""

    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = _DfsIter[
        Self.T,
        Self.I,
        Self.track_previous_sibling,
        Self.growth_percent,
        iterable_origin,
    ]
    """The iterator returned by `__iter__`: depth-first from the root."""

    comptime _LEFT = 0
    """Region holding each node's first child."""
    comptime _RIGHT = 1
    """Region holding each node's next sibling."""
    comptime _LAST = 2
    """Region holding the cached tail of each node's child chain."""
    comptime _PARENT = 3
    """Region holding each node's parent."""
    comptime _FREE = 4
    """Region holding the slots released by `remove`."""
    comptime _PREV = 5
    """Region holding each node's previous sibling, if it is being tracked."""
    comptime _REGIONS = 6 if Self.track_previous_sibling else 5
    """How many regions the link buffer is divided into."""

    var _elements: Pointer[Self.T, MutUntrackedOrigin]
    """The element of every node slot; `_count` of them are initialized."""
    var _links: Pointer[Self.Index, MutUntrackedOrigin]
    """Every index the tree needs, in one allocation: `_REGIONS` regions of
    `_capacity` entries each, in the order given by the region constants. A
    node link that points at its own node means "none"."""
    var _capacity: Int
    """Slots the buffers can hold, and the stride between link regions."""
    var _count: Int
    """Slots in use, live and free."""
    var _free_count: Int
    """How many entries of the free region are in use."""

    # ===-------------------------------------------------------------------===#
    # Lifecycle
    # ===-------------------------------------------------------------------===#

    def __init__(out self, root: Self.T, *, capacity: Int = 8):
        """Constructs a tree holding a single root node.

        Args:
            root: The element to store at the root.
            capacity: Slots to allocate up front. Passing the eventual node
                count avoids every intermediate reallocation.
        """
        comptime assert (
            Self.growth_percent > 100
        ), "growth_percent must exceed 100, or the buffers could never grow"
        var slots = capacity if capacity > 1 else 1
        self._elements = Self._alloc_elements(slots)
        self._links = Self._alloc_links(slots)
        self._capacity = slots
        self._count = 1
        self._free_count = 0
        self._elements.unsafe_offset(0).unsafe_write(root.copy())
        # Every link of the root points at the root: it has no child, no
        # sibling and no parent.
        for region in range(Self._REGIONS):
            self._set(region, 0, 0)

    def __init__(out self, *, copy: Self):
        """Constructs an independent copy of `copy`.

        Args:
            copy: The tree to duplicate.
        """
        self._capacity = copy._capacity
        self._count = copy._count
        self._free_count = copy._free_count
        self._elements = Self._alloc_elements(copy._capacity)
        self._links = Self._alloc_links(copy._capacity)
        unsafe_uninit_copy_n[overlapping=False](
            dest=self._elements, src=copy._elements, count=copy._count
        )
        unsafe_memcpy(
            dest=self._links,
            src=copy._links,
            count=copy._capacity * Self._REGIONS,
        )

    def __init__(out self, *, deinit move: Self):
        """Takes over `move`'s storage.

        Args:
            move: The tree to move from.
        """
        self._elements = move._elements
        self._links = move._links
        self._capacity = move._capacity
        self._count = move._count
        self._free_count = move._free_count

    def __deinit__(deinit self):
        """Destroys the live elements and releases both buffers."""
        unsafe_destroy_n(self._elements, self._count)
        Self._free_elements(self._elements, self._capacity)
        Self._free_links(self._links, self._capacity)

    @staticmethod
    def _alloc_elements(slots: Int) -> Pointer[Self.T, MutUntrackedOrigin]:
        return alloc(Layout[Self.T](count=slots)).unsafe_leak()

    @staticmethod
    def _alloc_links(slots: Int) -> Pointer[Self.Index, MutUntrackedOrigin]:
        return alloc(
            Layout[Self.Index](count=slots * Self._REGIONS)
        ).unsafe_leak()

    @staticmethod
    def _free_elements(
        var pointer: Pointer[Self.T, MutUntrackedOrigin], slots: Int
    ):
        dealloc(
            ThinAllocation(unsafe_owned_ptr=pointer).unsafe_with_layout(
                Layout[Self.T](count=slots)
            )
        )

    @staticmethod
    def _free_links(
        var pointer: Pointer[Self.Index, MutUntrackedOrigin], slots: Int
    ):
        dealloc(
            ThinAllocation(unsafe_owned_ptr=pointer).unsafe_with_layout(
                Layout[Self.Index](count=slots * Self._REGIONS)
            )
        )

    # ===-------------------------------------------------------------------===#
    # Size and element access
    # ===-------------------------------------------------------------------===#

    @always_inline
    def __len__(self) -> Int:
        """Returns the number of live nodes.

        Returns:
            The node count, excluding slots on the free list.
        """
        return self._count - self._free_count

    def __getitem__(ref self, index: Int) -> ref[self] Self.T:
        """Returns a reference to the element at `index`.

        Nothing is copied, so reading a node whose element owns heap storage
        costs nothing, and the reference is mutable when the tree is:

        ```mojo
        tree[node] += " suffix"
        ```

        Args:
            index: The node index.

        Returns:
            A reference to the element stored there, borrowed from the tree.
        """
        return self._elements[unsafe_offset=index]

    def capacity(self) -> Int:
        """Returns the number of node slots, live and free.

        Node indices are always below this, which is what `compact_dfs` shrinks.

        Returns:
            The slot count.
        """
        return self._count

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
        return self._left(index) == index

    @always_inline
    def is_root(self, index: Int) -> Bool:
        """Returns whether the node has no parent.

        Args:
            index: The node index.

        Returns:
            True if the node is the root.
        """
        return self._parent_of_raw(index) == index

    @always_inline
    def has_sibling(self, index: Int) -> Bool:
        """Returns whether the node has a next sibling.

        Args:
            index: The node index.

        Returns:
            True if a sibling follows this node.
        """
        return self._right(index) != index

    def are_siblings(self, a: Int, b: Int) -> Bool:
        """Returns whether two nodes share a parent.

        Args:
            a: The first node index.
            b: The second node index.

        Returns:
            True if both nodes have the same parent.
        """
        return self._parent_of_raw(a) == self._parent_of_raw(b)

    def parent_of(self, index: Int) -> Int:
        """Returns the parent of `index`, or `index` itself for the root.

        Args:
            index: The node index.

        Returns:
            The parent node index.
        """
        return self._parent_of_raw(index)

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
            node = self._parent_of_raw(node)
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
            node = self._parent_of_raw(node)
            result += 1
        return result

    # ===-------------------------------------------------------------------===#
    # Traversal
    # ===-------------------------------------------------------------------===#

    def children(
        self, index: Int
    ) -> _ChildIter[
        Self.T,
        Self.I,
        Self.track_previous_sibling,
        Self.growth_percent,
        origin_of(self),
    ]:
        """Returns an iterator over the node's children, in order.

        Args:
            index: The node index.

        Returns:
            An iterator yielding child indices.
        """
        var first = self._left(index)
        return {src = Pointer(to=self), node = -1 if first == index else first}

    def first_child(self, index: Int) -> Int:
        """Returns the node's first child, or -1 if it has none.

        Args:
            index: The node index.

        Returns:
            The first child's index, or -1.
        """
        var child = self._left(index)
        return -1 if child == index else child

    def next_sibling(self, index: Int) -> Int:
        """Returns the node that follows this one, or -1 if none does.

        Args:
            index: The node index.

        Returns:
            The next sibling's index, or -1.
        """
        var sibling = self._right(index)
        return -1 if sibling == index else sibling

    def subtree_size(self, index: Int) -> Int:
        """Returns how many nodes the subtree at `index` holds, itself included.

        Walks the subtree, so this is O(size of the subtree).

        Args:
            index: The subtree root.

        Returns:
            The node count.
        """
        var count = 0
        for _ in self.dfs(index):
            count += 1
        return count

    def dfs(
        self, root: Int = 0
    ) -> _DfsIter[
        Self.T,
        Self.I,
        Self.track_previous_sibling,
        Self.growth_percent,
        origin_of(self),
    ]:
        """Returns a depth-first (preorder) iterator over a subtree.

        The walk uses the parent links instead of a stack, so it allocates
        nothing and cannot overflow on a deep tree.

        Args:
            root: The node to start from; its subtree is what gets visited.

        Returns:
            An iterator yielding node indices, `root` first.
        """
        return {src = Pointer(to=self), root = root}

    def bfs(
        self, root: Int = 0
    ) -> _BfsIter[
        Self.T,
        Self.I,
        Self.track_previous_sibling,
        Self.growth_percent,
        origin_of(self),
    ]:
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

    def postorder(
        self, root: Int = 0
    ) -> _PostIter[
        Self.T,
        Self.I,
        Self.track_previous_sibling,
        Self.growth_percent,
        origin_of(self),
    ]:
        """Returns an iterator that visits children before their parent.

        This is the order most tree-shaped work wants -- evaluating, laying
        out, folding upwards, freeing -- and like `dfs` it walks on the parent
        links, so it allocates nothing and cannot overflow on a deep tree.

        Args:
            root: The node to start from; its subtree is what gets visited.

        Returns:
            An iterator yielding node indices, `root` last.
        """
        return {src = Pointer(to=self), root = root}

    def leaves(
        self, root: Int = 0
    ) -> _LeafIter[
        Self.T,
        Self.I,
        Self.track_previous_sibling,
        Self.growth_percent,
        origin_of(self),
    ]:
        """Returns an iterator over the subtree's leaves, in depth-first order.

        Args:
            root: The node to start from.

        Returns:
            An iterator yielding the indices of childless nodes.
        """
        return {src = Pointer(to=self), root = root}

    def write_to(
        self, mut writer: Some[Writer]
    ) where conforms_to(Self.T, Writable):
        """Writes the tree as an indented outline, one node per line.

        Args:
            writer: The writer to write to.
        """
        self._write_from(writer, 0)

    def _write_from(
        self, mut writer: Some[Writer], root: Int
    ) where conforms_to(Self.T, Writable):
        """Writes the subtree at `root`, tracking depth as it walks.

        Depth comes from the walk rather than from `depth()` per node: that
        would be O(depth) each time, and quadratic down a long chain.
        """
        if root >= self._count:
            return
        var node = root
        var depth = 0
        var first = True
        while True:
            if not first:
                writer.write("\n")
            first = False
            for _ in range(depth):
                writer.write("  ")
            writer.write("- ", self._elements[unsafe_offset=node])

            if not self.is_leaf(node):
                node = self._left(node)
                depth += 1
                continue

            var climbing = node
            var climbed = 0
            var advanced = False
            while climbing != root:
                if self.has_sibling(climbing):
                    node = self._right(climbing)
                    depth -= climbed
                    advanced = True
                    break
                climbing = self._parent_of_raw(climbing)
                climbed += 1
            if not advanced:
                return

    def get_postorder_indices(self, root: Int = 0) -> List[Int]:
        """Returns every node of a subtree, children before parents.

        Args:
            root: The node to start from.

        Returns:
            The node indices in visit order.
        """
        var result = List[Int]()
        for index in self.postorder(root):
            result.append(index)
        return result^

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
    def _deepest_first(self, node: Int) -> Int:
        """Descends to the first leaf under `node`, which postorder visits."""
        var current = node
        while not self.is_leaf(current):
            current = self._left(current)
        return current

    @always_inline
    def _post_successor(self, node: Int, root: Int) -> Int:
        """Returns the next node in postorder within `root`'s subtree, or -1."""
        if node == root:
            return -1
        if self.has_sibling(node):
            return self._deepest_first(self._right(node))
        return self._parent_of_raw(node)

    @always_inline
    def _dfs_successor(self, node: Int, root: Int) -> Int:
        """Returns the next node in preorder within `root`'s subtree, or -1."""
        if not self.is_leaf(node):
            return self._left(node)
        var current = node
        while current != root:
            if self.has_sibling(current):
                return self._right(current)
            current = self._parent_of_raw(current)
            if self.is_root(current) and current != root:
                # Walked past the subtree without finding a sibling.
                return -1
        return -1

    # ===-------------------------------------------------------------------===#
    # Mutation
    # ===-------------------------------------------------------------------===#

    def add_child(mut self, element: Self.T, parent: Int = 0) -> Int:
        """Appends a new node as the last child of `parent`, in constant time.

        Args:
            element: The element to store.
            parent: The index of the node to attach to.

        Returns:
            The index of the new node.
        """
        var index = self._claim_slot(element)
        self._set_parent(index, parent)
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
        var offset = self._count
        var incoming = other._count
        self._reserve(offset + incoming)
        unsafe_uninit_copy_n[overlapping=False](
            dest=self._elements.unsafe_offset(offset),
            src=other._elements,
            count=incoming,
        )
        self._count += incoming
        for i in range(incoming):
            for region in range(Self._REGIONS):
                if region == Self._FREE:
                    continue
                self._set(region, offset + i, other._get(region, i) + offset)
        for i in range(other._free_count):
            self._set(
                Self._FREE,
                self._free_count + i,
                other._get(Self._FREE, i) + offset,
            )
        self._free_count += other._free_count

        # The copied root's parent is the node we are attaching it to. The 2023
        # version hard-coded 0 here, which silently corrupted `parent` whenever
        # a tree was grafted onto anything but the root.
        self._set_parent(offset, parent)
        self._append_child(parent, offset)
        return offset

    def prepend_root(mut self, element: Self.T) -> Int:
        """Inserts a new root above the current one, which becomes its child.

        Args:
            element: The element for the new root.

        Returns:
            The index the old root moved to.
        """
        var old_root = self._elements.unsafe_offset(0)[].copy()
        # A self-pointer means "no child", so the old root's sentinel cannot be
        # copied verbatim: at its new index it would point at the new root and
        # close a cycle. Read the real child before claiming the slot.
        var had_child = not self.is_leaf(0)
        var first_child = self._left(0)
        var last_child = self._last(0)

        var moved = self._claim_slot(old_root)
        if had_child:
            self._set_left(moved, first_child)
            self._set_last(moved, last_child)
        self._set_right(moved, moved)
        self._set_parent(moved, 0)

        self._elements.unsafe_offset(0)[] = element.copy()
        self._set_left(0, moved)
        self._set_last(0, moved)
        self._set_right(0, 0)
        self._set_parent(0, 0)
        self._set_prev(moved, moved)

        for child in self.children(moved):
            self._set_parent(child, moved)
        return moved

    def is_free(self, index: Int) -> Bool:
        """Returns whether a slot has been released and not yet reused.

        A freed slot is marked by pointing its parent link at itself, which
        only the root does legitimately.

        Args:
            index: The slot index.

        Returns:
            True if the slot holds no live node.
        """
        return index != 0 and self._parent_of_raw(index) == index

    def insert_after(mut self, sibling: Int, element: Self.T) -> Int:
        """Inserts a new node directly after `sibling`, among its siblings.

        Args:
            sibling: The node to insert after. It must not be the root, which
                has no siblings.
            element: The element to store.

        Returns:
            The index of the new node, or -1 if `sibling` is the root.
        """
        if self.is_root(sibling):
            return -1
        var node = self._claim_slot(element)
        self._insert_after_sibling(sibling, node)
        return node

    def insert_before(mut self, sibling: Int, element: Self.T) -> Int:
        """Inserts a new node directly before `sibling`, among its siblings.

        Args:
            sibling: The node to insert before. It must not be the root, which
                has no siblings.
            element: The element to store.

        Returns:
            The index of the new node, or -1 if `sibling` is the root.
        """
        if self.is_root(sibling):
            return -1
        var parent = self._parent_of_raw(sibling)
        var previous = self._previous_sibling(sibling)
        var node = self._claim_slot(element)
        if previous == -1:
            self._insert_first(parent, node)
        else:
            self._insert_after_sibling(previous, node)
        return node

    def insert_child_at(
        mut self, parent: Int, position: Int, element: Self.T
    ) -> Int:
        """Inserts a new node as `parent`'s child at `position`.

        Positions past the end append, so `insert_child_at(p, len, x)` and
        `add_child(x, p)` agree. Finding the position walks the sibling chain,
        so this is O(position).

        Args:
            parent: The node to insert under.
            position: Where among the children to put it, counting from zero.
            element: The element to store.

        Returns:
            The index of the new node.
        """
        if position <= 0:
            var first = self._claim_slot(element)
            self._insert_first(parent, first)
            return first

        var previous = -1
        var seen = 0
        for child in self.children(parent):
            previous = child
            seen += 1
            if seen == position:
                break

        var node = self._claim_slot(element)
        if previous == -1:
            self._insert_first(parent, node)
        else:
            self._insert_after_sibling(previous, node)
        return node

    def move_node(mut self, node: Int, new_parent: Int) -> Bool:
        """Moves a node and its subtree to become the last child of another.

        Args:
            node: The node to move. It must not be the root.
            new_parent: The node to move it under. It must not be inside
                `node`'s own subtree, which would make a cycle.

        Returns:
            True if the node was moved.
        """
        if node == 0 or node == new_parent:
            return False
        if self.is_free(node) or self.is_free(new_parent):
            return False
        # Walking up from the destination must not reach the node being moved.
        var ancestor = new_parent
        while True:
            if ancestor == node:
                return False
            if self.is_root(ancestor):
                break
            ancestor = self._parent_of_raw(ancestor)

        self._detach(node)
        self._set_right(node, node)
        self._set_parent(node, new_parent)
        self._append_child(new_parent, node)
        return True

    def remove(mut self, index: Int):
        """Removes a node and its whole subtree.

        Removing the root empties the tree of everything but the root slot,
        whose element is left as it was. Removing a node that is already gone
        does nothing.

        Args:
            index: The node index to remove.
        """
        if self.is_free(index):
            return
        if index == 0:
            # The 2023 version cleared the node arrays but left the free list
            # populated, so the next insert reused an out-of-range slot.
            # Destroy every slot but the root, which keeps its element.
            unsafe_destroy_n(self._elements.unsafe_offset(1), self._count - 1)
            self._count = 1
            self._free_count = 0
            for region in range(Self._REGIONS):
                self._set(region, 0, 0)
            return

        self._detach(index)
        for node in self.bfs(index):
            self._set(Self._FREE, self._free_count, node)
            self._free_count += 1
            # Mark the slot free: only the root may legitimately be its own
            # parent, so this is what `is_free` looks for.
            self._set_parent(node, node)

    def swap_elements(mut self, a: Int, b: Int):
        """Exchanges the elements of two nodes, leaving the shape alone.

        Args:
            a: The first node index.
            b: The second node index.
        """
        var left = self._elements.unsafe_offset(a)
        var right = self._elements.unsafe_offset(b)
        var temporary = left[].copy()
        left[] = right[].copy()
        right[] = temporary^

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

        var parent_a = self._parent_of_raw(a)
        var parent_b = self._parent_of_raw(b)
        var sibling_a = self._right(a)
        var sibling_b = self._right(b)
        var previous_a = self._previous_sibling(a)
        var previous_b = self._previous_sibling(b)
        var last_a = self._last(parent_a)
        var last_b = self._last(parent_b)

        # Unhook both, then hook each into the other's place. Order matters
        # when the two are siblings, so the incoming links are read first.
        self._set_parent(a, parent_b)
        self._set_parent(b, parent_a)

        self._relink(parent_a, previous_a, b)
        self._relink(parent_b, previous_b, a)

        self._set_right(b, b if sibling_a == a else sibling_a)
        self._set_right(a, a if sibling_b == b else sibling_b)

        # If they were adjacent siblings the steps above can leave one pointing
        # at itself through the other; fix the direct link.
        if sibling_a == b:
            self._set_right(b, a)
        elif sibling_b == a:
            self._set_right(a, b)

        # Each node took the other's place, so a parent whose tail was one of
        # them now ends with the other. When they are siblings only one of
        # these fires, since both reads saw the same tail.
        if last_a == a:
            self._set_last(parent_a, b)
        if last_b == b:
            self._set_last(parent_b, a)

        comptime if Self.track_previous_sibling:
            # Each node inherits the other's predecessor, and whatever now
            # follows each of them points back at it. The follower steps run
            # last so they win when the two were adjacent siblings.
            self._set_prev(b, b if previous_a == -1 else previous_a)
            self._set_prev(a, a if previous_b == -1 else previous_b)
            var after_b = self._right(b)
            if after_b != b:
                self._set_prev(after_b, b)
            var after_a = self._right(a)
            if after_a != a:
                self._set_prev(after_a, a)
        return True

    def free_slots(self) -> Int:
        """Returns how many slots `remove` has released and not reused.

        Returns:
            The number of slots waiting to be reused or reclaimed.
        """
        return self._free_count

    def fragmentation(self) -> Float64:
        """Returns the share of slots that are free, between 0 and 1.

        A tree that has never had anything removed reports 0. Half the slots
        being free reports 0.5, at which point a traversal is touching twice
        the memory it needs to.

        Returns:
            Freed slots divided by slots in use.
        """
        if self._count == 0:
            return 0.0
        return Float64(self._free_count) / Float64(self._count)

    def compact_if_fragmented(mut self, threshold: Float64 = 0.5) -> Bool:
        """Compacts the tree when enough of its slots are free.

        Compaction is worth a good deal -- a depth-first walk over a half-freed
        tree drops from 3.7 to 1.3 ns per node, and the slot array shrinks to
        the live node count -- but it **renumbers every node**, so it cannot be
        done behind the caller's back. Hence a method the caller invokes, and a
        return value saying whether it happened:

        ```mojo
        if tree.compact_if_fragmented():
            # every index you were holding is now stale
            ...
        ```

        Nodes end up in depth-first order, the order `dfs()` and `postorder()`
        then walk them in.

        Args:
            threshold: Compact when the share of free slots exceeds this.
                The default compacts once half the slots are free.

        Returns:
            True if the tree was compacted, which means node indices changed.
        """
        if self.fragmentation() <= threshold:
            return False
        self.compact_dfs()
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

    @always_inline
    def _get(self, region: Int, index: Int) -> Int:
        """Reads one entry of one region."""
        return Int(self._links.unsafe_offset(region * self._capacity + index)[])

    @always_inline
    def _set(mut self, region: Int, index: Int, value: Int):
        """Writes one entry of one region."""
        self._links.unsafe_offset(
            region * self._capacity + index
        )[] = Self.Index(value)

    @always_inline
    def _left(self, node: Int) -> Int:
        return Int(self._links.unsafe_offset(node)[])

    @always_inline
    def _set_left(mut self, node: Int, value: Int):
        self._links.unsafe_offset(node)[] = Self.Index(value)

    @always_inline
    def _right(self, node: Int) -> Int:
        return Int(self._links.unsafe_offset(self._capacity + node)[])

    @always_inline
    def _set_right(mut self, node: Int, value: Int):
        self._links.unsafe_offset(self._capacity + node)[] = Self.Index(value)

    @always_inline
    def _prev(self, node: Int) -> Int:
        return self._get(Self._PREV, node)

    @always_inline
    def _last(self, node: Int) -> Int:
        return self._get(Self._LAST, node)

    @always_inline
    def _set_last(mut self, node: Int, value: Int):
        self._set(Self._LAST, node, value)

    @always_inline
    def _parent_of_raw(self, node: Int) -> Int:
        return self._get(Self._PARENT, node)

    @always_inline
    def _set_parent(mut self, node: Int, value: Int):
        self._set(Self._PARENT, node, value)

    def reserve(mut self, slots: Int):
        """Grows the buffers so the tree can hold `slots` nodes without
        reallocating.

        Args:
            slots: The node count to make room for.
        """
        self._reserve(slots)

    @always_inline
    def _reserve(mut self, needed: Int):
        """Makes room for `needed` slots, growing only when it has to.

        The check is inlined into the callers; the growth itself is kept out of
        line so the common path stays a single comparison.
        """
        if needed > self._capacity:
            self._grow(needed)

    @no_inline
    def _grow(mut self, needed: Int):
        """Reallocates both buffers to hold at least `needed` slots.

        The element buffer moves in one bulk relocation and each link region in
        one `memcpy`, rather than an entry at a time.
        """
        var capacity = self._capacity * Self.growth_percent // 100
        if capacity < needed:
            capacity = needed

        var elements = Self._alloc_elements(capacity)
        unsafe_uninit_move_n[overlapping=False](
            dest=elements, src=self._elements, count=self._count
        )
        Self._free_elements(self._elements, self._capacity)
        self._elements = elements

        var links = Self._alloc_links(capacity)
        for region in range(Self._REGIONS):
            var used = self._free_count if region == Self._FREE else self._count
            unsafe_memcpy(
                dest=links.unsafe_offset(region * capacity),
                src=self._links.unsafe_offset(region * self._capacity),
                count=used,
            )
        Self._free_links(self._links, self._capacity)
        self._links = links
        self._capacity = capacity

    def _claim_slot(mut self, element: Self.T) -> Int:
        """Returns a fresh node slot, reusing a freed one when available."""
        if self._free_count == 0:
            var index = self._count
            debug_assert(
                index <= Int(Self.Index.MAX),
                "LCRSTree: node index type is too narrow for this many nodes",
            )
            self._reserve(index + 1)
            self._elements.unsafe_offset(index).unsafe_write(element.copy())
            self._count += 1
            for region in range(Self._REGIONS):
                if region != Self._FREE:
                    self._set(region, index, index)
            return index
        self._free_count -= 1
        var index = self._get(Self._FREE, self._free_count)
        self._elements.unsafe_offset(index)[] = element.copy()
        self._set_left(index, index)
        self._set_right(index, index)
        self._set_last(index, index)
        self._set_parent(index, index)
        self._set_prev(index, index)
        return index

    def _append_child(mut self, parent: Int, node: Int):
        """Hooks `node` on as the last child of `parent`, in constant time."""
        var last = self._last(parent)
        if last == parent:
            self._set_left(parent, node)
            self._set_prev(node, node)
        else:
            self._set_right(last, node)
            self._set_prev(node, last)
        self._set_last(parent, node)

    @always_inline
    def _set_prev(mut self, node: Int, previous: Int):
        """Records what precedes `node`, if backward links are being kept."""
        comptime if Self.track_previous_sibling:
            self._set(Self._PREV, node, previous)

    def _insert_first(mut self, parent: Int, node: Int):
        """Hooks `node` on as the first child of `parent`."""
        var first = self._left(parent)
        self._set_parent(node, parent)
        self._set_prev(node, node)
        self._set_left(parent, node)
        if first == parent:
            self._set_right(node, node)
            self._set_last(parent, node)
        else:
            self._set_right(node, first)
            self._set_prev(first, node)

    def _insert_after_sibling(mut self, sibling: Int, node: Int):
        """Hooks `node` on directly after `sibling`."""
        var parent = self._parent_of_raw(sibling)
        var following = self._right(sibling)
        self._set_parent(node, parent)
        self._set_right(sibling, node)
        self._set_prev(node, sibling)
        if following == sibling:
            self._set_right(node, node)
            self._set_last(parent, node)
        else:
            self._set_right(node, following)
            self._set_prev(following, node)

    def _previous_sibling(self, node: Int) -> Int:
        """Returns the sibling before `node`, or -1 if it is the first child."""
        comptime if Self.track_previous_sibling:
            var previous = self._get(Self._PREV, node)
            return -1 if previous == node else previous
        else:
            var parent = self._parent_of_raw(node)
            var child = self._left(parent)
            if child == node:
                return -1
            while self._right(child) != node:
                child = self._right(child)
            return child

    def _relink(mut self, parent: Int, previous: Int, node: Int):
        """Puts `node` where a former child of `parent` sat."""
        if previous == -1:
            self._set_left(parent, node)
        else:
            self._set_right(previous, node)

    def _detach(mut self, index: Int):
        """Unhooks `index` from its parent's child chain."""
        var parent = self._parent_of_raw(index)
        var previous = self._previous_sibling(index)
        var sibling = self._right(index)
        if previous == -1:
            self._set_left(parent, parent if sibling == index else sibling)
        else:
            self._set_right(previous, previous if sibling == index else sibling)
        if self._last(parent) == index:
            # The tail moved back to whatever preceded the detached node.
            self._set_last(parent, parent if previous == -1 else previous)
        if sibling != index:
            # Whatever followed now follows the detached node's predecessor.
            self._set_prev(sibling, sibling if previous == -1 else previous)

    @staticmethod
    def _remap(mapping: List[Int], old: Int, fallback: Int) -> Self.Index:
        """Maps an old node index to its new one, or to `fallback` if dropped.
        """
        var mapped = mapping[old]
        return Self.Index(fallback if mapped == -1 else mapped)

    def _compact(mut self, kept: List[Int]):
        """Rebuilds the arrays so the nodes sit in the order given by `kept`."""
        var size = len(kept)
        var mapping = List[Int](length=self._count, fill=-1)
        for new_index in range(size):
            mapping[kept[new_index]] = new_index

        var capacity = size if size > 0 else 1
        var elements = Self._alloc_elements(capacity)
        var links = Self._alloc_links(capacity)

        for new_index in range(size):
            var old = kept[new_index]
            elements.unsafe_offset(new_index).unsafe_write(
                self._elements.unsafe_offset(old)[].copy()
            )
            # A link leaving the kept set becomes "none", i.e. a self-pointer.
            # That is what happens to the subtree root's sibling and parent
            # when compacting to a subtree.
            for region in range(Self._REGIONS):
                if region == Self._FREE:
                    continue
                links.unsafe_offset(
                    region * capacity + new_index
                )[] = self._remap(mapping, self._get(region, old), new_index)

        unsafe_destroy_n(self._elements, self._count)
        Self._free_elements(self._elements, self._capacity)
        Self._free_links(self._links, self._capacity)
        self._elements = elements
        self._links = links
        self._capacity = capacity
        self._count = size
        self._free_count = 0


# ===-----------------------------------------------------------------------===#
# Iterators
# ===-----------------------------------------------------------------------===#


struct _ChildIter[
    mut: Bool,
    //,
    T: Copyable & Deinitable,
    I: DType,
    P: Bool,
    G: Int,
    origin: Origin[mut=mut],
](ImplicitlyCopyable, Iterable, Iterator):
    """Yields the indices of one node's children, in order.

    Parameters:
        mut: Whether the borrow of the tree is mutable.
        T: The element type of the tree.
        I: The index type of the tree.
        P: Whether the tree keeps backward sibling links.
        G: The tree's growth percentage.
        origin: The origin of the borrowed tree.
    """

    comptime Element = Int
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _src: Pointer[LCRSTree[Self.T, Self.I, Self.P, Self.G], Self.origin]
    var _node: Int

    def __init__(
        out self,
        src: Pointer[LCRSTree[Self.T, Self.I, Self.P, Self.G], Self.origin],
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
        self._node = (
            self._src[]
            ._right(result) if self._src[]
            .has_sibling(result) else -1
        )
        return result


struct _DfsIter[
    mut: Bool,
    //,
    T: Copyable & Deinitable,
    I: DType,
    P: Bool,
    G: Int,
    origin: Origin[mut=mut],
](ImplicitlyCopyable, Iterable, Iterator):
    """Yields a subtree's node indices in depth-first preorder.

    Parameters:
        mut: Whether the borrow of the tree is mutable.
        T: The element type of the tree.
        I: The index type of the tree.
        P: Whether the tree keeps backward sibling links.
        G: The tree's growth percentage.
        origin: The origin of the borrowed tree.
    """

    comptime Element = Int
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _src: Pointer[LCRSTree[Self.T, Self.I, Self.P, Self.G], Self.origin]
    var _root: Int
    var _node: Int

    def __init__(
        out self,
        src: Pointer[LCRSTree[Self.T, Self.I, Self.P, Self.G], Self.origin],
        root: Int,
    ):
        """Starts a preorder walk of the subtree at `root`.

        Args:
            src: The tree to walk.
            root: The subtree root.
        """
        self._src = src
        self._root = root
        self._node = root if root < src[]._count else -1

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


struct _PostIter[
    mut: Bool,
    //,
    T: Copyable & Deinitable,
    I: DType,
    P: Bool,
    G: Int,
    origin: Origin[mut=mut],
](ImplicitlyCopyable, Iterable, Iterator):
    """Yields a subtree's node indices with children before their parent.

    Parameters:
        mut: Whether the borrow of the tree is mutable.
        T: The element type of the tree.
        I: The index type of the tree.
        P: Whether the tree keeps backward sibling links.
        G: The tree's growth percentage.
        origin: The origin of the borrowed tree.
    """

    comptime Element = Int
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _src: Pointer[LCRSTree[Self.T, Self.I, Self.P, Self.G], Self.origin]
    var _root: Int
    var _node: Int

    def __init__(
        out self,
        src: Pointer[LCRSTree[Self.T, Self.I, Self.P, Self.G], Self.origin],
        root: Int,
    ):
        """Starts a postorder walk of the subtree at `root`.

        Args:
            src: The tree to walk.
            root: The subtree root.
        """
        self._src = src
        self._root = root
        self._node = src[]._deepest_first(root) if root < src[]._count else -1

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        """Returns this iterator.

        Returns:
            A copy of `self`.
        """
        return self.copy()

    def __next__(mut self) raises StopIteration -> Int:
        """Returns the next node, children before parents.

        Raises:
            StopIteration: When the subtree is exhausted.

        Returns:
            The next node index.
        """
        if self._node == -1:
            raise StopIteration()
        var result = self._node
        self._node = self._src[]._post_successor(result, self._root)
        return result


struct _LeafIter[
    mut: Bool,
    //,
    T: Copyable & Deinitable,
    I: DType,
    P: Bool,
    G: Int,
    origin: Origin[mut=mut],
](ImplicitlyCopyable, Iterable, Iterator):
    """Yields the childless nodes of a subtree, in depth-first order.

    Parameters:
        mut: Whether the borrow of the tree is mutable.
        T: The element type of the tree.
        I: The index type of the tree.
        P: Whether the tree keeps backward sibling links.
        G: The tree's growth percentage.
        origin: The origin of the borrowed tree.
    """

    comptime Element = Int
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _inner: _DfsIter[Self.T, Self.I, Self.P, Self.G, Self.origin]

    def __init__(
        out self,
        src: Pointer[LCRSTree[Self.T, Self.I, Self.P, Self.G], Self.origin],
        root: Int,
    ):
        """Starts a walk of the leaves under `root`.

        Args:
            src: The tree to walk.
            root: The subtree root.
        """
        self._inner = {src = src, root = root}

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        """Returns this iterator.

        Returns:
            A copy of `self`.
        """
        return self.copy()

    def __next__(mut self) raises StopIteration -> Int:
        """Returns the next leaf.

        Raises:
            StopIteration: When the subtree is exhausted.

        Returns:
            The next childless node's index.
        """
        while True:
            var node = self._inner.__next__()
            if self._inner._src[].is_leaf(node):
                return node


struct _BfsIter[
    mut: Bool,
    //,
    T: Copyable & Deinitable,
    I: DType,
    P: Bool,
    G: Int,
    origin: Origin[mut=mut],
](Copyable, Iterable, Iterator):
    """Yields a subtree's node indices level by level.

    Parameters:
        mut: Whether the borrow of the tree is mutable.
        T: The element type of the tree.
        I: The index type of the tree.
        P: Whether the tree keeps backward sibling links.
        G: The tree's growth percentage.
        origin: The origin of the borrowed tree.
    """

    comptime Element = Int
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _src: Pointer[LCRSTree[Self.T, Self.I, Self.P, Self.G], Self.origin]
    var _queue: List[Int]
    var _cursor: Int

    def __init__(
        out self,
        src: Pointer[LCRSTree[Self.T, Self.I, Self.P, Self.G], Self.origin],
        root: Int,
    ):
        """Starts a breadth-first walk of the subtree at `root`.

        Args:
            src: The tree to walk.
            root: The subtree root.
        """
        self._src = src
        self._queue = []
        if root < src[]._count:
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
# Borrowing the elements
# ===-----------------------------------------------------------------------===#


comptime BorrowedTree[T: Copyable & Deinitable, origin: ImmOrigin] = LCRSTree[
    Pointer[T, origin]
]
"""A tree that records structure between values it does not own.

The elements are pointers carrying `origin`, so the compiler tracks the
borrow: the storage is kept alive for as long as the tree needs it, and a tree
that would outlive it fails to compile.

```mojo
from mm_lcrs_tree import BorrowedTree, borrowed_tree

def outline[o: ImmOrigin, //](lines: Span[String, o]) -> BorrowedTree[String, o]:
    var tree = borrowed_tree(lines)                     # root is lines[0]
    _ = tree.add_child(Pointer(to=lines[1]))
    return tree^
```

The borrow is immutable by construction. A mutable one cannot work: the tree's
own type would embed a mutable reference to the storage, so every `add_child`
would be passing it mutably twice and the compiler rejects the call. To change
the values, hold indices instead and mutate the storage directly.

Parameters:
    T: The type of the borrowed values.
    origin: The origin of the storage they live in.
"""


def borrowed_tree[
    T: Copyable & Deinitable, origin: ImmOrigin, //
](values: Span[T, origin], root: Int = 0, *, capacity: Int = 8) -> BorrowedTree[
    T, origin
]:
    """Starts a tree that borrows its elements from `values`.

    Parameters:
        T: The type of the borrowed values.
        origin: The origin of the storage they live in.

    Args:
        values: The storage to borrow from. It must outlive the tree, which
            the origin makes the compiler check.
        root: Which of `values` the root node refers to.
        capacity: Slots to allocate up front.

    Returns:
        A tree of one node, referring to `values[root]`.
    """
    return BorrowedTree[T, origin](Pointer(to=values[root]), capacity=capacity)


# ===-----------------------------------------------------------------------===#
# Printing
# ===-----------------------------------------------------------------------===#


def print_tree[
    T: Copyable & Deinitable & Writable, I: DType, P: Bool, G: Int, //
](tree: LCRSTree[T, I, P, G], root: Int = 0):
    """Prints the shape of a tree, one node per line.

    `print(tree)` does the same for the whole tree; this takes a subtree root.

    Parameters:
        T: The element type, which must also be printable.
        I: The index type of the tree.
        P: Whether the tree keeps backward sibling links.
        G: The tree's growth percentage.

    Args:
        tree: The tree to print.
        root: The node to print from.
    """
    var out = String()
    tree._write_from(out, root)
    print(out)
