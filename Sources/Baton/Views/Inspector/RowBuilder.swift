/// Hands out the running identity every row needs, so no call site has to track a counter.
struct RowBuilder {
    var rows: [DiffRow] = []
    private var next = 0

    mutating func append(_ make: (Int) -> DiffRow) {
        rows.append(make(next))
        next += 1
    }
}
