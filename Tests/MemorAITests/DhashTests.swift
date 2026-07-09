import XCTest
import CoreGraphics
@testable import MemorAI

final class DhashTests: XCTestCase {

    /// Build a tiny solid-color CGImage for use as dhash input.
    private func solidColorImage(gray: UInt8, width: Int = 16, height: Int = 16) -> CGImage {
        var pixels = [UInt8](repeating: gray, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        return ctx.makeImage()!
    }

    func testSameImageTwiceProducesIdenticalHashesAndZeroDistance() {
        let capturer = ScreenCapturer()
        let image = solidColorImage(gray: 128)
        let h1 = capturer.dhash(image)
        let h2 = capturer.dhash(image)
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(capturer.hammingDistance(h1, h2), 0)
    }

    func testSolidBlackVsSolidWhiteSelfDistanceIsZero() {
        let capturer = ScreenCapturer()
        let black = solidColorImage(gray: 0)
        let white = solidColorImage(gray: 255)
        let hBlack = capturer.dhash(black)
        let hWhite = capturer.dhash(white)
        // Solid-color images have no gradients, so black vs white hashes may
        // legitimately be equal. We only assert self-distance is zero.
        XCTAssertEqual(capturer.hammingDistance(hBlack, hBlack), 0)
        XCTAssertEqual(capturer.hammingDistance(hWhite, hWhite), 0)
    }

    func testHammingDistancePureFunction() {
        let capturer = ScreenCapturer()
        XCTAssertEqual(capturer.hammingDistance(0b1011, 0b0010), 2)
        XCTAssertEqual(capturer.hammingDistance(0, .max), 64)
    }
}
