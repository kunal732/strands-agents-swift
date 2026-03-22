import SwiftUI

struct AgentDetailView: View {
    let agent: AgentResult

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(agent.color.opacity(0.15)).frame(width: 44, height: 44)
                    Image(systemName: agent.icon)
                        .font(.system(size: 18))
                        .foregroundStyle(agent.color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.label).font(.title2.bold())
                    Text("Analysis complete").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                Text(agent.output)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
    }
}
