import Foundation

/// A line-by-line comparison, laid out so that the two sides line up row by row.
public struct DiffRow: Equatable {
    public enum Kind: Equatable { case same, changed, removed, added }
    public let kind: Kind
    /// Zero-based line numbers. Nil is an empty place opposite a line that exists only on the other side.
    public let left: Int?
    public let right: Int?

    public init(kind: Kind, left: Int?, right: Int?) {
        self.kind = kind
        self.left = left
        self.right = right
    }
}

public enum LineDiff {
    public static func lines(of text: String) -> [String] {
        if text.isEmpty { return [] }
        var result = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        if result.last == "" { result.removeLast() }
        return result
    }

    /// Past this many differences the middle is shown as one change rather than spending minutes and gigabytes on it.
    public static let maxEdits = 4000

    public static func compare(_ left: [String], _ right: [String], ignoringSpace: Bool = false) -> [DiffRow] {
        func key(_ line: String) -> String {
            ignoringSpace ? line.filter { !$0.isWhitespace } : line
        }
        // Whole-number ids make comparing long lines as cheap as comparing short ones.
        var ids: [String: Int32] = [:]
        func id(_ line: String) -> Int32 {
            let k = key(line)
            if let known = ids[k] { return known }
            let new = Int32(ids.count)
            ids[k] = new
            return new
        }
        let a = left.map(id), b = right.map(id)
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
        var endA = a.count, endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] {
            endA -= 1
            endB -= 1
        }
        var rows = (0..<start).map { DiffRow(kind: .same, left: $0, right: $0) }
        rows += middle(Array(a[start..<endA]), Array(b[start..<endB]), offsetA: start, offsetB: start)
        var i = endA, j = endB
        while i < a.count {
            rows.append(DiffRow(kind: .same, left: i, right: j))
            i += 1
            j += 1
        }
        return rows
    }

    /// Myers' algorithm, keeping each step so the path can be walked back.
    private static func middle(_ a: [Int32], _ b: [Int32], offsetA: Int, offsetB: Int) -> [DiffRow] {
        let n = a.count, m = b.count
        if n == 0 && m == 0 { return [] }
        var edits: [(isSame: Bool, a: Int, b: Int, isDelete: Bool)] = []
        var solved = false
        let limit = min(n + m, maxEdits)
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        let shift = limit + 1
        var trace: [[Int]] = []
        search: for d in 0...limit {
            trace.append(Array(v[(shift - d - 1)...(shift + d + 1)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[shift + k - 1] < v[shift + k + 1])) ? v[shift + k + 1] : v[shift + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[shift + k] = x
                if x >= n, y >= m {
                    solved = true
                    var cx = n, cy = m
                    for depth in stride(from: d, to: 0, by: -1) {
                        let past = trace[depth]
                        let base = depth + 1 // Index of k = 0 inside this step's slice.
                        let ck = cx - cy
                        let down = ck == -depth || (ck != depth && past[base + ck - 1] < past[base + ck + 1])
                        let pk = down ? ck + 1 : ck - 1
                        let px = past[base + pk], py = px - pk
                        while cx > (down ? px : px + 1), cy > (down ? py + 1 : py) {
                            cx -= 1
                            cy -= 1
                            edits.append((true, cx, cy, false))
                        }
                        if down {
                            cy -= 1
                            edits.append((false, cx, cy, false))
                        } else {
                            cx -= 1
                            edits.append((false, cx, cy, true))
                        }
                    }
                    while cx > 0, cy > 0 {
                        cx -= 1
                        cy -= 1
                        edits.append((true, cx, cy, false))
                    }
                    break search
                }
            }
        }
        guard solved else {
            return pair(removed: Array(0..<n).map { $0 + offsetA }, added: Array(0..<m).map { $0 + offsetB })
        }
        var rows: [DiffRow] = []
        var removed: [Int] = [], added: [Int] = []
        func flush() {
            rows += pair(removed: removed, added: added)
            removed = []
            added = []
        }
        for edit in edits.reversed() {
            if edit.isSame {
                flush()
                rows.append(DiffRow(kind: .same, left: edit.a + offsetA, right: edit.b + offsetB))
            } else if edit.isDelete {
                removed.append(edit.a + offsetA)
            } else {
                added.append(edit.b + offsetB)
            }
        }
        flush()
        return rows
    }

    /// Lines taken out and put in at one spot are shown across from each other as changes.
    private static func pair(removed: [Int], added: [Int]) -> [DiffRow] {
        var rows: [DiffRow] = []
        for index in 0..<max(removed.count, added.count) {
            switch (index < removed.count ? removed[index] : nil, index < added.count ? added[index] : nil) {
            case let (l?, r?): rows.append(DiffRow(kind: .changed, left: l, right: r))
            case let (l?, nil): rows.append(DiffRow(kind: .removed, left: l, right: nil))
            case let (nil, r?): rows.append(DiffRow(kind: .added, left: nil, right: r))
            default: break
            }
        }
        return rows
    }

    /// The first row of each run of differences.
    public static func changeStarts(_ rows: [DiffRow]) -> [Int] {
        var starts: [Int] = []
        var inside = false
        for (index, row) in rows.enumerated() {
            if row.kind == .same {
                inside = false
            } else if !inside {
                starts.append(index)
                inside = true
            }
        }
        return starts
    }

    /// The part of two lines that differs, in UTF-16 units: what is left between their common start and end.
    public static func changedRanges(_ left: String, _ right: String) -> (left: NSRange, right: NSRange) {
        let a = Array(left.utf16), b = Array(right.utf16)
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
        var endA = a.count, endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] {
            endA -= 1
            endB -= 1
        }
        return (NSRange(location: start, length: endA - start), NSRange(location: start, length: endB - start))
    }
}
