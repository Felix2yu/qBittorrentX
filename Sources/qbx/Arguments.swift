import Foundation

/// 极简参数解析。零第三方依赖，够用就好：`--flag value`、`--bool`、位置参数。
struct Arguments {
    private var options: [String: String] = [:]
    private var flags: Set<String> = []
    private(set) var positional: [String] = []

    init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            let token = raw[i]
            if token.hasPrefix("--") {
                let name = String(token.dropFirst(2))
                // 下一个 token 不是选项时当作值，否则当布尔开关。
                if i + 1 < raw.count, !raw[i + 1].hasPrefix("--") {
                    options[name] = raw[i + 1]
                    i += 2
                } else {
                    flags.insert(name)
                    i += 1
                }
            } else {
                positional.append(token)
                i += 1
            }
        }
    }

    func string(_ name: String) -> String? { options[name] }
    func string(_ name: String, default fallback: String) -> String { options[name] ?? fallback }
    func has(_ name: String) -> Bool { flags.contains(name) || options[name] != nil }
    func int(_ name: String) -> Int? { options[name].flatMap(Int.init) }
    func int(_ name: String, default fallback: Int) -> Int { int(name) ?? fallback }
    func double(_ name: String) -> Double? { options[name].flatMap(Double.init) }

    /// 逗号分隔的多值，如 `--hashes a,b`。
    func list(_ name: String) -> [String] {
        guard let raw = options[name] else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}