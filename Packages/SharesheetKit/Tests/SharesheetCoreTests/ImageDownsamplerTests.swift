import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SharesheetCore

private func pngData(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func pixelSize(_ data: Data) throws -> (width: Int, height: Int) {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
}

@Test func downsamplesALargeImageToAJPEGThumbnail() throws {
    let file = try makeTempDirectory().appending(path: "big.png")
    try pngData(width: 3000, height: 1500).write(to: file)
    let jpeg = try #require(ImageDownsampler.jpegData(fromFileAt: file, maxPixelSize: 600))
    let size = try pixelSize(jpeg)
    #expect(size.width == 600 && size.height == 300)
    let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
    #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
}

@Test func downsamplesAPortraitImage() throws {
    let file = try makeTempDirectory().appending(path: "tall.png")
    try pngData(width: 800, height: 1600).write(to: file)
    let jpeg = try #require(ImageDownsampler.jpegData(fromFileAt: file, maxPixelSize: 600))
    let size = try pixelSize(jpeg)
    #expect(size.width == 300 && size.height == 600)
}

@Test func downsamplerRejectsNonImages() throws {
    let file = try makeTempDirectory().appending(path: "note.png")
    try Data("not an image".utf8).write(to: file)
    #expect(ImageDownsampler.jpegData(fromFileAt: file, maxPixelSize: 600) == nil)
}
