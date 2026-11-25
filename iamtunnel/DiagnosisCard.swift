import SwiftUI

// Shows one Diagnosis: what's wrong, why, and a button that fixes it.
struct DiagnosisCard: View {
    let diagnosis: Diagnosis
    var onFixed: () -> Void = {}
    @State private var fixFailed = false
    @State private var showTechnical = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(diagnosis.title, systemImage: "stethoscope")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text(diagnosis.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let technical = diagnosis.technical {
                DisclosureGroup(isExpanded: $showTechnical) {
                    VStack(alignment: .leading, spacing: 4) {
                        ScrollView {
                            Text(technical)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 70)
                        .padding(6)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(technical, forType: .string)
                            copied = true
                        }
                        .controlSize(.mini)
                    }
                    .padding(.top, 4)
                } label: {
                    Text("AWS error")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if let label = diagnosis.fixLabel {
                HStack {
                    Button(label) {
                        let ok = AWSDoctor.apply(diagnosis.fix)
                        fixFailed = !ok
                        if ok { onFixed() }
                    }
                    .controlSize(.small)
                    if fixFailed {
                        Text("Couldn't apply the fix. Edit the file by hand.")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
