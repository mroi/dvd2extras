import XCTest

@testable import MovieArchiveConverter


/* MARK: Converter Tests */

class ConverterTests: XCTestCase {

	func testDeinitialization() {
		let deinitClient = expectation(description: "converter client should be released")
		let deinitReturn = expectation(description: "return channel should be released")

		class TestClient: ConverterClient<ConverterInterface> {
			let deinitClient: XCTestExpectation
			init(withExpectations expectations: XCTestExpectation...) {
				deinitClient = expectations[0]
			}
			deinit {
				deinitClient.fulfill()
			}
		}
		class TestReturn: ReturnImplementation {
			let deinitReturn: XCTestExpectation
			init(withExpectations expectations: XCTestExpectation...) {
				deinitReturn = expectations[0]
			}
			deinit {
				deinitReturn.fulfill()
			}
		}

		// do complicated stuff with client and return and check for proper release
		do {
			let client = TestClient(withExpectations: deinitClient)
			let returnChannel = TestReturn(withExpectations: deinitReturn)
			try! ConverterClient.withMocks(proxy: client.remote, publisher: returnChannel.publisher) {
				XCTAssertNoThrow(
					try client.withConnectionErrorHandling { done in
						done(.success(ConverterClient<ConverterInterface>()))
					}
				)
				returnChannel.sendConnectionInterrupted()
			}
		}

		waitForExpectations(timeout: .infinity)
	}

	func testXPCErrorPropagation() {
		// set up an invalid XPC connection
		let returnChannel = ReturnImplementation()
		let connection = NSXPCConnection(serviceName: "invalid")
		connection.remoteObjectInterface = NSXPCInterface(with: ConverterTesting.self)
		connection.invalidationHandler = { returnChannel.sendConnectionInvalid() }
		connection.interruptionHandler = { returnChannel.sendConnectionInterrupted() }
		connection.resume()
		defer { connection.invalidate() }

		// expect publisher to report the error
		let publisherFailure = expectation(description: "publisher should fail")
		let subscription = returnChannel.publisher.sink(
			receiveCompletion: {
				XCTAssertEqual($0, .failure(.connectionInvalid))
				publisherFailure.fulfill()
			},
			receiveValue: { _ in })
		defer { subscription.cancel() }

		// exercise the invalid connection
		ConverterClient.withMocks(proxy: connection.remoteObjectProxy, publisher: returnChannel.publisher) {
			let remote = connection.remoteObjectProxy as! ConverterTesting
			remote.doNothing()
		}

		waitForExpectations(timeout: .infinity)
	}

	func testXPCErrorWrapper() {
		class ErrorSender {
			private let returnChannel: ReturnImplementation
			init(channel: ReturnImplementation) { returnChannel = channel }
			func error() { returnChannel.sendConnectionInterrupted() }
		}
		class ErrorClient: ConverterClient<ErrorSender> {
			func test() throws {
				// test that this wrapper observes the published error and throws
				try withConnectionErrorHandling { (_: (Result<Void, ConverterError>) -> Void) in
					remote.error()
				}
				XCTFail("error handling should throw")
			}
		}

		let returnChannel = ReturnImplementation()
		let sender = ErrorSender(channel: returnChannel)
		try! ConverterClient.withMocks(proxy: sender, publisher: returnChannel.publisher) {
			XCTAssertThrowsError(try ErrorClient().test()) {
				XCTAssertEqual($0 as! ConverterError, .connectionInterrupted)
			}
		}
	}
}

@objc private protocol ConverterTesting {
	func doNothing()
}
