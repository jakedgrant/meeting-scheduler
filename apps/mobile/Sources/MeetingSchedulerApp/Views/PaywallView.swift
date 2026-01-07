import SwiftUI
import Shared
import RevenueCat

struct PaywallView: View {
    @Environment(\.dismiss) var dismiss

    @State var purchaseService = PurchaseService.shared
    @State var selectedPackage: Package?
    @State var isPurchasing = false
    @State var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    packagesSection
                    featuresSection
                    errorMessageView
                    purchaseButton
                    restoreButton
                    termsText
                }
                .padding(.bottom)
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .task {
                await purchaseService.loadOfferings()
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "star.fill")
                .font(.system(size: 50))
                .foregroundStyle(.yellow)

            Text("Upgrade to Pro")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Unlock unlimited polls and premium features")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top)
    }

    @ViewBuilder
    private var packagesSection: some View {
        if let offering = purchaseService.currentOffering {
            VStack(spacing: 12) {
                ForEach(offering.availablePackages, id: \.identifier) { package in
                    PackageCard(
                        package: package,
                        isSelected: selectedPackage?.identifier == package.identifier,
                        action: { selectedPackage = package }
                    )
                }
            }
            .padding(.horizontal)
        } else if purchaseService.isLoading {
            ProgressView("Loading plans...")
                .padding()
        } else {
            Text("No plans available")
                .foregroundStyle(.secondary)
        }
    }

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What you get:")
                .font(.headline)

            FeatureRow(icon: "infinity", text: "Unlimited active polls")
            FeatureRow(icon: "person.3.fill", text: "Up to 50 participants per poll")
            FeatureRow(icon: "calendar", text: "Calendar integrations")
            FeatureRow(icon: "bell.fill", text: "Priority notifications")
        }
        .padding()
        .background(Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    @ViewBuilder
    private var errorMessageView: some View {
        if let error = errorMessage {
            Text(error)
                .foregroundStyle(.red)
                .font(.caption)
                .padding(.horizontal)
        }
    }

    private var purchaseButton: some View {
        Button(action: purchase) {
            HStack {
                if isPurchasing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                }
                Text(isPurchasing ? "Processing..." : "Subscribe Now")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(selectedPackage != nil ? .blue : .gray)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(selectedPackage == nil || isPurchasing)
        .padding(.horizontal)
    }

    private var restoreButton: some View {
        Button("Restore Purchases") {
            restorePurchases()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var termsText: some View {
        Text("Cancel anytime. By subscribing, you agree to our Terms of Service.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
    }

    // MARK: - Actions

    private func purchase() {
        guard let package = selectedPackage else { return }

        isPurchasing = true
        errorMessage = nil

        Task {
            do {
                _ = try await purchaseService.purchase(package: package)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isPurchasing = false
        }
    }

    private func restorePurchases() {
        isPurchasing = true
        errorMessage = nil

        Task {
            do {
                _ = try await purchaseService.restorePurchases()
                if purchaseService.hasProAccess {
                    dismiss()
                } else {
                    errorMessage = "No purchases to restore"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isPurchasing = false
        }
    }
}

// MARK: - PackageCard

struct PackageCard: View {
    let package: Package
    let isSelected: Bool
    let action: () -> Void

    private var packageTitle: String {
        let id = package.identifier.lowercased()
        if id.contains("team") { return "Team" }
        if id.contains("pro") { return "Pro" }
        return package.identifier
    }

    private var packagePeriod: String {
        switch package.packageType {
        case .annual: return "Yearly"
        case .monthly: return "Monthly"
        default: return ""
        }
    }

    private var isAnnual: Bool {
        package.packageType == .annual
    }

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(packageTitle)
                        .font(.headline)
                    Text(packagePeriod)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(package.localizedPriceString)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.blue)

                    if isAnnual {
                        Text("Save 17%")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding()
            .background(isSelected ? Color.blue.opacity(0.1) : Color.gray.opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FeatureRow

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 24)

            Text(text)
                .font(.subheadline)
        }
    }
}

#Preview {
    PaywallView()
}
