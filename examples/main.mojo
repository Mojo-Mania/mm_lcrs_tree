"""A short tour of `LCRSTree`."""

from mm_lcrs_tree import LCRSTree, LCRSTreeBuilder, print_tree


def main() raises:
    # Build a small filesystem by hand.
    var fs = LCRSTree[String]("/")
    var etc = fs.add_child("etc")
    _ = fs.add_child("hosts", etc)
    _ = fs.add_child("passwd", etc)
    var usr = fs.add_child("usr")
    var bin = fs.add_child("bin", usr)
    _ = fs.add_child("mojo", bin)

    print("nodes:", len(fs))
    print_tree(fs)

    print("\ndepth first:")
    for index in fs.dfs():
        print(" ", fs[index])

    print("\nbreadth first:")
    for index in fs.bfs():
        print(" ", fs[index])

    print("\nchildren of /etc:")
    for child in fs.children(etc):
        print(" ", fs[child])

    print("\npath to mojo:")
    var mojo = fs.children_indices(bin)[0]
    for ancestor in fs.ancestor_indices(mojo):
        print(" ", fs[ancestor])

    # Remove a subtree; the slots it freed get reused by later inserts.
    fs.remove(usr)
    print("\nafter removing /usr:", len(fs), "nodes,", fs.capacity(), "slots")
    _ = fs.add_child("var")
    print("after adding /var: ", len(fs), "nodes,", fs.capacity(), "slots")

    # The same shape, described top down.
    var menu = (
        LCRSTreeBuilder[String]("menu")
        .node("file")
        .leaf("open")
        .leaf("save")
        .up()
        .node("edit")
        .leaf("copy")
        .leaf("paste")
        .tree()
    )
    print("\nbuilt with the builder:")
    print_tree(menu)
