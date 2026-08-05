//! A spec file whose program is stale.  The comment may say Float and
//! the Zig below may name a Builder; only the program counts.

const Builder = @import("std").ArrayList(u8);

test "a program that never had its names migrated" {
    try agreeOk(
        \\func main():
        \\    let x: Float = 1.5
        \\    assert(x == 1.5)
        \\
    );
}
