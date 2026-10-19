/// RC4, used by Jet to obfuscate the database header and, when a Jet 3/4
/// database is "encoded", every page after the header.
struct RC4 {
    private var state = [UInt8](repeating: 0, count: 256)
    private var i: UInt8 = 0
    private var j: UInt8 = 0

    init(key: [UInt8]) {
        for n in 0..<256 { state[n] = UInt8(n) }
        var j: UInt8 = 0
        for n in 0..<256 {
            j = j &+ state[n] &+ key[n % key.count]
            state.swapAt(n, Int(j))
        }
    }

    mutating func apply(_ data: inout [UInt8], range: Range<Int>) {
        for n in range {
            i = i &+ 1
            j = j &+ state[Int(i)]
            state.swapAt(Int(i), Int(j))
            data[n] ^= state[Int(state[Int(i)] &+ state[Int(j)])]
        }
    }
}
