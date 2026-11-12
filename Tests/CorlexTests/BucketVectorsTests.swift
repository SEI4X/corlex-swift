import XCTest
@testable import Corlex

/// The shared vectors of `packages/domain/test-vectors/remote-config.json` (copied into
/// Fixtures; CI checks the copy is identical). A person must land in the same bucket and the
/// same variant here as on the server and in the other SDKs.
final class BucketVectorsTests: XCTestCase {
    private struct BucketCase: Decodable { let key: String; let userId: String; let bucket: Int }
    private struct Series: Decodable { let key: String; let prefix: String; let count: Int; let buckets: [Int] }
    private struct Expected: Decodable { let value: JSONValue }
    private struct Context: Decodable { let userId: String; let platform: String? }
    private struct ResolveCase: Decodable {
        let name: String
        let param: CompiledParam
        let context: Context
        let expected: Expected?
    }
    private struct ExpectedVariant: Decodable { let variant: String; let index: Int; let value: JSONValue }
    private struct ExperimentCase: Decodable {
        let name: String
        let experiment: CompiledExperiment
        let userId: String
        let expected: ExpectedVariant?
    }
    private struct ExperimentSeries: Decodable {
        let experiment: CompiledExperiment
        let prefix: String
        let count: Int
        let variants: [Int]
    }
    private struct Vectors: Decodable {
        let buckets: [BucketCase]
        let series: Series
        let resolve: [ResolveCase]
        let experiments: [ExperimentCase]
        let experimentSeries: ExperimentSeries
    }

    private func load() throws -> Vectors {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "remote-config", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testBucketsMatchTheSharedVectors() throws {
        let vectors = try load()
        XCTAssertGreaterThanOrEqual(vectors.buckets.count, 50)
        for item in vectors.buckets {
            XCTAssertEqual(Bucketing.bucket(key: item.key, userId: item.userId), item.bucket, "\(item.key) / \(item.userId)")
        }
    }

    func testSeriesOfAThousandPeople() throws {
        let series = try load().series
        let buckets = (0..<series.count).map { Bucketing.bucket(key: series.key, userId: "\(series.prefix)\($0)") }
        XCTAssertEqual(buckets, series.buckets)
    }

    func testResolveMatchesTheSharedVectors() throws {
        let cases = try load().resolve
        XCTAssertGreaterThanOrEqual(cases.count, 13)
        for item in cases {
            let got = ConfigEvaluator.resolve(item.param, userId: item.context.userId, platform: item.context.platform)
            XCTAssertEqual(got, item.expected?.value, item.name)
        }
    }

    func testExperimentAssignmentMatchesTheSharedVectors() throws {
        let cases = try load().experiments
        XCTAssertGreaterThanOrEqual(cases.count, 19)
        for item in cases {
            let got = ConfigEvaluator.assign(item.experiment, userId: item.userId)
            XCTAssertEqual(got?.variant, item.expected?.variant, item.name)
            XCTAssertEqual(got?.index, item.expected?.index, item.name)
            XCTAssertEqual(got?.value, item.expected?.value, item.name)
        }
    }

    func testExperimentSeriesAt80_20() throws {
        let series = try load().experimentSeries
        let got = (0..<series.count).map {
            ConfigEvaluator.assign(series.experiment, userId: "\(series.prefix)\($0)")?.index ?? -1
        }
        XCTAssertEqual(got, series.variants)
    }

    func testJSONNumbersKeepTheirKind() throws {
        let value = try JSONDecoder().decode([String: JSONValue].self, from: Data(#"{"a":7,"b":7.5,"c":true,"d":null,"e":"x","f":[1],"g":{"h":1}}"#.utf8))
        XCTAssertEqual(value["a"], .int(7))
        XCTAssertEqual(value["b"], .double(7.5))
        XCTAssertEqual(value["c"], .bool(true))
        XCTAssertEqual(value["d"], .null)
        XCTAssertEqual(value["f"], .array([.int(1)]))
    }
}
