import Foundation
import CCrypto

// Chromium/Electron cookie decryption shared by Claude Desktop and Figma Desktop:
//  1. Keychain "<App> Safe Storage" password -> PBKDF2-SHA1("saltysalt", 1003) -> AES-128 key
//  2. encrypted_value = "v10" + AES-128-CBC (IV = 16 spaces, PKCS7)
//  3. plaintext = 32-byte SHA-256 host prefix + cookie value
enum ChromiumCookie {
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
