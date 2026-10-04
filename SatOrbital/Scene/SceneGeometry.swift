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

    static func graticule() throws -> [MeshResource] {
        let samples = 180
        let e2 = Float(EarthCoordinates.eccentricitySquared)
        func point(latitude: Float, longitude: Float) -> SIMD3<Float> {
            let n = 1 / sqrt(1 - e2 * pow(sin(latitude), 2))
            return SIMD3(n * cos(latitude) * sin(longitude),
                         n * (1 - e2) * sin(latitude),
                         n * cos(latitude) * cos(longitude)) * 1.0008
        }
        var lines: [[SIMD3<Float>]] = []
        for degrees in stride(from: -60, through: 60, by: 20) {
            var line = (0..<samples).map { index in
                point(latitude: Float(degrees) * .pi / 180,
                      longitude: Float(index) * 2 * .pi / Float(samples))
            }
            line.append(line[0]); lines.append(line)
        }
        for index in 0..<6 {
            let longitude = Float(index) * .pi / 6
            var line = (0..<samples).map { sample in
                point(latitude: Float(sample) * 2 * .pi / Float(samples), longitude: longitude)
            }
            line.append(line[0]); lines.append(line)
        }
        return try lines.map { try orbitTube(points: $0, radius: 0.0008) }
    }

    static func footprint(_ footprint: VisibilityFootprint) throws -> MeshResource {
        // Lift the overlay slightly to prevent Earth-mesh z-fighting.
        let positions = footprint.surfacePoints.map { EarthCoordinates.scenePosition($0 * 1.0015) }
        let a = EarthCoordinates.equatorialRadius
        let b = a * (1 - EarthCoordinates.flattening)
        let normals = footprint.surfacePoints.map { p in
            let n = simd_normalize(p / SIMD3(a * a, a * a, b * b))
            return SIMD3<Float>(Float(n.y), Float(n.z), Float(n.x))
        }
        var descriptor = MeshDescriptor(name: "Above-horizon footprint")
        descriptor.positions = .init(positions)
        descriptor.normals = .init(normals)
        descriptor.primitives = .triangles(footprint.indices)
        return try MeshResource.generate(from: [descriptor])
    }

    static func orbitTube(points: [SIMD3<Float>], radius: Float = 0.0025, sides: Int = 6) throws -> MeshResource {
        try orbitTubes(lines: [points], radius: radius, sides: sides)
    }

    /// Combine overview rings into one mesh rather than hundreds of draw calls.
    static func orbitTubes(lines: [[SIMD3<Float>]], radius: Float = 0.0025, sides: Int = 3) throws -> MeshResource {
        try makeOrbitMesh(orbitData(lines: lines, radius: radius, sides: sides))
    }

    struct OrbitData: Sendable {
        let positions: [SIMD3<Float>]
        let normals: [SIMD3<Float>]
        let indices: [UInt32]
    }

    nonisolated static func orbitData(lines: [[SIMD3<Float>]], radius: Float = 0.0025, sides: Int = 3) -> OrbitData {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for points in lines {
        precondition(points.count >= 5 && points.first == points.last)
        let base = UInt32(positions.count)
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
                positions.append(center + normal * radius)
                normals.append(normal)
                if index < points.count - 1 {
                    let a = base + UInt32(index * sides + side)
                    let b = base + UInt32(index * sides + (side + 1) % sides)
                    let c = a + UInt32(sides)
                    let d = b + UInt32(sides)
                    indices += [a, b, c, b, d, c]
                }
            }
        }
        }
        return OrbitData(positions: positions, normals: normals, indices: indices)
    }

    static func makeOrbitMesh(_ data: OrbitData) throws -> MeshResource {
        var descriptor = MeshDescriptor(name: "Current satellite orbital ellipse")
        descriptor.positions = .init(data.positions)
        descriptor.normals = .init(data.normals)
        descriptor.primitives = .triangles(data.indices)
        return try MeshResource.generate(from: [descriptor])
    }

    struct MarkerBox {
        let size: SIMD3<Float>
        let center: SIMD3<Float>
        let palette: Int
    }

    static func marker(boxes: [MarkerBox]) throws -> MeshResource {
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        for box in boxes {
            for axis in 0..<3 {
                for sign: Float in [-1, 1] {
                    let first = (axis + 1) % 3, second = (axis + 2) % 3
                    let base = UInt32(positions.count)
                    var normal = SIMD3<Float>(repeating: 0); normal[axis] = sign
                    for (a, b): (Float, Float) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] {
                        var point = box.center
                        point[axis] += sign * box.size[axis] / 2
                        point[first] += a * box.size[first] / 2
                        point[second] += b * box.size[second] / 2
                        positions.append(point); normals.append(normal)
                        uvs.append([Float(box.palette) / 4 + 0.125, 0.5])
                    }
                    if sign > 0 { indices += [base, base + 1, base + 2, base, base + 2, base + 3] }
                    else { indices += [base, base + 2, base + 1, base, base + 3, base + 2] }
                }
            }
        }
        var descriptor = MeshDescriptor(name: "Satellite marker")
        descriptor.positions = .init(positions); descriptor.normals = .init(normals)
        descriptor.textureCoordinates = .init(uvs); descriptor.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descriptor])
    }
}
