import XCTest
import NIO
import NIOHTTP1
@testable import AsyncHTTPClient
@testable import StripeKit

final class PromotionCodeTests: XCTestCase {
    private let currentResponse = """
    {
        "id": "promo_123", "object": "promotion_code", "code": "AUTO123",
        "created": 1700000000, "active": true, "customer": null,
        "promotion": {"type": "coupon", "coupon": "coupon_123"},
        "expires_at": 1800000000, "max_redemptions": 1,
        "restrictions": {"minimum_amount": 30000, "minimum_amount_currency": "eur"}
    }
    """

    private func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: Data(json.utf8))
    }

    private func parameters(_ request: HTTPClientRequest) throws -> [String: String] {
        // The route sends a byte buffer; inspect it without executing an HTTP request.
        guard let body = request.body, case .byteBuffer(let buffer) = body.mode else {
            XCTFail("Expected an in-memory request body")
            return [:]
        }
        return try Dictionary(uniqueKeysWithValues: String(buffer: buffer).split(separator: "&").map {
            let pair = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            XCTAssertEqual(pair.count, 2)
            return (
                try XCTUnwrap(String(pair[0]).removingPercentEncoding),
                try XCTUnwrap(String(try XCTUnwrap(pair.last)).removingPercentEncoding)
            )
        })
    }

    func testCreateUsesCloverParametersAndForwardsHeaders() async throws {
        let handler = StripeAPIHandler(apiKey: "sk_test_not_a_real_key") { request in
            XCTAssertEqual(request.method, .POST)
            XCTAssertEqual(URLComponents(string: request.url)?.path, "/v1/promotion_codes")
            XCTAssertEqual(URLComponents(string: request.url)?.host, "api.stripe.com")
            XCTAssertEqual(request.headers.first(name: "Stripe-Version"), "2026-02-25.clover")
            XCTAssertEqual(request.headers.first(name: "Authorization"), "Bearer sk_test_not_a_real_key")
            XCTAssertEqual(request.headers.first(name: "Content-Type"), "application/x-www-form-urlencoded")
            XCTAssertEqual(request.headers.first(name: "Idempotency-Key"), "logbook-promo-123")
            XCTAssertEqual(request.headers.first(name: "Stripe-Account"), "acct_123")
            XCTAssertEqual(try self.parameters(request), [
                "promotion[type]": "coupon",
                "promotion[coupon]": "coupon_123",
                "expires_at": "1800000000",
                "max_redemptions": "1",
                "restrictions[minimum_amount]": "30000",
                "restrictions[minimum_amount_currency]": "eur"
            ])
            return HTTPClientResponse(body: .bytes(ByteBuffer(string: self.currentResponse)))
        }
        var routes = StripePromotionCodesRoutes(apiHandler: handler)
        routes.headers = ["Idempotency-Key": "logbook-promo-123", "Stripe-Account": "acct_123"]
        let result = try await routes.create(
            coupon: "coupon_123",
            expiresAt: Date(timeIntervalSince1970: 1800000000.75),
            maxRedemptions: 1,
            restrictions: ["minimum_amount": 30000, "minimum_amount_currency": "eur"]
        )
        XCTAssertEqual(result.code, "AUTO123")
        XCTAssertEqual(result.promotion?.type, "coupon")
        XCTAssertEqual(result.promotion?.coupon, "coupon_123")
        XCTAssertEqual(result.expiresAt, Date(timeIntervalSince1970: 1800000000))
        XCTAssertEqual(result.restrictions?.minimumAmount, 30000)
        XCTAssertEqual(result.restrictions?.minimumAmountCurrency, "eur")
    }

    func testCreatePreservesExplicitOptionalParameters() async throws {
        let handler = StripeAPIHandler(apiKey: "sk_test_not_a_real_key") { request in
            XCTAssertEqual(try self.parameters(request), [
                "promotion[type]": "coupon", "promotion[coupon]": "coupon_123",
                "code": "SAVE+10", "metadata[source]": "Logbook & friends",
                "active": "false", "customer": "cus_123"
            ])
            return HTTPClientResponse(body: .bytes(ByteBuffer(string: self.currentResponse)))
        }
        _ = try await StripePromotionCodesRoutes(apiHandler: handler).create(
            coupon: "coupon_123", code: "SAVE+10",
            metadata: ["source": "Logbook & friends"], active: false, customer: "cus_123"
        )
    }

    func testNestedPromotionSurvivesDecodingAndEncoding() throws {
        let result = try decode(PromotionCode.self, json: currentResponse)
        XCTAssertEqual(result.promotion?.type, "coupon")
        XCTAssertEqual(result.promotion?.coupon, "coupon_123")
        XCTAssertNil(result.coupon)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        let promotion = try XCTUnwrap(encoded["promotion"] as? [String: String])
        XCTAssertEqual(promotion, ["type": "coupon", "coupon": "coupon_123"])
    }

    func testExpandedNestedCouponDecodes() throws {
        let result = try decode(PromotionCode.self, json: """
        {
            "id": "promo_123", "object": "promotion_code", "created": 1700000000,
            "promotion": {
                "type": "coupon",
                "coupon": {
                    "id": "coupon_123", "object": "coupon", "created": 1700000000,
                    "percent_off": 12.5, "applies_to": {"products": ["prod_123"]}
                }
            }
        }
        """)
        XCTAssertEqual(result.promotion?.$coupon?.id, "coupon_123")
        XCTAssertEqual(result.promotion?.$coupon?.percentOff, 12.5)
        XCTAssertEqual(result.promotion?.$coupon?.appliesTo?.products, ["prod_123"])
    }

    func testLegacyCouponStillDecodes() throws {
        let result = try decode(PromotionCode.self, json: """
        {
            "id": "promo_legacy", "object": "promotion_code", "created": 1700000000,
            "coupon": {"id": "coupon_123", "object": "coupon", "created": 1700000000, "percent_off": 10}
        }
        """)
        XCTAssertEqual(result.coupon?.id, "coupon_123")
        XCTAssertEqual(result.coupon?.percentOff, 10)
        XCTAssertNil(result.promotion)
    }

    func testCouponDecodesFractionalPercentage() throws {
        let result = try decode(Coupon.self, json: """
        {"id": "coupon_123", "object": "coupon", "created": 1700000000, "percent_off": 12.5}
        """)
        XCTAssertEqual(result.percentOff, 12.5)
    }

    func testCouponDecodesProductRestrictions() throws {
        let result = try decode(Coupon.self, json: """
        {
            "id": "coupon_123", "object": "coupon", "created": 1700000000,
            "applies_to": {"products": ["prod_123"]}
        }
        """)
        XCTAssertEqual(result.appliesTo?.products, ["prod_123"])
    }

    func testCouponCreateEncodesProductRestrictions() async throws {
        let handler = StripeAPIHandler(apiKey: "sk_test_not_a_real_key") { request in
            XCTAssertEqual(try self.parameters(request), [
                "percent_off": "12.5", "duration": "once",
                "applies_to[products][0]": "prod_123"
            ])
            return HTTPClientResponse(body: .bytes(ByteBuffer(string: """
            {"id": "coupon_123", "object": "coupon", "created": 1700000000}
            """)))
        }
        _ = try await StripeCouponRoutes(apiHandler: handler).create(
            duration: .once, percentOff: 12.5, appliesTo: CouponAppliesTo(products: ["prod_123"])
        )
    }
}
