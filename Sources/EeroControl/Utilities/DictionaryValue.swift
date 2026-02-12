import Foundation

enum DictionaryValue {
    static func value(in dict: [String: Any], path: [String]) -> Any? {
        var current: Any = dict
        for key in path {
            guard let next = (current as? [String: Any])?[key] else {
                return nil
            }
            current = next
        }
        return current
    }

    static func string(in dict: [String: Any], path: [String]) -> String? {
        value(in: dict, path: path) as? String
    }

    static func bool(in dict: [String: Any], path: [String]) -> Bool? {
        if let value = value(in: dict, path: path) as? Bool {
            return value
        }
        if let value = value(in: dict, path: path) as? NSNumber {
            return value.boolValue
        }
        return nil
    }

    static func int(in dict: [String: Any], path: [String]) -> Int? {
        if let value = value(in: dict, path: path) as? Int {
            return value
        }
        if let value = value(in: dict, path: path) as? NSNumber {
            return value.intValue
        }
        if let value = value(in: dict, path: path) as? String {
            return Int(value)
        }
        return nil
    }

    static func double(in dict: [String: Any], path: [String]) -> Double? {
        if let value = value(in: dict, path: path) as? Double {
            return value
        }
        if let value = value(in: dict, path: path) as? NSNumber {
            return value.doubleValue
        }
        if let value = value(in: dict, path: path) as? String {
            return Double(value)
        }
        return nil
    }

    static func dict(in dict: [String: Any], path: [String]) -> [String: Any]? {
        value(in: dict, path: path) as? [String: Any]
    }

    static func dictArray(in dict: [String: Any], path: [String]) -> [[String: Any]] {
        value(in: dict, path: path) as? [[String: Any]] ?? []
    }

    static func stringMap(in dict: [String: Any], path: [String]) -> [String: String] {
        guard let raw = value(in: dict, path: path) as? [String: Any] else {
            return [:]
        }
        return raw.reduce(into: [String: String]()) { partialResult, item in
            if let value = item.value as? String {
                partialResult[item.key] = value
            }
        }
    }

    static func id(fromURL urlString: String?) -> String {
        guard let raw = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return ""
        }

        if let url = URL(string: raw), url.scheme != nil {
            let components = url.pathComponents.filter { $0 != "/" }
            if let component = components.last, !component.isEmpty {
                return component
            }
        }

        let pathComponent = raw
            .split(separator: "/")
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let pathComponent, !pathComponent.isEmpty {
            return pathComponent
        }

        return raw
    }
}
