import SwiftUI
import CoreLocation
import AVFoundation
import UIKit

// Helper for Aspect Ratios
enum AspectRatio: String, CaseIterable {
    case fourThree = "4:3"
    case sixteenNine = "16:9"
    case square = "1:1"
    
    var value: CGFloat {
        switch self {
        case .fourThree: return 4.0 / 3.0
        case .sixteenNine: return 16.0 / 9.0
        case .square: return 1.0
        }
    }
}

struct ContentView: View {
    @StateObject var cameraManager = CameraManager()
    @StateObject var locationManager = LocationManager()
    let smoother = CompassSmoother()
    
    @State var currentAdvice: DirectorAdvice?
    @State private var showMap = false
    
    // UI States
    @State private var currentAspectRatio: AspectRatio = .fourThree
    @State private var currentZoom: CGFloat = 1.0
    @State private var selectedPresetIndex: Int = 0
    @State private var showFlashAnimation = false
    @State private var isCapturing = false
    @State private var ellipsisStep = 0
    
    // Zoom Gesture State
    @State private var baseZoomFactor: CGFloat = 1.0
    
    // Target: The Campanile (Change to test!)
    @State var targetLandmark = Landmark(
        name: "The Campanile",
        coordinate: CLLocationCoordinate2D(latitude: 37.8720, longitude: -122.2578)
    )
    
    // Helper for Map binding
    var targetLandmarkBinding: Binding<MapLandmark> {
        Binding(
            get: { MapLandmark(name: targetLandmark.name, coordinate: targetLandmark.coordinate) },
            set: { new in targetLandmark = Landmark(name: new.name, coordinate: new.coordinate) }
        )
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                // --- LAYER 1: CAMERA (With Aspect Ratio & Pinch Zoom) ---
                GeometryReader { geo in
                    let ratio = currentAspectRatio.value
                    let height = geo.size.width * ratio
                    
                    CameraPreview(cameraManager: cameraManager)
                        .frame(width: geo.size.width, height: height)
                        .clipped()
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        // PINCH TO ZOOM GESTURE
                        .gesture(
                            MagnificationGesture()
                                .onChanged { val in
                                    let newZoom = baseZoomFactor * val
                                    cameraManager.zoom(factor: newZoom)
                                    // Update UI slider immediately
                                    currentZoom = max(cameraManager.minZoomFactor, min(newZoom, cameraManager.maxZoomFactor))
                                }
                                .onEnded { _ in
                                    baseZoomFactor = currentZoom
                                }
                        )
                }
                .ignoresSafeArea(.all, edges: .top)
                
                // --- LAYER 2: OVERLAYS ---
                if let advice = currentAdvice {
                    FloatingTargetView(
                        angleDiff: advice.turnAngle,
                        isLocked: abs(advice.turnAngle) < 3
                    )
                }
                
                // --- LAYER 3: CONTROLS ---
                VStack {
                    // TOP BAR
                    HStack {
                        // GPS Status
                        Circle().fill(locationManager.permissionGranted ? Color.green : Color.red).frame(width: 8, height: 8)
                        Text(locationManager.permissionGranted ? "GPS ONLINE" : "OFFLINE")
                            .font(.caption2).bold().foregroundColor(.white)
                            .padding(4).background(.ultraThinMaterial).cornerRadius(4)
                        
                        Spacer()
                        
                        // Aspect Ratio Toggle
                        Button {
                            toggleAspectRatio()
                        } label: {
                            Text(currentAspectRatio.rawValue)
                                .font(.footnote.bold()).foregroundColor(.white)
                                .padding(8).background(.ultraThinMaterial).clipShape(Capsule())
                        }
                        
                        // Flip Camera
                        Button {
                            cameraManager.switchCamera()
                            currentZoom = 1.0 // Reset zoom
                            baseZoomFactor = 1.0
                        } label: {
                            Image(systemName: "camera.rotate.fill")
                                .font(.headline).foregroundColor(.white)
                                .padding(8).background(.ultraThinMaterial).clipShape(Circle())
                        }
                    }
                    .padding(.top, 50).padding(.horizontal)
                    
                    Spacer()
                    
                    // BOTTOM BAR
                    VStack(spacing: 20) {
                        
                        // Scope
                        if let advice = currentAdvice {
                            ScopeView(advice: advice)
                        } else {
                            Text("Calibrating...").font(.headline).foregroundColor(.white).padding().background(.ultraThinMaterial).cornerRadius(15)
                        }
                        
                        Spacer(minLength: 8)
                        
                        // Zoom Controls
                        VStack(spacing: 8) {
                            HStack(spacing: 24) {
                                let epsilon: CGFloat = 0.001
                                let presets = cameraManager.suggestedZoomPresets
                                
                                ForEach(presets, id: \.self) { preset in
                                    ZoomButton(label: labelForPreset(preset), factor: preset, currentZoom: $currentZoom, action: { value in
                                        selectionHaptic()
                                        cameraManager.zoom(factor: value)
                                        baseZoomFactor = value // Update base for pinch
                                    })
                                }
                            }
                            .opacity(0.95)
                            .onChange(of: currentZoom) { _, newValue in
                                let presets = cameraManager.suggestedZoomPresets
                                if let idx = presets.enumerated().min(by: { abs($0.element - newValue) < abs($1.element - newValue) })?.offset {
                                    selectedPresetIndex = idx
                                }
                            }
                            // Reset base zoom if presets change (e.g. lens switch)
                            .onChange(of: cameraManager.suggestedZoomPresets) { _, newPresets in
                                guard !newPresets.isEmpty else { return }
                                if let nearest = newPresets.min(by: { abs($0 - currentZoom) < abs($1 - currentZoom) }) {
                                    currentZoom = nearest
                                    baseZoomFactor = nearest
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 16)
                        .background(Color.clear)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 32)
                        
                        // Footer Actions
                        HStack {
                            // Map
                            Button { showMap = true } label: {
                                Image(systemName: "map.fill")
                                    .font(.title2).foregroundColor(.white).padding(15)
                                    .background(.ultraThinMaterial).clipShape(Circle())
                            }
                            
                            Spacer()
                            
                            // SHUTTER BUTTON (Large)
                            Button {
                                takePhoto()
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(.ultraThinMaterial)
                                        .frame(width: 78, height: 78)
                                        .overlay(
                                            Circle().stroke(Color.white.opacity(0.6), lineWidth: 1)
                                        )
                                        .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 3)
                                        .overlay(
                                            Circle().stroke(LinearGradient(
                                                colors: [Color.white.opacity(0.45), Color.white.opacity(0.1)],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ), lineWidth: 2).blur(radius: 0.5)
                                        )
                                    Circle().fill(Color.white).frame(width: 64, height: 64)
                                }
                            }
                            
                            Spacer()
                            
                            // Placeholder
                            Color.clear.frame(width: 60, height: 60)
                        }
                        .padding(.horizontal, 30).padding(.bottom, 30)
                    }
                }
                
                // --- LAYER 4: ANIMATIONS ---
                if locationManager.isInterferenceHigh {
                    CalibrationView().transition(.opacity).zIndex(100)
                }
                if showFlashAnimation {
                    Color.white.ignoresSafeArea().transition(.opacity).zIndex(200)
                }
                if isCapturing {
                    CapturingOverlay(ellipsisStep: ellipsisStep)
                        .transition(.opacity)
                        .zIndex(150)
                        .onAppear {
                            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { timer in
                                if !isCapturing {
                                    timer.invalidate()
                                } else {
                                    ellipsisStep = (ellipsisStep + 1) % 4
                                }
                            }
                        }
                }
            }
            .navigationDestination(isPresented: $showMap) {
                MapScreen(locationManager: locationManager, landmark: targetLandmarkBinding)
            }
            .onReceive(locationManager.$heading) { _ in updateNavigationLogic() }
            .onReceive(locationManager.$location) { _ in updateNavigationLogic() }
            .onReceive(cameraManager.captureDidFinish) { _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCapturing = false
                }
            }
            .onAppear {
                currentZoom = 1.0
            }
        }
    }
    
    // MARK: - Haptics
    private func selectionHaptic() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }
    
    // MARK: - Logic
    func toggleAspectRatio() {
        let allCases = AspectRatio.allCases
        if let currentIndex = allCases.firstIndex(of: currentAspectRatio) {
            let nextIndex = (currentIndex + 1) % allCases.count
            currentAspectRatio = allCases[nextIndex]
        }
    }
    
    func takePhoto() {
        isCapturing = true
        withAnimation(.easeOut(duration: 0.1)) { showFlashAnimation = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeIn(duration: 0.2)) { showFlashAnimation = false }
        }
        cameraManager.capturePhoto(location: locationManager.location)
    }
    
    func updateNavigationLogic() {
        guard let userLoc = locationManager.location,
              let rawHeading = locationManager.heading?.trueHeading else { return }
        
        let smoothHeading = smoother.smooth(rawHeading)
        var newAdvice = PhotoDirector.guideToLandmark(
            userHeading: smoothHeading,
            userLocation: userLoc.coordinate,
            target: targetLandmark
        )
        
        if abs(newAdvice.turnAngle) < 3 {
            newAdvice = DirectorAdvice(message: newAdvice.message, icon: newAdvice.icon, isUrgent: newAdvice.isUrgent, lightingScore: newAdvice.lightingScore, turnAngle: 0)
        }
        withAnimation(.linear(duration: 0.1)) { self.currentAdvice = newAdvice }
    }
    
    func labelForPreset(_ preset: CGFloat) -> String {
        guard let best = cameraManager.suggestedZoomPresets.min(by: { abs($0 - preset) < abs($1 - preset) }) else {
            let whole = abs(preset.rounded() - preset) < 0.001
            return whole ? String(format: "%.0f×", preset) : String(format: "%.1f×", preset)
        }
        
        if abs(best - 1.0) < 0.001 { return "1×" }
        else if abs(best - 0.5) < 0.001 { return "0.5×" }
        else if abs(best - 2.0) < 0.001 { return "2×" }
        else if abs(best - 3.0) < 0.001 { return "3×" }
        else {
            return String(format: "%.1f×", preset)
        }
    }
}

// Helper Button
struct ZoomButton: View {
    let label: String
    let factor: CGFloat
    @Binding var currentZoom: CGFloat
    let action: (CGFloat) -> Void
    
    var body: some View {
        Button {
            currentZoom = factor
            action(factor)
        } label: {
            Text(label)
                .font(.footnote.bold())
                .foregroundColor(currentZoom == factor ? .yellow : .white)
                .padding(8)
                .background(currentZoom == factor ? Color.white.opacity(0.2) : Color.clear)
                .clipShape(Circle())
        }
    }
}

struct CapturingOverlay: View {
    let ellipsisStep: Int
    var body: some View {
        let dots = String(repeating: ".", count: ellipsisStep)
        return Text("Capturing" + dots)
            .font(.footnote.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1)
            )
            .padding(.bottom, 110)
    }
}

#Preview {
    ContentView()
}
