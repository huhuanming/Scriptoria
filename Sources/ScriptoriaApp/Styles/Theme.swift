import SwiftUI

/// Scriptoria design system
enum Theme {
    // MARK: - Accent Colors
    static let accent = Color.blue
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.35, green: 0.5, blue: 1.0), Color(red: 0.55, green: 0.35, blue: 1.0)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let successColor = Color.green
    static let failureColor = Color(red: 1.0, green: 0.35, blue: 0.35)
    static let warningColor = Color.orange
    static let runningColor = Color(red: 0.35, green: 0.6, blue: 1.0)

    // MARK: - Tag Colors (cycle through for variety)
    static let tagColors: [Color] = [
        Color(red: 0.35, green: 0.55, blue: 1.0),    // blue
        Color(red: 0.6, green: 0.35, blue: 0.9),     // purple
        Color(red: 0.2, green: 0.75, blue: 0.6),     // teal
        Color(red: 0.9, green: 0.55, blue: 0.2),     // amber
        Color(red: 0.85, green: 0.35, blue: 0.5),    // pink
        Color(red: 0.3, green: 0.7, blue: 0.3),      // green
    ]

    static func tagColor(for tag: String) -> Color {
        let hash = abs(tag.hashValue)
        return tagColors[hash % tagColors.count]
    }

    // MARK: - Animations
    static let springSnappy = Animation.spring(response: 0.3, dampingFraction: 0.7)
    static let springSmooth = Animation.spring(response: 0.45, dampingFraction: 0.8)
    static let fadeQuick = Animation.easeInOut(duration: 0.15)
    static let fadeMedium = Animation.easeInOut(duration: 0.25)
}

// MARK: - Reusable Style Modifiers

struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 10
    var padding: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }
}

struct TerminalOutputModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        content
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(colorScheme == .dark
                        ? Color.black.opacity(0.35)
                        : Color.black.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.5)
            )
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 10, padding: CGFloat = 12) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, padding: padding))
    }

    func terminalOutput() -> some View {
        modifier(TerminalOutputModifier())
    }
}

// MARK: - Animated Status Dot

struct StatusDot: View {
    let color: Color
    var isAnimating: Bool = false
    var size: CGFloat = 8

    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.5), radius: isPulsing ? 4 : 0)
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .animation(
                isAnimating
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .onAppear { isPulsing = isAnimating }
            .onChange(of: isAnimating) { _, new in isPulsing = new }
    }
}

// MARK: - Tag Capsule

struct TagCapsule: View {
    let tag: String
    var isCompact: Bool = false

    var body: some View {
        let color = Theme.tagColor(for: tag)
        Text(tag)
            .font(isCompact ? .caption2 : .caption)
            .fontWeight(.medium)
            .padding(.horizontal, isCompact ? 5 : 8)
            .padding(.vertical, isCompact ? 1 : 3)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Run Button Style

struct RunButtonStyle: ButtonStyle {
    var isRunning: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(
                Group {
                    if isRunning {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.gray.opacity(0.4))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.accentGradient)
                    }
                }
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(Theme.springSnappy, value: configuration.isPressed)
    }
}
