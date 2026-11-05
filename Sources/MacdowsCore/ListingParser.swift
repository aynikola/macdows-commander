import Foundation

/// Parses the text of FTP LIST and `ls -la` output (Unix style) and IIS style DOS listings.
public enum ListingParser {
    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    public static func parse(_ text: String, now: Date = Date()) -> [FileEntry] {
        var result: [FileEntry] = []
        text.enumerateLines { line, _ in
            if let entry = parseLine(line, now: now), entry.name != ".", entry.name != ".." {
                result.append(entry)
            }
        }
        return result
    }

    public static func parseLine(_ line: String, now: Date = Date()) -> FileEntry? {
        guard let first = line.first else { return nil }
        if first.isNumber { return parseDOS(line) }
        guard "-dlbcps".contains(first) else { return nil }
        return parseUnix(line, now: now)
    }

    /// Splits off `count` whitespace separated fields and returns them with the untouched rest of the line.
    private static func fields(_ line: String, count: Int) -> ([String], String)? {
        var parts: [String] = []
        var index = line.startIndex
        while parts.count < count {
            while index < line.endIndex, line[index].isWhitespace { index = line.index(after: index) }
            guard index < line.endIndex else { return nil }
            let start = index
            while index < line.endIndex, !line[index].isWhitespace { index = line.index(after: index) }
            parts.append(String(line[start..<index]))
        }
        guard index < line.endIndex else { return nil }
        // Exactly one separator before the name is not guaranteed, but leading spaces in names are rare.
        while index < line.endIndex, line[index].isWhitespace { index = line.index(after: index) }
        return (parts, String(line[index...]))
    }

    private static func parseUnix(_ line: String, now: Date) -> FileEntry? {
        // perms links owner group size month day time name
        var parsed = fields(line, count: 8)
        let ownerIndex = 2
        var sizeIndex = 4
        var monthIndex = 5
        if parsed == nil || Int64(parsed!.0[4]) == nil {
            // Some servers leave out the group column.
            parsed = fields(line, count: 7)
            guard let shorter = parsed, Int64(shorter.0[3]) != nil else { return nil }
            sizeIndex = 3
            monthIndex = 4
        }
        guard let (parts, rest) = parsed, !rest.isEmpty else { return nil }
        let perms = parts[0]
        let type = perms.first!
        var name = rest
        if type == "l", let arrow = name.range(of: " -> ") {
            name = String(name[..<arrow.lowerBound])
        }
        return FileEntry(
            name: name,
            isDirectory: type == "d",
            isSymlink: type == "l",
            size: Int64(parts[sizeIndex]) ?? 0,
            date: unixDate(month: parts[monthIndex], day: parts[monthIndex + 1], timeOrYear: parts[monthIndex + 2], now: now),
            permissions: perms,
            owner: parts[ownerIndex]
        )
    }

    private static func unixDate(month: String, day: String, timeOrYear: String, now: Date) -> Date? {
        guard let monthNumber = months[month.lowercased()], let dayNumber = Int(day) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        var comps = DateComponents(month: monthNumber, day: dayNumber)
        if timeOrYear.contains(":") {
            let clock = timeOrYear.split(separator: ":")
            comps.hour = Int(clock[0])
            comps.minute = clock.count > 1 ? Int(clock[1]) : 0
            comps.year = calendar.component(.year, from: now)
            // A time without a year means "within the last six months", so a future date is last year.
            if let date = calendar.date(from: comps), date.timeIntervalSince(now) > 86400 {
                comps.year = comps.year! - 1
            }
        } else {
            comps.year = Int(timeOrYear)
        }
        return calendar.date(from: comps)
    }

    private static func parseDOS(_ line: String) -> FileEntry? {
        // 11-04-26  02:30PM  <DIR>  name   or   11-04-26  02:30PM  1234  name
        guard let (parts, rest) = fields(line, count: 3), !rest.isEmpty else { return nil }
        let isDirectory = parts[2].uppercased() == "<DIR>"
        guard isDirectory || Int64(parts[2]) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd-yy hh:mma"
        return FileEntry(
            name: rest,
            isDirectory: isDirectory,
            size: isDirectory ? 0 : (Int64(parts[2]) ?? 0),
            date: formatter.date(from: parts[0] + " " + parts[1])
        )
    }
}
