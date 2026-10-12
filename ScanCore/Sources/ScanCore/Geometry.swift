import Foundation

/// Pinhole camera intrinsics in pixel units of a specific image size.
public struct Intrinsics: Equatable {
    public var fx: Float
    public var fy: Float
    public var cx: Float
    public var cy: Float

    public init(fx: Float, fy: Float, cx: Float, cy: Float) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
    }

    /// Intrinsics for an image `sx` times wider and `sy` times taller than the
    /// one these were calibrated for (e.g. the colour camera vs. the depth map).
    public func scaled(x sx: Float, y sy: Float) -> Intrinsics {
        Intrinsics(fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy)
    }

    /// Estimate from a horizontal field of view, assuming square pixels and a
    /// centred principal point. Used when a device gives no calibration data.
    public static func fromHorizontalFOV(degrees: Float, width: Int, height: Int) -> Intrinsics {
        let half = degrees * .pi / 360
        let f = Float(width) / 2 / tan(half)
        return Intrinsics(fx: f, fy: f, cx: Float(width) / 2, cy: Float(height) / 2)
    }

    /// Back-project pixel (u, v) at metric depth `z` into camera space using the
    /// ARKit / OpenGL convention: +x right, +y up, camera looking down -z.
    @inline(__always)
    public func unproject(u: Float, v: Float, depth z: Float) -> SIMD3<Float> {
        SIMD3((u - cx) / fx * z, -(v - cy) / fy * z, -z)
    }
}

/// A 4x4 affine transform stored column-major, laid out like `simd_float4x4`
/// so platform code can convert with a straight copy of the columns.
public struct RigidTransform: Equatable {
    public var c0: SIMD4<Float>
    public var c1: SIMD4<Float>
    public var c2: SIMD4<Float>
    public var c3: SIMD4<Float>

    public init(_ c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>, _ c3: SIMD4<Float>) {
        self.c0 = c0
        self.c1 = c1
        self.c2 = c2
        self.c3 = c3
    }

    public static let identity = RigidTransform(
        SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))

    public static func translation(_ t: SIMD3<Float>) -> RigidTransform {
        var m = identity
        m.c3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }

    /// Rotation by `radians` about the +z axis (counter-clockwise seen from +z).
    public static func rotationZ(_ radians: Float) -> RigidTransform {
        let c = cos(radians), s = sin(radians)
        return RigidTransform(SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
    }

    @inline(__always)
    public func apply(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let r = c0 * p.x + c1 * p.y + c2 * p.z + c3
        return SIMD3(r.x, r.y, r.z)
    }

    /// Applies only the linear part (for directions such as normals).
    @inline(__always)
    public func applyDirection(_ d: SIMD3<Float>) -> SIMD3<Float> {
        let r = c0 * d.x + c1 * d.y + c2 * d.z
        return SIMD3(r.x, r.y, r.z)
    }

    /// Where the transformed frame's origin lands (e.g. the camera position).
    public var origin: SIMD3<Float> { SIMD3(c3.x, c3.y, c3.z) }

    /// The inverse, assuming the transform is a rotation plus a translation.
    public var inverse: RigidTransform {
        let x = SIMD3(c0.x, c0.y, c0.z), y = SIMD3(c1.x, c1.y, c1.z), z = SIMD3(c2.x, c2.y, c2.z)
        let t = origin
        return RigidTransform(SIMD4(c0.x, c1.x, c2.x, 0), SIMD4(c0.y, c1.y, c2.y, 0), SIMD4(c0.z, c1.z, c2.z, 0),
                              SIMD4(-(x * t).sum(), -(y * t).sum(), -(z * t).sum(), 1))
    }
}

@inline(__always)
func crossProduct(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

@inline(__always)
func vectorLength(_ v: SIMD3<Float>) -> Float {
    (v * v).sum().squareRoot()
}

@inline(__always)
func unitVector(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let l = vectorLength(v)
    return l > 0 ? v / l : SIMD3(0, 0, 0)
}
