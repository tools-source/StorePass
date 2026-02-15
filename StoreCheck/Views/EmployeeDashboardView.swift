import SwiftUI
import UIKit

struct EmployeeDashboardView: View {
    @StateObject private var vm = EmployeeDashboardViewModel(
        authService: AppContainer.shared.authService as! AuthService,
        storeRepository: AppContainer.shared.storeRepository,
        checkInRepository: AppContainer.shared.checkInRepository,
        checkInService: AppContainer.shared.checkInService,
        locationService: AppContainer.shared.locationService
    )

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.m) {
                    Picker("Assigned Store", selection: Binding(get: {
                        vm.selectedStore?.id ?? ""
                    }, set: { id in
                        vm.selectedStore = vm.stores.first { $0.id == id }
                        vm.refreshLocationStatus()
                    })) {
                        ForEach(vm.stores, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                    .cardStyle()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Today: \(vm.todayStatus)").font(.headline)
                        Text(locationDescription(vm.locationStatus))
                            .foregroundStyle(locationColor(vm.locationStatus))
                        Button("Refresh Location") { vm.requestLocation() }
                            .buttonStyle(.bordered)
                    }
                    .cardStyle()

                    Button("Check In") {
                        Task {
                            let success = await vm.checkIn()
                            if success {
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCheckIn(vm.locationStatus))
                }
                .padding()
            }
            .navigationTitle("Employee")
            .task { await vm.load() }
        }
    }

    private func canCheckIn(_ state: LocationCheckState) -> Bool {
        if case .inRange = state { return true }
        return false
    }

    private func locationDescription(_ state: LocationCheckState) -> String {
        switch state {
        case .inRange(let d): return "In range ✅ • \(Int(d))m away"
        case .outOfRange(let d): return "Out of range ❌ • \(Int(d))m away"
        case .permissionDenied: return "Location denied. Enable it in Settings."
        case .locationUnavailable: return "Location unavailable."
        case .preciseLocationRequired: return "Precise Location required."
        case .lowAccuracy(let a): return "Poor accuracy (\(Int(a))m). Move and retry."
        case .unknown: return "Location unknown"
        }
    }

    private func locationColor(_ state: LocationCheckState) -> Color {
        if case .inRange = state { return .green }
        return .orange
    }
}
