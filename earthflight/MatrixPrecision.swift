import simd

// Casts between the Double precision planetary maths and RealityKit's Float.
// They change precision only, never the transform. Nonisolated because the
// target defaults to MainActor isolation and a cast belongs to no actor.

extension simd_float4x4 {
    nonisolated init(_ matrix: simd_double4x4) {
        self.init(columns: (
            SIMD4<Float>(matrix.columns.0),
            SIMD4<Float>(matrix.columns.1),
            SIMD4<Float>(matrix.columns.2),
            SIMD4<Float>(matrix.columns.3)
        ))
    }
}

extension simd_double4x4 {
    nonisolated init(_ matrix: simd_float4x4) {
        self.init(columns: (
            SIMD4<Double>(matrix.columns.0),
            SIMD4<Double>(matrix.columns.1),
            SIMD4<Double>(matrix.columns.2),
            SIMD4<Double>(matrix.columns.3)
        ))
    }
}

extension simd_quatf {
    /// The rotation part of a rigid transform.
    nonisolated init(rotationOf matrix: simd_double4x4) {
        self.init(vector: SIMD4<Float>(simd_quatd(matrix).vector))
    }
}
