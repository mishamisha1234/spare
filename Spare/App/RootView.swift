import SwiftUI
import SpareCore

/// Phase 1 placeholder. Phase 2 replaces this with onboarding and the real Home.
/// The one job of Home: ask how long you have.
struct RootView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("How long do you have?")
                .font(.largeTitle.weight(.semibold))
                .padding(.bottom, 8)

            ForEach(TimeWindow.allCases) { window in
                HStack(alignment: .firstTextBaseline) {
                    Text(window.label)
                        .font(.title2.weight(.medium))
                    Spacer()
                    Text(window.format.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
            }

            Spacer()
        }
        .padding(24)
    }
}

#Preview {
    RootView()
}
