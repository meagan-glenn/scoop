import SwiftUI
import CloudKit
import UIKit

/// Household sync: status plus the invite. One sheet, no settings maze.
struct SyncSheet: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var sync = CloudSync.shared
    @Environment(\.dismiss) private var dismiss
    @State private var share: CKShare?
    @State private var shareError: String?
    @State private var isPreparingShare = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: statusSymbol)
                        .font(.title2)
                        .foregroundColor(statusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sync.status.label)
                            .font(.headline)
                        if let lastSync = sync.lastSync {
                            Text("Last synced \(relativeDay(lastSync))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .card()

                if case .live(let isOwner) = sync.status {
                    if isOwner {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Share with your household")
                                .font(.subheadline.weight(.semibold))
                            Text("Everyone you invite sees the same animals and logs the same record, from their own phone.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if let url = share?.url {
                                ShareLink(item: url, subject: Text("Join our Scoop household"),
                                          message: Text("Tap this on your phone to see the same animals and logs I do.")) {
                                    Label("Send invite link", systemImage: "link")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                }
                                .buttonStyle(.borderedProminent)
                                Button {
                                    presentSharingController()
                                } label: {
                                    Label("Manage who's in", systemImage: "person.2")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Button {
                                    prepareShare()
                                } label: {
                                    Group {
                                        if isPreparingShare {
                                            ProgressView()
                                        } else {
                                            Label("Invite someone", systemImage: "person.badge.plus")
                                        }
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isPreparingShare)
                            }
                        }
                        .card()
                    } else {
                        Text("You're logging into a shared household. Everything you add shows up on everyone's phone.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .card()
                    }
                } else if case .off = sync.status {
                    Text("Once iCloud is available, the household syncs on its own and you can invite someone to share it. Until then everything stays on this phone.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .card()
                }

                if let shareError {
                    Text(shareError)
                        .font(.caption)
                        .foregroundColor(Tier.concern.color)
                }

                Spacer()

                Text("Synced through iCloud. Photos and logs stay in your household's iCloud, not on our servers. There are no servers.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding()
            .navigationTitle("Household sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                // If a share already exists, surface the link right away.
                if case .live(true) = sync.status, share == nil {
                    share = try? await CloudSync.shared.existingShare()
                }
            }
        }
    }

    private var statusSymbol: String {
        switch sync.status {
        case .off: return "icloud.slash"
        case .starting: return "arrow.triangle.2.circlepath.icloud"
        case .live: return "checkmark.icloud.fill"
        }
    }

    private var statusColor: Color {
        switch sync.status {
        case .off: return .secondary
        case .starting: return .secondary
        case .live: return Tier.normal.color
        }
    }

    private func prepareShare() {
        shareError = nil
        isPreparingShare = true
        Task {
            defer { isPreparingShare = false }
            do {
                share = try await CloudSync.shared.fetchOrCreateShare()
            } catch {
                shareError = "Couldn't start sharing: \(error.localizedDescription)"
            }
        }
    }

    /// Apple's sharing UI, presented from UIKit. Wrapping it in a SwiftUI
    /// sheet is unreliable (blank or unresponsive), so find the top view
    /// controller and present directly.
    private func presentSharingController() {
        guard let share else { return }
        let controller = UICloudSharingController(share: share, container: sync.container)
        controller.availablePermissions = [.allowPublic, .allowPrivate, .allowReadWrite]
        controller.delegate = sharingDelegate
        sharingDelegate.onError = { message in shareError = message }
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(controller, animated: true)
    }
}

private let sharingDelegate = SharingDelegate()

final class SharingDelegate: NSObject, UICloudSharingControllerDelegate {
    var onError: ((String) -> Void)?
    func itemTitle(for csc: UICloudSharingController) -> String? { "Scoop household" }
    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        onError?("Sharing failed: \(error.localizedDescription)")
    }
    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {}
    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {}
}
