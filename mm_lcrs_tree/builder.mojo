"""A fluent builder for `LCRSTree`."""

from .lcrs_tree import LCRSTree


struct LCRSTreeBuilder[T: Copyable & Deinitable, I: DType = DType.uint32](
    Movable
):
    """Builds an `LCRSTree` by describing it top down.

    `node` adds a child and descends into it, `leaf` adds a child without
    descending, and `up` returns to the parent:

    ```mojo
    from mm_lcrs_tree import LCRSTreeBuilder

    var tree = (
        LCRSTreeBuilder[Int](1)
        .node(5)
            .leaf(7)
            .up()
        .node(10)
            .leaf(15)
        .tree()
    )
    ```

    Parameters:
        T: The element type stored at each node.
        I: The unsigned integer type used for node indices.
    """

    var _tree: LCRSTree[Self.T, Self.I]
    var _path: List[Int]

    def __init__(out self, root: Self.T):
        """Starts a tree with `root` at the top.

        Args:
            root: The element for the root node.
        """
        self._tree = LCRSTree[Self.T, Self.I](root)
        self._path = [0]

    def node(var self, element: Self.T) -> Self:
        """Adds a child to the current node and descends into it.

        Args:
            element: The element for the new node.

        Returns:
            The builder, for chaining.
        """
        var parent = self._path[len(self._path) - 1]
        self._path.append(self._tree.add_child(element, parent))
        return self^

    def leaf(var self, element: Self.T) -> Self:
        """Adds a child to the current node without descending into it.

        Args:
            element: The element for the new node.

        Returns:
            The builder, for chaining.
        """
        var parent = self._path[len(self._path) - 1]
        _ = self._tree.add_child(element, parent)
        return self^

    def up(var self) -> Self:
        """Returns to the parent of the current node.

        Staying at the root is a no-op, so an extra `up` is harmless.

        Returns:
            The builder, for chaining.
        """
        if len(self._path) > 1:
            _ = self._path.pop()
        return self^

    def tree(deinit self) -> LCRSTree[Self.T, Self.I]:
        """Finishes building and returns the tree.

        Returns:
            The tree that was described.
        """
        var path = self._path^
        _ = path^
        return self._tree^
