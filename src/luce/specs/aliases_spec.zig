//! Transparent type aliases, exercised through both execution engines.
//!
//! An alias is deliberately absent from MIR and runtime values.  These
//! programs therefore prove transparency by mixing the alias and its target
//! at every typed boundary: annotations, calls, returns, containers,
//! optionals, function values, nominal types, interfaces, and modules.

const agree = @import("agree.zig");

test "scalar chains are interchangeable with their target at every boundary" {
    try agree.prints(
        \\alias Id = i64
        \\alias UserId = Id
        \\alias MaybeId = UserId?
        \\
        \\func identity(value: Id) -> UserId:
        \\    return value
        \\
        \\func present(value: MaybeId) -> UserId:
        \\    return value else 0
        \\
        \\func main():
        \\    let raw: i64 = UserId(41.4)
        \\    let named: UserId = identity(raw)
        \\    let back: i64 = named
        \\    print(str(present(back) + 1))
        \\
    , "42\n");
}

test "container aliases resolve recursively and may be constructed with new" {
    try agree.prints(
        \\alias UserId = i64
        \\alias Users = list[UserId]
        \\alias UserIndex = map[str, UserId]
        \\alias Grid = array[UserId, _, _]
        \\
        \\func main():
        \\    var users: Users = Users()
        \\    users.append(40)
        \\    var index: UserIndex = UserIndex()
        \\    index["answer"] = users[0] + 2
        \\    let grid: Grid = Grid(1, 1)
        \\    grid[0, 0] = index["answer"]
        \\    print(str(grid[0, 0]))
        \\
    , "42\n");
}

test "a function alias is the same callable type" {
    try agree.prints(
        \\alias Transform = func(i64) -> i64
        \\
        \\func bump(value: i64) -> i64:
        \\    return value + 1
        \\
        \\func apply(transform: Transform, value: i64) -> i64:
        \\    return transform(value)
        \\
        \\func main():
        \\    let transform: Transform = bump
        \\    print(str(apply(transform, 41)))
        \\
    , "42\n");
}

test "aliases preserve enum storage widths and task resource lifetimes" {
    try agree.prints(
        \\alias Width = u8
        \\alias Work = task[i64]
        \\
        \\enum Small(Width):
        \\    answer = 42
        \\
        \\func compute() -> i64:
        \\    return i64(Small.answer)
        \\
        \\func main():
        \\    let value: Small = Small.answer
        \\    let work: Work = spawn compute()
        \\    print(str(value))
        \\    print(str(work.wait()))
        \\
    , "answer\n42\n");
}

test "forward aliases name structs enums unions and interfaces" {
    try agree.prints(
        \\alias Item = Button
        \\alias Kind = Method
        \\alias Answer = Outcome
        \\alias View = Drawable
        \\
        \\interface Drawable:
        \\    func render(value: i64) -> i64
        \\
        \\struct Button: View:
        \\    offset: i64
        \\    static func shifted(offset: i64) -> Button:
        \\        return Button(offset = offset)
        \\
        \\    func render(value: i64) -> i64:
        \\        return value + self.offset
        \\
        \\enum Method:
        \\    get
        \\    post
        \\
        \\union Outcome:
        \\    okay(value: i64)
        \\    failed(message: str)
        \\
        \\func draw(item: View, value: i64) -> i64:
        \\    return item.render(value)
        \\
        \\func read(answer: Answer) -> i64:
        \\    match answer:
        \\        okay(value):
        \\            return value
        \\        failed(message):
        \\            return len(message)
        \\
        \\func main():
        \\    let shift: func(i64) -> Item = Item.shifted
        \\    let make_answer: func(i64) -> Answer = Answer.okay
        \\    let button: Item = shift(1)
        \\    let method: Kind = Kind.get
        \\    assert(method == Kind.get)
        \\    print(str(draw(button, read(make_answer(41)))))
        \\
    , "42\n");
}

test "aliases are transparent while file-scope constants fold" {
    try agree.prints(
        \\alias Count = i64
        \\alias Position = Point
        \\alias Choice = Method
        \\
        \\struct Point:
        \\    x: Count
        \\
        \\enum Method:
        \\    first
        \\    answer = 42
        \\
        \\const ORIGIN: Position = Position(x = Count(41.4))
        \\const SELECTED: Choice = Choice.answer
        \\
        \\func main():
        \\    print(str(ORIGIN.x + i64(SELECTED) - 41))
        \\
    , "42\n");
}

test "an interface alias keeps heterogeneous list and map dispatch" {
    try agree.prints(
        \\alias Element = UIElement
        \\alias Elements = list[Element]
        \\alias ElementMap = map[str, Element]
        \\
        \\interface UIElement:
        \\    func render(value: i64) -> i64
        \\
        \\struct AddOne: Element:
        \\    marker: i64
        \\    func render(value: i64) -> i64:
        \\        return value + 1
        \\
        \\struct AddTwo: Element:
        \\    marker: i64
        \\    func render(value: i64) -> i64:
        \\        return value + 2
        \\
        \\func main():
        \\    var items: Elements = Elements()
        \\    items.append(AddOne(marker = 0))
        \\    items.append(AddTwo(marker = 0))
        \\    var by_name: ElementMap = ElementMap()
        \\    by_name["one"] = items[0]
        \\    by_name["two"] = items[1]
        \\    print(str(by_name["two"].render(40)))
        \\
    , "42\n");
}

test "public aliases cross a module boundary without runtime identity" {
    const models: agree.File = .{ .name = "models", .source =
        \\alias UserId = i64
        \\alias Users = list[UserId]
        \\
        \\func answer() -> UserId:
        \\    return 42
        \\
    };
    var program = try agree.project(
        \\import models
        \\
        \\func main():
        \\    var users: models.Users = models.Users()
        \\    let value: models.UserId = models.answer()
        \\    users.append(value)
        \\    assert(users[0] == 42)
        \\
    , &.{models});
    defer program.deinit();
    try agree.okProgram(&program, .{});
}

test "a public alias may re-export an imported nominal type" {
    const models: agree.File = .{ .name = "models", .source =
        \\struct User:
        \\    id: i64
        \\
    };
    const facade: agree.File = .{ .name = "facade", .source =
        \\import models
        \\
        \\alias User = models.User
        \\
        \\func answer() -> User:
        \\    return models.User(id = 42)
        \\
    };
    var program = try agree.project(
        \\import facade
        \\
        \\func main():
        \\    let first: facade.User = facade.answer()
        \\    let second = facade.User(id = 42)
        \\    assert(first.id == second.id)
        \\
    , &.{ models, facade });
    defer program.deinit();
    try agree.okProgram(&program, .{});
}
