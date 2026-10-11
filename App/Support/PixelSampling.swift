import CoreVideo
import ScanCore
import simd

extension RigidTransform {
    init(_ m: simd_float4x4) {
        self.init(m.columns.0, m.columns.1, m.columns.2, m.columns.3)
    }
}

extension Intrinsics {
    /// From a camera matrix laid out the way ARKit and AVFoundation deliver it
    /// (column-major: focal lengths on the diagonal, principal point in column 2).
    init(_ k: simd_float3x3) {
        self.init(fx: k.columns.0.x, fy: k.columns.1.y, cx: k.columns.2.x, cy: k.columns.2.y)
    }
}

extension DepthImage {
    /// Copies a kCVPixelFormatType_DepthFloat32 buffer.
    init?(depthMap buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        self.init(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                  rowStride: CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.stride,
                  data: base.assumingMemoryBound(to: Float.self))
    }
}

/// Copies a one-byte-per-pixel buffer (e.g. ARKit's depth confidence map).
func copyBytes(of buffer: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [UInt8](repeating: 0, count: w * h) }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let src = base.assumingMemoryBound(to: UInt8.self)
    var out = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w { out[y * w + x] = src[y * stride + x] }
    }
    return out
}

/// Reads RGB colours out of ARKit's bi-planar full-range YCbCr camera image.
/// Locks the buffer for its lifetime; call `unlock()` when done.
final class YCbCrSampler {
    private let buffer: CVPixelBuffer
    let width: Int
    let height: Int
    private let luma: UnsafePointer<UInt8>
    private let lumaStride: Int
    private let chroma: UnsafePointer<UInt8>
    private let chromaStride: Int

    init?(_ buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPlaneCount(buffer) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            return nil
        }
        self.buffer = buffer
        width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        luma = UnsafePointer(y.assumingMemoryBound(to: UInt8.self))
        lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        chroma = UnsafePointer(c.assumingMemoryBound(to: UInt8.self))
        chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    }

    func unlock() {
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    }

    /// BT.601 full-range conversion, which is what ARKit's camera image uses.
    func rgb(x: Int, y: Int) -> SIMD3<UInt8> {
        let px = min(max(x, 0), width - 1), py = min(max(y, 0), height - 1)
        let Y = Float(luma[py * lumaStride + px])
        let ci = (py / 2) * chromaStride + (px / 2) * 2
        let cb = Float(chroma[ci]) - 128
        let cr = Float(chroma[ci + 1]) - 128
        return SIMD3(clampByte(Y + 1.402 * cr),
                     clampByte(Y - 0.344136 * cb - 0.714136 * cr),
                     clampByte(Y + 1.772 * cb))
    }
}

/// A copied BGRA video frame, safe to keep after the capture buffer is recycled.
struct BGRAImage {
    let width: Int
    let height: Int
    private let pixels: [UInt8]

    init?(_ buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let src = base.assumingMemoryBound(to: UInt8.self)
        var copy = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for i in 0..<(width * 4) { copy[y * width * 4 + i] = src[y * stride + i] }
        }
        pixels = copy
    }

    func rgb(x: Int, y: Int) -> SIMD3<UInt8> {
        let px = min(max(x, 0), width - 1), py = min(max(y, 0), height - 1)
        let i = (py * width + px) * 4
        return SIMD3(pixels[i + 2], pixels[i + 1], pixels[i])
    }
}

@inline(__always)
private func clampByte(_ v: Float) -> UInt8 {
    UInt8(min(max(v, 0), 255))
}
