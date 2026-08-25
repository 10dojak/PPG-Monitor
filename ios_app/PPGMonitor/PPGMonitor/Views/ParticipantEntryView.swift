//
//  ParticipantEntryView.swift
//  PPGMonitor
//

import SwiftUI

struct ParticipantEntryView: View {
    @ObservedObject var sessionController: SessionController
    @State private var participantIDInput: String = ""

    private var isValid: Bool {
        !participantIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("PPG Monitor")
                .font(.largeTitle.bold())

            Text("Enter a participant ID to begin a session.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            TextField("Participant ID", text: $participantIDInput)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .frame(maxWidth: 320)

            Button("Continue") {
                sessionController.beginSession(participantID: participantIDInput)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isValid)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
