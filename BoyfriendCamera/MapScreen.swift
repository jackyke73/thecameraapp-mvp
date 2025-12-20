import SwiftUI
import MapKit
import CoreLocation

// 1. Data Model (Now equatable so we can detect changes)
struct MapLandmark: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var coordinate: CLLocationCoordinate2D
    
    static func == (lhs: MapLandmark, rhs: MapLandmark) -> Bool {
        lhs.id == rhs.id
    }
}

struct MapScreen: View {
    @ObservedObject var locationManager: LocationManager
    
    // 2. BINDING: This lets the Map update the "Target" in ContentView
    @Binding var landmark: MapLandmark

    // Map State
    @State private var position: MapCameraPosition = .automatic
    @State private var isSatellite = true
    
    // Search State
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false

    @State private var showSettings = false
    @State private var showPlaceholder1 = false
    @State private var showPlaceholder2 = false
    @State private var appInstallDate = Date() // TODO: replace with persisted install date if available

    var body: some View {
        ZStack {
            // --- THE MAP ---
            Map(position: $position) {
                UserAnnotation()
                
                // The Target Pin
                Annotation(landmark.name, coordinate: landmark.coordinate) {
                    ZStack {
                        Circle().fill(.red).frame(width: 20, height: 20).shadow(radius: 5)
                        Image(systemName: "camera.fill").font(.caption2).foregroundColor(.white)
                    }
                }
            }
            .mapStyle(isSatellite ? .hybrid(elevation: .realistic) : .standard(elevation: .realistic))
            .onAppear {
                // Auto-fit when we open the map
                fitBothLocations()
            }
            
            // --- TOP RIGHT SETTINGS AND SATELLITE TOGGLE ---
            VStack {
                HStack {
                    Spacer()
                    // Settings button
                    Button {
                        showSettings = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "gearshape.fill")
                            Text("Settings")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .shadow(radius: 3)
                    }

                    // Space between buttons
                    Spacer().frame(width: 8)

                    // Satellite toggle
                    Button {
                        withAnimation { isSatellite.toggle() }
                    } label: {
                        Image(systemName: isSatellite ? "globe.americas.fill" : "map.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding(10)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                            .shadow(radius: 3)
                    }
                    .padding(.trailing, 10)
                }
                .padding(.top, 10)
                Spacer()
            }
            
            // --- SEARCH RESULTS LIST (Appears when typing) ---
            if !searchResults.isEmpty && isSearching {
                VStack {
                    List(searchResults, id: \.self) { item in
                        Button {
                            selectNewTarget(item)
                        } label: {
                            HStack {
                                Image(systemName: "mappin.circle.fill").foregroundColor(.red)
                                VStack(alignment: .leading) {
                                    Text(item.name ?? "Unknown").font(.headline)
                                    Text(item.placemark.title ?? "").font(.caption).foregroundColor(.gray)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .background(.ultraThinMaterial)
                    .cornerRadius(15)
                    .frame(maxHeight: 300)
                    .padding()
                    .shadow(radius: 10)
                    
                    Spacer()
                }
                .padding(.top, 50) // Push down below search bar
            }
        }
        .navigationTitle(landmark.name)
        .navigationBarTitleDisplayMode(.inline)
        // --- NATIVE SEARCH BAR ---
        .searchable(text: $searchText, isPresented: $isSearching, prompt: "Search for new target...")
        .onChange(of: searchText) { _ in
            performSearch()
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(showPlaceholder1: $showPlaceholder1, showPlaceholder2: $showPlaceholder2, totalDaysUsed: totalDaysUsed)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showPlaceholder1) {
            PlaceholderDetailSheet(title: "Placeholder 1")
                .presentationDetents([.medium])
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showPlaceholder2) {
            PlaceholderDetailSheet(title: "Placeholder 2")
                .presentationDetents([.medium])
                .presentationBackground(.ultraThinMaterial)
        }
    }
    
    // MARK: - Logic Helpers
    
    func fitBothLocations() {
        guard let userLoc = locationManager.location else { return }
        
        let userCoord = userLoc.coordinate
        let targetCoord = landmark.coordinate
        
        // Calculate the bounding box
        let minLat = min(userCoord.latitude, targetCoord.latitude)
        let maxLat = max(userCoord.latitude, targetCoord.latitude)
        let minLon = min(userCoord.longitude, targetCoord.longitude)
        let maxLon = max(userCoord.longitude, targetCoord.longitude)
        
        // Add some padding (multiply span by 1.4)
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat)/2, longitude: (minLon + maxLon)/2)
        let span = MKCoordinateSpan(
            latitudeDelta: abs(maxLat - minLat) * 1.4,
            longitudeDelta: abs(maxLon - minLon) * 1.4
        )
        
        // Smoothly fly to this new region
        withAnimation {
            position = .region(MKCoordinateRegion(center: center, span: span))
        }
    }
    
    func performSearch() {
        guard !searchText.isEmpty else {
            searchResults = []
            return
        }
        
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        // Search near the current target
        request.region = MKCoordinateRegion(center: landmark.coordinate, latitudinalMeters: 50000, longitudinalMeters: 50000)
        
        let search = MKLocalSearch(request: request)
        search.start { response, error in
            if let items = response?.mapItems {
                self.searchResults = items
            }
        }
    }
    
    func selectNewTarget(_ item: MKMapItem) {
        // 1. Update the Target (This updates ContentView automatically!)
        landmark = MapLandmark(
            name: item.name ?? "New Target",
            coordinate: item.placemark.coordinate
        )
        
        // 2. Clear Search
        searchText = ""
        isSearching = false
        searchResults = []
        
        // 3. Re-fit the map
        fitBothLocations()
    }

    var totalDaysUsed: Int {
        let start = Calendar.current.startOfDay(for: appInstallDate)
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.dateComponents([.day], from: start, to: today).day ?? 0
    }
}
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var showPlaceholder1: Bool
    @Binding var showPlaceholder2: Bool
    let totalDaysUsed: Int
    @State private var selectedDate = Date()

    var body: some View {
        VStack(spacing: 16) {
            // Top bar inside sheet
            HStack {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down")
                        Text("Close")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top)

            // Two clickable placeholder blocks
            VStack(spacing: 12) {
                Button { showPlaceholder1 = true } label: {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Text("PLACEHOLDER 1")
                                .font(.headline.weight(.semibold))
                                .foregroundColor(.white)
                        )
                        .frame(height: 80)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                }
                Button { showPlaceholder2 = true } label: {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Text("PLACEHOLDER 2")
                                .font(.headline.weight(.semibold))
                                .foregroundColor(.white)
                        )
                        .frame(height: 80)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                }
            }
            .padding(.horizontal)

            // Calendar + total days used
            VStack(alignment: .leading, spacing: 8) {
                Text("Total days used: \(totalDaysUsed)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                DatePicker("Calendar", selection: $selectedDate, displayedComponents: [.date])
                    .datePickerStyle(.graphical)
                    .tint(.white)
            }
            .padding(.horizontal)

            Spacer()
        }
        .presentationBackground(.ultraThinMaterial)
    }
}

struct PlaceholderDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down")
                        Text("Back")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                }
                Spacer()
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundColor(.white)
                Spacer()
                Color.clear.frame(width: 60, height: 1)
            }
            .padding(.horizontal)
            .padding(.top)

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Text("Content for \(title)")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .padding()
            Spacer()
        }
        .presentationBackground(.ultraThinMaterial)
    }
}

