//
//  StripeErrorTests.swift
//  
//
//  Created by Copilot on 7/19/26.
//

import XCTest
@testable import StripeKit

/// Stripe's documented error `type`/`code`/`decline_code` values evolve over time (e.g.
/// `customer_tax_location_invalid`), but `StripeErrorType`, `StripeErrorCode`, and
/// `StripeDeclineCode` are fixed, hardcoded `String` enums. Previously, decoding any
/// unrecognized raw value threw a raw `DecodingError` that failed the *entire*
/// `_StripeError`/`StripeError` decode (see `StripeRequest.swift`), producing an unhandled
/// error for API consumers instead of a catchable `StripeError` with a usable `.message`.
/// These tests confirm unrecognized values decode leniently to a `.unknown` fallback instead.
class StripeErrorTests: XCTestCase {

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    func testStripeErrorCode_decodesUnrecognizedValue_asUnknown_andSiblingFieldsStillDecode() throws {
        let json = """
        {
            "error": {
                "type": "invalid_request_error",
                "code": "some_future_code_stripe_hasnt_invented_yet",
                "message": "Some new error message from Stripe."
            }
        }
        """.data(using: .utf8)!

        let error = try makeDecoder().decode(StripeError.self, from: json)

        XCTAssertEqual(error.error?.code, .unknown)
        // Proves an unrecognized `code` no longer blows up decoding of the whole struct.
        XCTAssertEqual(error.error?.type, .invalidRequestError)
        XCTAssertEqual(error.error?.message, "Some new error message from Stripe.")
    }

    func testStripeErrorType_decodesUnrecognizedValue_asUnknown() throws {
        let json = """
        {
            "error": {
                "type": "some_future_type_stripe_hasnt_invented_yet",
                "message": "Some new error message from Stripe."
            }
        }
        """.data(using: .utf8)!

        let error = try makeDecoder().decode(StripeError.self, from: json)

        XCTAssertEqual(error.error?.type, .unknown)
        XCTAssertEqual(error.error?.message, "Some new error message from Stripe.")
    }

    func testStripeDeclineCode_decodesUnrecognizedValue_asUnknown() throws {
        let json = """
        {
            "error": {
                "type": "card_error",
                "decline_code": "some_future_decline_code_stripe_hasnt_invented_yet",
                "message": "Your card was declined."
            }
        }
        """.data(using: .utf8)!

        let error = try makeDecoder().decode(StripeError.self, from: json)

        XCTAssertEqual(error.error?.declineCode, .unknown)
        XCTAssertEqual(error.error?.type, .cardError)
    }

    func testStripeErrorCode_decodesCustomerTaxLocationInvalid() throws {
        let json = """
        {
            "error": {
                "type": "invalid_request_error",
                "code": "customer_tax_location_invalid",
                "message": "Customer tax location could not be determined."
            }
        }
        """.data(using: .utf8)!

        let error = try makeDecoder().decode(StripeError.self, from: json)

        XCTAssertEqual(error.error?.code, .customerTaxLocationInvalid)
    }

    func testStripeErrorCode_decodesKnownValue_withoutRegression() throws {
        let json = """
        {
            "error": {
                "type": "card_error",
                "code": "card_declined",
                "message": "Your card was declined."
            }
        }
        """.data(using: .utf8)!

        let error = try makeDecoder().decode(StripeError.self, from: json)

        XCTAssertEqual(error.error?.type, .cardError)
        XCTAssertEqual(error.error?.code, .cardDeclined)
    }

    func testStripeErrorCode_missingKey_decodesAsNil_withoutRegression() throws {
        let json = """
        {
            "error": {
                "type": "api_error",
                "message": "Something went wrong."
            }
        }
        """.data(using: .utf8)!

        let error = try makeDecoder().decode(StripeError.self, from: json)

        XCTAssertNil(error.error?.code)
        XCTAssertNil(error.error?.declineCode)
        XCTAssertEqual(error.error?.type, .apiError)
    }

    func testUnknownCase_encodesAndDecodesRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = makeDecoder()

        let encodedType = try encoder.encode(StripeErrorType.unknown)
        XCTAssertEqual(try decoder.decode(StripeErrorType.self, from: encodedType), .unknown)

        let encodedCode = try encoder.encode(StripeErrorCode.unknown)
        XCTAssertEqual(try decoder.decode(StripeErrorCode.self, from: encodedCode), .unknown)

        let encodedDeclineCode = try encoder.encode(StripeDeclineCode.unknown)
        XCTAssertEqual(try decoder.decode(StripeDeclineCode.self, from: encodedDeclineCode), .unknown)
    }
}
