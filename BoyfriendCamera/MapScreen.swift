import SwiftUI
import MapKit
import CoreLocation


struct MapLandmark: Identifiable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
}

struct MapScreen: View {
    @ObservedObject var locationManager: LocationManager
    let landmark: MapLandmark

    // “肉眼可清楚看到地标”的近距离阈值（你可以调）
    private let nearThresholdMeters: CLLocationDistance = 250

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )

    private var userCoordinate: CLLocationCoordinate2D? {
        locationManager.location?.coordinate
    }

    private var distanceToLandmark: CLLocationDistance? {
        guard let user = locationManager.location else { return nil }
        let lm = CLLocation(latitude: landmark.coordinate.latitude, longitude: landmark.coordinate.longitude)
        return user.distance(from: lm)
    }

    private var isNear: Bool {
        (distanceToLandmark ?? .greatestFiniteMagnitude) <= nearThresholdMeters
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部：当前定位信息（低调显示）
            VStack(alignment: .leading, spacing: 6) {
                Text("Current Location").font(.headline)

                if let c = userCoordinate {
                    Text(String(format: "Lat: %.5f, Lon: %.5f", c.latitude, c.longitude))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Locating...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let d = distanceToLandmark {
                    Text("Distance to \(landmark.name): \(Int(d)) m")
                        .font(.subheadline)
                        .foregroundStyle(isNear ? .primary : .secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)

            // 地图：用户位置 + 灰色地标；靠近点亮区域
            Map(
                coordinateRegion: $region,
                interactionModes: .all,
                showsUserLocation: true,
                annotationItems: [landmark]
            ) { item in
                MapAnnotation(coordinate: item.coordinate) {
                    ZStack {
                        // 点亮圈（靠近时出现）
                        if isNear {
                            Circle()
                                .fill(Color.yellow.opacity(0.22))
                                .frame(width: 90, height: 90)
                                .blur(radius: 2)

                            Circle()
                                .stroke(Color.yellow.opacity(0.75), lineWidth: 2)
                                .frame(width: 90, height: 90)
                        }

                        // 地标：灰色
                        Circle()
                            .fill(Color.gray.opacity(0.9))
                            .frame(width: 14, height: 14)

                        Circle()
                            .stroke(Color.white.opacity(0.9), lineWidth: 2)
                            .frame(width: 18, height: 18)
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 进入地图页时，保证开始更新（如果已授权就会动起来）
            locationManager.startUpdates()

            // 先给一个合理视野
            if let user = userCoordinate {
                region = fitRegion(user: user, landmark: landmark.coordinate)
            } else {
                region = MKCoordinateRegion(
                    center: landmark.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                )
            }
        }
        .onChange(of: userCoordinate?.latitude) { _ in
            guard let user = userCoordinate else { return }
            region = fitRegion(user: user, landmark: landmark.coordinate)
        }
        .onChange(of: userCoordinate?.longitude) { _ in
            guard let user = userCoordinate else { return }
            region = fitRegion(user: user, landmark: landmark.coordinate)
        }
    }

    private func fitRegion(user: CLLocationCoordinate2D, landmark: CLLocationCoordinate2D) -> MKCoordinateRegion {
        let minLat = min(user.latitude, landmark.latitude)
        let maxLat = max(user.latitude, landmark.latitude)
        let minLon = min(user.longitude, landmark.longitude)
        let maxLon = max(user.longitude, landmark.longitude)

        // padding，保证“肉眼能同时看到”
        let latDelta = max(0.005, (maxLat - minLat) * 1.8)
        let lonDelta = max(0.005, (maxLon - minLon) * 1.8)

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
    }
}
