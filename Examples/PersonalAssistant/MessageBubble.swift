import SwiftUI

struct MessageBubble: View {
    let msg: ChatMessage

    private var info: SpecialistInfo? {
        allSpecialists.first(where: { $0.id == msg.specialist })
    }

    var body: some View {
        if msg.role == "user" {
            userBubble
        } else {
            assistantBubble
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 80)
            Text(msg.content)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: 420, alignment: .trailing)
        }
    }

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill((info?.color ?? Color.gray).opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: info?.icon ?? "sparkles")
                    .font(.system(size: 14))
                    .foregroundStyle(info?.color ?? Color.gray)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let info {
                    Text(info.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(info.color)
                }
                Text(msg.content)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(maxWidth: 460, alignment: .leading)
            }

            Spacer(minLength: 60)
        }
    }
}
