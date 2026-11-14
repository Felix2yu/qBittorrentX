import Foundation

/// CLI 表格排版。中文占 2 列，`padding(toLength:)` 与 `prefix` 都按字符数算，会把表格撑歪。
enum TextTable {
    static func 截断(_ s: String, _ 列宽: Int) -> String {
        var 宽 = 0
        var out = ""
        for ch in s {
            let w = 显示宽(ch)
            if 宽 + w > 列宽 { return out + "…" }
            out.append(ch)
            宽 += w
        }
        return out
    }

    static func pad(_ s: String, _ width: Int) -> String {
        let 宽 = s.reduce(0) { $0 + 显示宽($1) }
        return 宽 >= width ? s + " " : s + String(repeating: " ", count: width - 宽)
    }

    private static func 显示宽(_ ch: Character) -> Int {
        ch.unicodeScalars.allSatisfy { $0.value < 0x1100 } ? 1 : 2
    }
}