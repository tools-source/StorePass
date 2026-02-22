import SwiftUI

struct ManagerCheckInsView: View {
    @StateObject private var viewModel: ManagerCheckInsViewModel

    init(
        storeRepository: StoreRepositoryProtocol,
        checkInRepository: CheckInRepositoryProtocol,
        authRepository: AuthRepositoryProtocol
    ) {
        _viewModel = StateObject(wrappedValue: ManagerCheckInsViewModel(
            storeRepository: storeRepository,
            checkInRepository: checkInRepository,
            authRepository: authRepository
        ))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Store") {
                    if viewModel.stores.isEmpty {
                        Text("No stores available.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Store", selection: $viewModel.selectedStoreId) {
                            ForEach(viewModel.stores) { store in
                                Text(store.name).tag(Optional(store.id))
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .listRowBackground(DS.Colors.card)

                Section("Recent Check-ins") {
                    if viewModel.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    } else if viewModel.checkIns.isEmpty {
                        Text("No check-ins yet for this store.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.checkIns) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.employeeName)
                                    .font(.headline)
                                Text(item.storeName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(item.checkInTime.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                Text("\(item.status.rawValue.capitalized) • \(Int(item.distanceMeters))m • ±\(Int(item.accuracyMeters))m")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listRowBackground(DS.Colors.card)
            }
            .scrollContentBackground(.hidden)
            .background(DS.Colors.background)
            .navigationTitle("Check-ins")
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
            .onChange(of: viewModel.selectedStoreId) { _, _ in
                Task { await viewModel.load() }
            }
        }
    }
}
