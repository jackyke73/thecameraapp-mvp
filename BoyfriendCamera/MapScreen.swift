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
            
            // --- TOP RIGHT SATELLITE TOGGLE ---
            VStack {
                HStack {
                    Spacer()
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
                    .padding(.top, 10) // Adjust for notch if needed
                    .padding(.trailing, 10)
                }
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
}
