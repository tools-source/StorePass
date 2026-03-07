import SwiftUI
import UIKit

struct ManageStoresView: View {
    @EnvironmentObject private var container: AppContainer
    @StateObject private var viewModel: StoreManagementViewModel

    @State private var name = ""
    @State private var address = ""
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var radiusText = "150"

    @State private var deletingStore: Store?

    init(repository: StoreRepositoryProtocol) {
        _viewModel = StateObject(wrappedValue: StoreManagementViewModel(repository: repository))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: DS.Spacing.m) {
                        ScreenHeader(
                            title: "Stores",
                            subtitle: "Create and manage geofenced work locations",
                            icon: "building.2"
                        )

                        summaryCard
                        createStoreCard

                        if viewModel.stores.isEmpty {
                            EmptyStateView(
                                icon: "building.2.crop.circle",
                                title: "No stores yet",
                                message: "Create your first store to onboard employees with join codes."
                            )
                        } else {
                            VStack(spacing: DS.Spacing.s) {
                                ForEach(viewModel.stores) { store in
                                    NavigationLink {
                                        StoreDetailView(
                                            store: store,
                                            viewModel: viewModel,
                                            managerId: container.authRepository.currentUserId,
                                            onDelete: { deletingStore = store }
                                        )
                                    } label: {
                                        storeRow(store)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if let error = viewModel.storeError {
                            BannerView(text: error, isError: true)
                        }
                    }
                    .frame(maxWidth: DS.Metrics.maxReadableWidth)
                    .padding(.horizontal, DS.Spacing.m)
                    .padding(.vertical, DS.Spacing.m)
                }
            }
            .navigationTitle("Stores")
            .task { await viewModel.load(managerId: container.authRepository.currentUserId) }
            .refreshable { await viewModel.load(managerId: container.authRepository.currentUserId) }
            .onReceive(Timer.publish(every: 12, on: .main, in: .common).autoconnect()) { _ in
                Task { await viewModel.load(managerId: container.authRepository.currentUserId) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .cloudKitDidReceiveRemoteChange)) { _ in
                Task { await viewModel.load(managerId: container.authRepository.currentUserId) }
            }
            .alert(
                "Delete Store",
                isPresented: Binding(get: { deletingStore != nil }, set: { if !$0 { deletingStore = nil } })
            ) {
                Button("Delete", role: .destructive) {
                    guard let store = deletingStore else { return }
                    Task {
                        await viewModel.deleteStore(id: store.id)
                        await viewModel.load(managerId: container.authRepository.currentUserId)
                    }
                    deletingStore = nil
                }
                Button("Cancel", role: .cancel) { deletingStore = nil }
            } message: {
                Text("Employees will lose access to this store immediately.")
            }
            .overlay(alignment: .bottom) {
                if let toast = viewModel.toastMessage {
                    Text(toast)
                        .font(DS.Typography.caption)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(DS.Colors.card.opacity(0.95), in: Capsule())
                        .padding(.bottom, 22)
                }
            }
        }
    }

    private var summaryCard: some View {
        CardView {
            HStack(spacing: DS.Spacing.s) {
                MetricChip(label: "Total Stores", value: "\(viewModel.stores.count)", icon: "building.2")
                MetricChip(label: "Default Radius", value: "\(radiusText)m", icon: "scope")
            }
        }
    }

    private var createStoreCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(
                    title: "Create Store",
                    subtitle: "Set location and radius used for attendance validation.",
                    icon: "plus.circle"
                )

                Group {
                    entryField(title: "Store name", text: $name, keyboard: .default)
                    entryField(title: "Address", text: $address, keyboard: .default)

                    HStack(spacing: DS.Spacing.s) {
                        entryField(title: "Latitude", text: $latitudeText, keyboard: .numbersAndPunctuation)
                        entryField(title: "Longitude", text: $longitudeText, keyboard: .numbersAndPunctuation)
                    }

                    entryField(title: "Radius (meters)", text: $radiusText, keyboard: .numberPad)
                }

                Button(viewModel.isCreatingStore ? "Creating..." : "Create Store") {
                    Task {
                        await createStore()
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(viewModel.isCreatingStore)
            }
        }
    }

    private func storeRow(_ store: Store) -> some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        Text(store.name)
                            .font(DS.Typography.headline)
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text(store.address)
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    StatBadge(style: .neutral, text: "\(store.radiusMeters)m")
                }

                Divider()

                KeyValueRow(title: "Join code", value: viewModel.resolvedJoinCode(for: store))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func entryField(title: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(DS.Typography.micro)
                .foregroundStyle(DS.Colors.textSecondary)

            TextField(title, text: text)
                .keyboardType(keyboard)
                .padding(.horizontal, DS.Spacing.s)
                .frame(height: DS.Metrics.rowHeight)
                .background(DS.Colors.elevated.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func createStore() async {
        guard let latitude = Double(latitudeText),
              let longitude = Double(longitudeText),
              let radius = Int(radiusText) else {
            viewModel.presentStoreError("Latitude, longitude, and radius must be valid numbers.")
            return
        }

        let created = await viewModel.createStore(
            name: name,
            address: address,
            latitude: latitude,
            longitude: longitude,
            radiusMeters: radius
        )

        await viewModel.load(managerId: container.authRepository.currentUserId)

        if created {
            name = ""
            address = ""
            latitudeText = ""
            longitudeText = ""
            radiusText = "150"
        }
    }
}

private struct StoreDetailView: View {
    let store: Store
    @ObservedObject var viewModel: StoreManagementViewModel
    let managerId: String?
    let onDelete: () -> Void

    @State private var isRotating = false

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.m) {
                CardView {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        ScreenHeader(title: store.name, subtitle: store.address, icon: "mappin.circle")
                        KeyValueRow(title: "Latitude", value: String(format: "%.6f", store.latitude))
                        KeyValueRow(title: "Longitude", value: String(format: "%.6f", store.longitude))
                        KeyValueRow(title: "Radius", value: "\(store.radiusMeters)m")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                CardView {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        ScreenHeader(title: "Join Code", subtitle: "Use this code to join the store", icon: "number")

                        Text(viewModel.resolvedJoinCode(for: store))
                            .font(.system(.title2, design: .monospaced).weight(.bold))
                            .foregroundStyle(DS.Colors.textPrimary)

                        HStack(spacing: DS.Spacing.s) {
                            Button("Copy") {
                                UIPasteboard.general.string = viewModel.resolvedJoinCode(for: store)
                                viewModel.showToast("Join code copied")
                            }
                            .buttonStyle(SecondaryButtonStyle())

                            Button(isRotating ? "Rotating..." : "Rotate") {
                                Task {
                                    isRotating = true
                                    await viewModel.rotateStoreCode(storeId: store.id, managerId: managerId)
                                    isRotating = false
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(isRotating)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                CardView {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        ScreenHeader(title: "Danger Zone", subtitle: "Permanent store removal", icon: "trash")

                        Button("Delete Store", role: .destructive) {
                            onDelete()
                        }
                        .buttonStyle(DestructiveButtonStyle())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: DS.Metrics.maxReadableWidth)
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.m)
        }
        .background(AppBackground())
        .navigationTitle("Store Detail")
    }
}
