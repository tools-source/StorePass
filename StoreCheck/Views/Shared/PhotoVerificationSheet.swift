import SwiftUI
import UIKit

struct PhotoVerificationSheet: View {
    @Binding var isPresented: Bool
    let title: String
    let onPickedImage: (UIImage) -> Void

    var body: some View {
        NavigationStack {
            PhotoVerificationPicker(
                title: title,
                onPickedImage: { image in
                    isPresented = false
                    onPickedImage(image)
                },
                onCancel: {
                    isPresented = false
                }
            )
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        PhotoVerifyLogger.log("photo picker sheet canceled title=\(title)")
                        isPresented = false
                    }
                }
            }
        }
    }
}
