//
//  YXCrypto.swift
//  YunX · 密码学工具（各网盘签名/加密共用）
//

import Foundation
import CryptoKit
import CommonCrypto
import Compression

enum YXCrypto {

    // MARK: - 摘要

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func md5Hex(_ data: Data) -> String {
        hex(Data(Insecure.MD5.hash(data: data)))
    }

    static func md5Hex(_ text: String) -> String {
        md5Hex(Data(text.utf8))
    }

    static func sha1Hex(_ data: Data) -> String {
        hex(Data(Insecure.SHA1.hash(data: data)))
    }

    static func sha1Hex(_ text: String) -> String {
        sha1Hex(Data(text.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    // MARK: - CRC32

    private static let crc32Table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        return table
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    /// 123 云盘用：8 位小写、不补前导 0
    static func crc32Hex(_ data: Data) -> String {
        String(crc32(data), radix: 16)
    }

    static func crc32Hex(_ text: String) -> String {
        crc32Hex(Data(text.utf8))
    }

    // MARK: - AES

    /// AES-CBC + PKCS7（139 网盘）
    static func aesCBC(key: Data, iv: Data, data: Data, encrypt: Bool) -> Data? {
        guard key.count == kCCKeySizeAES128 || key.count == kCCKeySizeAES256,
              iv.count == kCCBlockSizeAES128 else { return nil }
        let outLength = data.count + kCCBlockSizeAES128
        var out = Data(count: outLength)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outBytes -> CCCryptorStatus in
            guard let outPtr = outBytes.bindMemory(to: UInt8.self).baseAddress else {
                return CCCryptorStatus(kCCMemoryFailure)
            }
            return key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    data.withUnsafeBytes { dataBytes in
                        CCCrypt(
                            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            outPtr, outLength,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(moved..<out.count)
        return out
    }

    /// AES-ECB + PKCS7（蓝奏优享）
    static func aesECB(key: Data, data: Data, encrypt: Bool) -> Data? {
        let outLength = data.count + kCCBlockSizeAES128
        var out = Data(count: outLength)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outBytes -> CCCryptorStatus in
            guard let outPtr = outBytes.bindMemory(to: UInt8.self).baseAddress else {
                return CCCryptorStatus(kCCMemoryFailure)
            }
            return key.withUnsafeBytes { keyBytes in
                data.withUnsafeBytes { dataBytes in
                    CCCrypt(
                        CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                        keyBytes.baseAddress, key.count,
                        nil,
                        dataBytes.baseAddress, data.count,
                        outPtr, outLength,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(moved..<out.count)
        return out
    }

    // MARK: - Gzip（139 响应体）

    /// 只做 gzip → raw deflate 的头尾剥离，解压交给 Compression 框架，
    /// 避免直接操作 z_stream 指针（嵌套闭包对同一 var 取地址会触发访问冲突检查）。
    static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18,
              data[data.startIndex] == 0x1F,
              data[data.startIndex + 1] == 0x8B else { return nil }
        let flags = data[data.startIndex + 3]
        var offset = 10

        if flags & 0x04 != 0 {                      // FEXTRA
            guard data.count > offset + 2 else { return nil }
            let xlen = Int(data[data.startIndex + offset])
                | (Int(data[data.startIndex + offset + 1]) << 8)
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 {                      // FNAME
            while offset < data.count, data[data.startIndex + offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {                      // FCOMMENT
            while offset < data.count, data[data.startIndex + offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }        // FHCRC

        let end = data.count - 8                    // 去掉 CRC32 + ISIZE
        guard offset < end else { return nil }
        let payload = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end))

        return decompressDeflate(payload)
    }

    private static func decompressDeflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        var capacity = max(input.count * 6, 64 * 1024)
        for _ in 0..<5 {
            var out = Data(count: capacity)
            let produced = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                guard let dstPtr = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                    guard let srcPtr = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(dstPtr, capacity,
                                                     srcPtr, input.count,
                                                     nil, COMPRESSION_ZLIB)
                }
            }
            if produced > 0 {
                out.removeSubrange(produced..<out.count)
                return out
            }
            capacity *= 4
        }
        return nil
    }

    // MARK: - 随机

    static func randomHex(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func randomAlphaNumeric(_ count: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var out = ""
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        for b in bytes {
            out.append(chars[Int(b) % chars.count])
        }
        return out
    }

    static func randomInt(_ upperBound: Int) -> Int {
        var value: UInt32 = 0
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &value)
        return Int(value % UInt32(max(1, upperBound)))
    }
}
