//
//  BigUInt.swift
//  YunX · 定点大整数（115 网盘的 RSA modPow 用）
//
//  只需要「模幂」与「模乘」，不需要通用除法：
//  模乘用 double-and-add，加法后一次条件减法即可归约（因为两侧都 < m）。
//  115 的指数固定 65537，一次 modPow 只有 17 次模乘，性能足够。
//

import Foundation

struct BigUInt: Hashable, CustomStringConvertible {
    /// 小端 32 位 limb，无高位零（零值 = 空数组）
    private(set) var limbs: [UInt32]

    init() {
        self.limbs = []
    }

    init(_ value: UInt32) {
        self.limbs = value == 0 ? [] : [value]
    }

    init(limbs: [UInt32]) {
        var l = limbs
        while let last = l.last, last == 0 { l.removeLast() }
        self.limbs = l
    }

    init(hex: String) {
        var digits = hex.lowercased()
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") { digits.removeFirst(2) }
        digits = digits.filter { $0.isHexDigit }
        var result: [UInt32] = []
        var chars = Array(digits)
        // 从右往左每 8 个 hex = 一个 limb（小端）
        while !chars.isEmpty {
            let take = min(8, chars.count)
            let slice = chars.suffix(take)
            chars.removeLast(take)
            result.append(UInt32(String(slice), radix: 16) ?? 0)
        }
        self.init(limbs: result)
    }

    /// 大端字节串
    init(bytes: Data) {
        var value = BigUInt()
        for byte in bytes {
            value = value.shiftLeft(8).add(BigUInt(UInt32(byte)))
        }
        self = value
    }

    var isZero: Bool { limbs.isEmpty }

    var bitLength: Int {
        guard let last = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - last.leadingZeroBitCount)
    }

    var description: String {
        if limbs.isEmpty { return "0" }
        return limbs.reversed().map { String($0, radix: 16) }.joined(separator: ":")
    }

    // MARK: - 基本运算

    func bit(_ index: Int) -> Bool {
        let idx = index / 32
        guard idx < limbs.count else { return false }
        return (limbs[idx] >> UInt32(index % 32)) & 1 == 1
    }

    func shiftLeft(_ bits: Int) -> BigUInt {
        guard bits > 0, !isZero else { return self }
        let limbShift = bits / 32
        let bitShift = bits % 32
        var out = [UInt32](repeating: 0, count: limbs.count + limbShift + 1)
        for (i, limb) in limbs.enumerated() {
            let target = i + limbShift
            out[target] |= limb << UInt32(bitShift)
            if bitShift > 0 {
                out[target + 1] |= limb >> UInt32(32 - bitShift)
            }
        }
        return BigUInt(limbs: out)
    }

    func compare(_ other: BigUInt) -> Int {
        if limbs.count != other.limbs.count {
            return limbs.count < other.limbs.count ? -1 : 1
        }
        for i in stride(from: limbs.count - 1, through: 0, by: -1) {
            if limbs[i] != other.limbs[i] {
                return limbs[i] < other.limbs[i] ? -1 : 1
            }
        }
        return 0
    }

    func add(_ other: BigUInt) -> BigUInt {
        let count = max(limbs.count, other.limbs.count)
        var out = [UInt32](repeating: 0, count: count + 1)
        var carry: UInt64 = 0
        for i in 0..<count {
            let a = i < limbs.count ? UInt64(limbs[i]) : 0
            let b = i < other.limbs.count ? UInt64(other.limbs[i]) : 0
            let sum = a + b + carry
            out[i] = UInt32(sum & 0xFFFF_FFFF)
            carry = sum >> 32
        }
        out[count] = UInt32(carry)
        return BigUInt(limbs: out)
    }

    /// 前提：self >= other
    func subtract(_ other: BigUInt) -> BigUInt {
        var out = [UInt32](repeating: 0, count: limbs.count)
        var borrow: Int64 = 0
        for i in 0..<limbs.count {
            let a = Int64(limbs[i])
            let b = i < other.limbs.count ? Int64(other.limbs[i]) : 0
            var diff = a - b - borrow
            if diff < 0 {
                diff += 0x1_0000_0000
                borrow = 1
            } else {
                borrow = 0
            }
            out[i] = UInt32(diff)
        }
        return BigUInt(limbs: out)
    }

    // MARK: - 模运算

    /// self mod m（self 与 m 的量级差不大时几次减法即可；带保护上限）
    func modReduce(_ m: BigUInt) -> BigUInt {
        guard !m.isZero else { return self }
        var value = self
        var guardCount = 0
        while value.compare(m) >= 0 {
            value = value.subtract(m)
            guardCount += 1
            if guardCount > 4096 { break }
        }
        return value
    }

    /// (self * other) mod m，要求 self/other 已 < m
    func mulMod(_ other: BigUInt, _ m: BigUInt) -> BigUInt {
        var result = BigUInt()
        var addend = self.modReduce(m)
        let bits = other.bitLength
        for i in 0..<bits {
            if other.bit(i) {
                result = result.add(addend).modReduce(m)
            }
            addend = addend.add(addend).modReduce(m)
        }
        return result
    }

    /// self^exponent mod modulus
    func modPow(_ exponent: UInt32, _ modulus: BigUInt) -> BigUInt {
        guard !modulus.isZero else { return BigUInt() }
        var result = BigUInt(1).modReduce(modulus)
        var base = modReduce(modulus)
        var e = exponent
        while e > 0 {
            if e & 1 == 1 {
                result = result.mulMod(base, modulus)
            }
            base = base.mulMod(base, modulus)
            e >>= 1
        }
        return result
    }

    // MARK: - 输出

    /// 大端定长字节
    func toBytes(width: Int) -> Data {
        var out = Data(count: width)
        for i in 0..<width {
            let byteIndex = width - 1 - i
            let limbIndex = i / 4
            let offset = i % 4
            var value: UInt32 = 0
            if limbIndex < limbs.count {
                value = (limbs[limbIndex] >> UInt32(offset * 8)) & 0xFF
            }
            out[byteIndex] = UInt8(value)
        }
        return out
    }

    /// 去掉前导零的大端字节
    func toMinimalBytes() -> Data {
        let width = (bitLength + 7) / 8
        return toBytes(width: max(width, 1))
    }
}
