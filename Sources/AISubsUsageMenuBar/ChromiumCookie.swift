import Foundation
import CCrypto

// Chromium/Electron cookie decryption shared by Claude, Figma and Notion Desktop:
//  1. Keychain "<App> Safe Storage" password -> PBKDF2-SHA1("saltysalt", 1003) -> AES-128 key
//  2. encrypted_value = "v10" + AES-128-CBC (IV = 16 spaces, PKCS7)
//  3. plaintext = 32-byte SHA-256 host prefix + cookie value
enum ChromiumCookie {
    enum KeychainError: LocalizedError {
        case accessDenied

        var errorDescription: String? { "Keychain access denied — click Always Allow, then Refresh." }
    }

    // Cached in memory so macOS only prompts once per launch and app.
    private static var cachedPasswords: [String: String] = [:]

    /// "<App> Safe Storage" password via the `security` CLI (same access path
    /// as the reference tools). Nil when missing; throws when the user denied.
    static func keychainPassword(service: String) throws -> String? {
        if let p = cachedPasswords[service] { return p }
        let out = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-w"]
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        // status 51 = user clicked Deny
        if proc.terminationStatus == 51 { throw KeychainError.accessDenied }
        guard proc.terminationStatus == 0 else { return nil }
        let pw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !pw.isEmpty else { return nil }
        cachedPasswords[service] = pw
        return pw
    }

    /// Decrypted (name, value) pairs of the cookies set for `hosts`, read with
    /// the system `sqlite3` CLI; immutable snapshot if the app holds a lock.
    static func cookies(db: String, hosts: [String], password: String) -> [(String, String)] {
        guard FileManager.default.fileExists(atPath: db),
              hosts.allSatisfy({ $0.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil })
        else { return [] }
        let list = hosts.map { "'\($0)'" }.joined(separator: ",")
        let sql = "SELECT name, hex(encrypted_value) FROM cookies WHERE host_key IN (\(list)) AND length(encrypted_value) > 3;"
        let dbQ = db.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? db
        guard let out = runSqlite(db: db, sql: sql) ?? runSqlite(db: "file:\(dbQ)?immutable=1", sql: sql) else { return [] }
        return out.split(separator: "\n").compactMap { sub -> (String, String)? in
            let line = String(sub)
            guard let sep = line.firstIndex(of: "|"),
                  let value = decrypt(hex: String(line[line.index(after: sep)...]), password: password),
                  !value.isEmpty
            else { return nil }
            return (String(line[..<sep]), value)
        }
    }

    private static func runSqlite(db: String, sql: String) -> String? {
        let out = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = ["-separator", "|", db, sql]
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    static func decrypt(hex: String, password: String) -> String? {
        var bytes = [UInt8]()
        var h = hex.makeIterator()
        while let hi = h.next(), let lo = h.next() {
            guard let b = UInt8(String([hi, lo]), radix: 16) else { return nil }
            bytes.append(b)
        }
        guard bytes.count > 3, bytes[0] == UInt8(ascii: "v"), bytes[1] == UInt8(ascii: "1"), bytes[2] == UInt8(ascii: "0") else { return nil }
        let cipher = Array(bytes.dropFirst(3))

        var key = [UInt8](repeating: 0, count: 16)
        let salt = Array("saltysalt".utf8)
        let rc = password.withCString { cStr in
            key.withUnsafeMutableBufferPointer { k in
                salt.withUnsafeBufferPointer { s in
                    c_pbkdf2_sha1(cStr, s.baseAddress, s.count, 1003, k.baseAddress, k.count)
                }
            }
        }
        guard rc == 0 else { return nil }

        var plain = [UInt8](repeating: 0, count: cipher.count + 16)
        var plainLen = plain.count
        let iv = [UInt8](repeating: 0x20, count: 16)
        let st: Int32 = cipher.withUnsafeBufferPointer { c in
            iv.withUnsafeBufferPointer { v in
                key.withUnsafeBufferPointer { k in
                    plain.withUnsafeMutableBufferPointer { p in
                        c_aes128_cbc_decrypt(k.baseAddress, v.baseAddress, c.baseAddress, c.count, p.baseAddress, &plainLen)
                    }
                }
            }
        }
        guard st == 0, plainLen > 32 else { return nil }
        return String(bytes: Array(plain.prefix(plainLen).dropFirst(32)), encoding: .utf8)
    }
}
