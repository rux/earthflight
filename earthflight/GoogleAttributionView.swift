import SwiftUI

struct GoogleAttributionView: View {
    let attribution: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Image("GoogleMapsAttribution")
                .resizable()
                .scaledToFit()
                .frame(height: 18)
                .accessibilityLabel("Google Maps")

            if !attribution.isEmpty {
                Text(attribution)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 5)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
        .padding(10)
    }
}
