import Foundation

/// How a list shows a number field over the entries that have it.
public enum FieldAggregate: String, CaseIterable, Sendable, Codable {
    case sum, average, median, min, max, stdDev, count

    /// nil when the values do not allow a result (no values; fewer than two for the deviation).
    public func value(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sum = values.reduce(0, +)
        switch self {
        case .sum: return sum
        case .average: return sum / Double(values.count)
        case .min: return values.min()
        case .max: return values.max()
        case .count: return Double(values.count)
        case .median:
            let sorted = values.sorted(), mid = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        case .stdDev:
            guard values.count > 1 else { return nil }
            let mean = sum / Double(values.count)
            return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count - 1)).squareRoot()
        }
    }
}
