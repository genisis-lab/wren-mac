import Foundation

/// Comma-separated files, as Wren on the web reads and writes them (spreadsheets, user lists).
public enum CSV {
    /// The rows of a file. Quoted fields may hold commas, quotes ("") and line breaks; blank lines are skipped.
    /// Excel in many locales writes semicolons, so whichever the first line uses more is the separator.
    public static func parse(_ text: String) -> [[String]] {
        let src = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let first = src.prefix { $0 != "\n" && $0 != "\r" }
        let sep: Character = first.filter { $0 == ";" }.count > first.filter { $0 == "," }.count ? ";" : ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(src)[...]
        func endRow() {
            row.append(field)
            field = ""
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { rows.append(row) }
            row = []
        }
        while let ch = chars.popFirst() {
            if quoted {
                if ch == "\"" {
                    if chars.first == "\"" {
                        field.append("\"")
                        chars.removeFirst()
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(ch)
                }
            } else if ch == "\"" && field.isEmpty {
                quoted = true
            } else if ch == sep {
                row.append(field)
                field = ""
            } else if ch == "\n" || ch == "\r" || ch == "\r\n" {
                // Swift reads "\r\n" as one character.
                if ch == "\r", chars.first == "\n" { chars.removeFirst() }
                endRow()
            } else {
                field.append(ch)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// The first row as column names (lower-case letters and digits only, so "Setup Email" is "setupemail"),
    /// and each other row by them.
    public static func records(_ text: String) -> (headers: [String], records: [[String: String]]) {
        let rows = parse(text)
        guard let head = rows.first else { return ([], []) }
        let headers = head.map { $0.trimmingCharacters(in: .whitespaces).lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) } }
        let records = rows.dropFirst().map { row in
            Dictionary(headers.enumerated().map { i, h in (h, i < row.count ? row[i].trimmingCharacters(in: .whitespaces) : "") }, uniquingKeysWith: { a, _ in a })
        }
        return (headers, records)
    }

    /// A file from rows: fields with commas, quotes or line breaks are quoted.
    public static func make(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { v in v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) ? "\"\(v.replacingOccurrences(of: "\"", with: "\"\""))\"" : v }
                .joined(separator: ",")
        }
        .joined(separator: "\r\n") + "\r\n"
    }

    /// The first of several possible columns that has a value.
    static func pick(_ record: [String: String], _ names: String...) -> String {
        names.lazy.compactMap { record[$0] }.first { !$0.isEmpty } ?? ""
    }
}

/// Importing people from a spreadsheet, as on the web: Admin → Users → Import.
public enum AdminImport {
    /// A file to start from.
    public static let template = "email,name,setup_email,password,role,quota_mb,send_limit\r\njane@example.com,Jane Doe,jane@gmail.com,,user,2048,\r\nsam@example.com,Sam Lee,,a long temporary passphrase,admin,,500\r\n"

    /// The server takes this many rows per request (setting passwords is slow).
    public static let batch = 100

    /// Each row as the server takes it, or why the file can't be read.
    public static func rows(_ text: String) -> (rows: [JSON], warning: String?) {
        let (headers, records) = CSV.records(text)
        guard headers.contains(where: { ["email", "address", "emailaddress"].contains($0) }) else {
            return ([], "The first line must name the columns, including “email”.")
        }
        let number = { (v: String) -> JSON in Double(v).map { JSON.number($0.rounded()) } ?? .null }
        let rows = records.map { r -> JSON in
            var row: [String: JSON] = [
                "email": .string(CSV.pick(r, "email", "address", "emailaddress")),
                "name": .string(CSV.pick(r, "name", "fullname", "displayname")),
            ]
            let password = CSV.pick(r, "password", "temporarypassword")
            if !password.isEmpty { row["password"] = .string(password) }
            let role = CSV.pick(r, "role").lowercased()
            if !role.isEmpty { row["role"] = .string(role == "admin" || role == "administrator" ? "admin" : "user") }
            let quota = CSV.pick(r, "quotamb", "quota")
            if !quota.isEmpty { row["quotaMb"] = number(quota) }
            let limit = CSV.pick(r, "sendlimit", "sendlimitperday", "dailylimit")
            if !limit.isEmpty { row["sendLimitPerDay"] = number(limit) }
            let setup = CSV.pick(r, "setupemail", "personalemail", "recoveryemail", "currentemail")
            if !setup.isEmpty { row["setupEmail"] = .string(setup) }
            return .object(row)
        }
        return (rows, nil)
    }

    /// The people list as a spreadsheet, with the same columns as the web's export.
    public static func export(_ users: [AdminUser]) -> String {
        let days = ISO8601DateFormatter()
        days.formatOptions = [.withFullDate]
        let day = { (ms: Double?) in wrenDate(ms).map { days.string(from: $0) } ?? "" }
        let mb = { (b: Double?) in b.flatMap { Int(exactly: ($0 / 1_048_576).rounded()) }.map(String.init) ?? "" }
        return CSV.make(
            [["email", "name", "role", "status", "created", "last_sign_in", "used_mb", "quota_mb", "send_limit_per_day", "aliases", "messages", "two_step", "recovery_email"]]
                + users.map { u in
                    [
                        u.email, u.name, u.role, u.status, day(u.createdAt), day(u.lastLoginAt), mb(u.usedBytes), mb(u.quotaBytes),
                        u.sendLimitPerDay.map(String.init) ?? "", String(u.aliases ?? 0), String(u.messages ?? 0),
                        u.totpEnabled == true ? "yes" : "no", u.recoveryEmail ?? "",
                    ]
                }
        )
    }
}
