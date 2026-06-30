// Headless SwiftTerm replay harness — feeds a captured PTY byte stream into a
// Terminal and dumps the visible cell buffer as text, to localize garbling.
// Usage: replay <capture.raw> <cols> <rows> [--frames]
//   default: dump the final visible buffer
//   --frames: dump the visible buffer after every synchronized-output commit (ESU),
//             so we can spot which committed frame is garbled.
import Foundation
import SwiftTerm

final class NullDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
    func sizeChanged(source: Terminal) {}
    func setTerminalTitle(source: Terminal, title: String) {}
    func scrolled(source: Terminal, yDisp: Int) {}
    func bufferActivated(source: Terminal) {}
    func bell(source: Terminal) {}
    func mouseModeChanged(source: Terminal) {}
}

let args = CommandLine.arguments
let path = args.count > 1 ? args[1] : "/tmp/leader-pty-capture.raw"
let cols = args.count > 2 ? (Int(args[2]) ?? 87) : 87
let rows = args.count > 3 ? (Int(args[3]) ?? 74) : 74
let perFrame = args.contains("--frames")

let data = [UInt8]((try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data())
var opts = TerminalOptions.default
opts.cols = cols
opts.rows = rows
let term = Terminal(delegate: NullDelegate(), options: opts)

func dumpVisible(_ label: String) {
    print("==== \(label) (yDisp=\(term.buffer.yDisp), altScreen=\(term.isCurrentBufferAlternate)) ====")
    for y in 0..<rows {
        let s = term.getLine(row: y)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? ""
        print(String(format: "%2d|", y) + s)
    }
}

// Find ESU terminators: ESC [ ? 2026 l
let esu: [UInt8] = [0x1b, 0x5b, 0x3f, 0x32, 0x30, 0x32, 0x36, 0x6c]
func indicesOfESU() -> [Int] {
    var out: [Int] = []
    if data.count < esu.count { return out }
    var i = 0
    while i <= data.count - esu.count {
        if Array(data[i..<i+esu.count]) == esu { out.append(i + esu.count); i += esu.count } else { i += 1 }
    }
    return out
}

if perFrame {
    let bounds = indicesOfESU()
    var prev = 0
    for (n, b) in bounds.enumerated() {
        term.feed(byteArray: Array(data[prev..<b]))
        prev = b
        dumpVisible("FRAME \(n+1)/\(bounds.count) [bytes \(prev)]")
    }
    if prev < data.count { term.feed(byteArray: Array(data[prev...])); dumpVisible("FINAL tail") }
} else {
    term.feed(byteArray: data)
    dumpVisible("FINAL (\(data.count) bytes fed)")
}
