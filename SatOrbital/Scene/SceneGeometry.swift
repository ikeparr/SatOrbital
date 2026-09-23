import RealityKit

@MainActor
enum SceneGeometry {
    /// Explicit UVs put north at the top of the bundled equirectangular map.
    static func globe() throws -> MeshResource {
        let rows = 96, columns = 192
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        for row in 0...rows {
            let v = Float(row) / Float(rows)
            let latitude = Float.pi / 2 - v * .pi
            for column in 0...columns {
                let u = Float(column) / Float(columns)
                let longitude = u * 2 * .pi - .pi
                let p = SIMD3<Float>(cos(latitude) * sin(longitude), sin(latitude), cos(latitude) * cos(longitude))
                let e2 = Float(EarthCoordinates.eccentricitySquared)
                let n = 1 / sqrt(1 - e2 * sin(latitude) * sin(latitude))
                positions.append([p.x * n, p.y * n * (1 - e2), p.z * n])
                normals.append(p)
                // RealityKit's texture V axis starts at the bottom of the image.
                uvs.append([u, 1 - v])
                if row < rows && column < columns {
                    let a = UInt32(row * (columns + 1) + column)
                    let b = a + UInt32(columns + 1)
                    indices += [a, b, a + 1, a + 1, b, b + 1]
                }
            }
        }
        var descriptor = MeshDescriptor(name: "Earth")
        descriptor.positions = .init(positions)
        descriptor.normals = .init(normals)
        descriptor.textureCoordinates = .init(uvs)
        descriptor.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descriptor])
    }

    static func orbitTube(points: [SIMD3<Float>]) throws -> MeshResource {
        precondition(points.count >= 5 && points.first == points.last)
        let sides = 6
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for index in points.indices {
            let center = points[index]
            // Wrap neighbors across the duplicated closing point so the tube's
            // first and last cross sections meet with identical normals.
            let count = points.count - 1
            let previous = (index + count - 1) % count
            let next = (index + 1) % count
            let tangent = normalize(points[next] - points[previous])
            let radial = normalize(center)
            let crossAxis = normalize(cross(tangent, radial))
            let outward = normalize(cross(crossAxis, tangent))
            for side in 0..<sides {
                let angle = Float(side) / Float(sides) * 2 * .pi
                let normal = outward * cos(angle) + crossAxis * sin(angle)
                positions.append(center + normal * 0.0025)
                normals.append(normal)
                if index < points.count - 1 {
                    let a = UInt32(index * sides + side)
                    let b = UInt32(index * sides + (side + 1) % sides)
                    let c = a + UInt32(sides)
                    let d = b + UInt32(sides)
                    indices += [a, b, c, b, d, c]
                }
            }
        }
        var descriptor = MeshDescriptor(name: "ISS current orbital ellipse")
        descriptor.positions = .init(positions)
        descriptor.normals = .init(normals)
        descriptor.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descriptor])
    }
}
