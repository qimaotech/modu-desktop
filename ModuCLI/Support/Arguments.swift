import Foundation

func normalizedArguments(_ arguments: [String]) -> [String] {
    var regular: [String] = [], global: [String] = [], index = 0
    while index < arguments.count {
        let value = arguments[index]
        if value == "--" { return regular + global + Array(arguments[index...]) }
        if value == "--json" || value.hasPrefix("--workspace=") { global.append(value) }
        else if value == "--workspace", index + 1 < arguments.count { global += [value, arguments[index + 1]]; index += 1 }
        else { regular.append(value) }
        index += 1
    }
    return regular + global
}
