import SwiftUI

// MARK: - Glass Design Tokens

/// Unified design tokens for glass surfaces across the app.
/// All glass components share these values for visual consistency.
enum GlassTokens {
    // MARK: Materials
    static let surfaceMaterial: Material = .regularMaterial
    static let thinMaterial: Material = .ultraThinMaterial

    // MARK: Corner Radii
    static let radiusLarge: CGFloat = 12      // Cards, search field
    static let radiusMedium: CGFloat = 10     // Segment containers
    static let radiusSmall: CGFloat = 8       // Inner segments, small pills

    // MARK: Stroke
    static let strokeOpacity: Double = 0.25
    static let strokeWidth: CGFloat = 0.5

    // MARK: Shadow
    static let shadowOpacity: Double = 0.06
    static let shadowRadius: CGFloat = 2
    static let shadowY: CGFloat = 1

    // MARK: Padding
    static let containerPadding: CGFloat = 4
    static let buttonPadding: CGFloat = 8

    // MARK: Colors
    static var strokeColor: Color { Color(UIColor.separator) }
    static var shadowColor: Color { Color.black }
    static var secondaryFill: Color { Color(UIColor.secondarySystemFill) }
    static var systemBackground: Color { Color(UIColor.systemBackground) }
    static var secondaryBackground: Color { Color(UIColor.secondarySystemBackground) }
    static var secondaryGroupedBackground: Color { Color(UIColor.secondarySystemGroupedBackground) }
    static var groupedBackground: Color { Color(UIColor.systemGroupedBackground) }
}

// MARK: - Glass Stroke Modifier

struct GlassStroke: ViewModifier {
    let shape: AnyShape

    func body(content: Content) -> some View {
        content.overlay(
            shape.stroke(
                GlassTokens.strokeColor.opacity(GlassTokens.strokeOpacity),
                lineWidth: GlassTokens.strokeWidth
            )
        )
    }
}

// MARK: - Glass Shadow Modifier

struct GlassShadow: ViewModifier {
    func body(content: Content) -> some View {
        content.shadow(
            color: GlassTokens.shadowColor.opacity(GlassTokens.shadowOpacity),
            radius: GlassTokens.shadowRadius,
            y: GlassTokens.shadowY
        )
    }
}

// MARK: - Glass Icon Button

/// Circular glass button for icons (filter, compose, etc.)
struct GlassIconButton: View {
    let systemName: String
    let isActive: Bool
    let action: () -> Void

    var activeColor: Color = .accentColor
    var inactiveColor: Color = .secondary
    var size: CGFloat = 36

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.58, weight: .regular))
                .foregroundStyle(isActive ? activeColor : inactiveColor)
                .frame(width: size, height: size)
                .background(Circle().fill(GlassTokens.surfaceMaterial))
                .modifier(GlassStroke(shape: AnyShape(Circle())))
                .modifier(GlassShadow())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Glass Pill

/// Pill-shaped glass container for search fields or elongated buttons
struct GlassPill<Content: View>: View {
    let content: Content
    let useMaterial: Bool
    let backgroundColor: Color

    init(
        useMaterial: Bool = false,
        backgroundColor: Color = GlassTokens.secondaryBackground,
        @ViewBuilder content: () -> Content
    ) {
        self.useMaterial = useMaterial
        self.backgroundColor = backgroundColor
        self.content = content()
    }

    var body: some View {
        content
            .background(pillBackground)
            .clipShape(Capsule())
            .modifier(GlassStroke(shape: AnyShape(Capsule())))
    }

    @ViewBuilder
    private var pillBackground: some View {
        if useMaterial {
            Capsule().fill(GlassTokens.surfaceMaterial)
        } else {
            Capsule().fill(backgroundColor)
        }
    }
}

// MARK: - Glass Segment Container

/// Container for segmented controls with glass styling
struct GlassSegmentContainer<Content: View>: View {
    let content: Content
    let useMaterial: Bool

    init(useMaterial: Bool = false, @ViewBuilder content: () -> Content) {
        self.useMaterial = useMaterial
        self.content = content()
    }

    private var containerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: GlassTokens.radiusMedium, style: .continuous)
    }

    var body: some View {
        content
            .padding(GlassTokens.containerPadding)
            .background(containerBackground)
            .clipShape(containerShape)
            .modifier(GlassStroke(shape: AnyShape(containerShape)))
    }

    @ViewBuilder
    private var containerBackground: some View {
        if useMaterial {
            containerShape.fill(GlassTokens.surfaceMaterial)
        } else {
            containerShape.fill(GlassTokens.secondaryFill)
        }
    }
}

// MARK: - Glass Segment

/// Individual segment within a GlassSegmentContainer
struct GlassSegment: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(segmentBackground)
        .clipShape(RoundedRectangle(cornerRadius: GlassTokens.radiusSmall - 1, style: .continuous))
    }

    @ViewBuilder
    private var segmentBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: GlassTokens.radiusSmall - 1, style: .continuous)
                .fill(GlassTokens.systemBackground)
                .shadow(
                    color: GlassTokens.shadowColor.opacity(GlassTokens.shadowOpacity),
                    radius: 1,
                    y: 1
                )
        } else {
            Color.clear
        }
    }
}

// MARK: - Glass Sheet Card

/// Card container for content within sheets
struct GlassSheetCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: GlassTokens.radiusLarge, style: .continuous)
    }

    var body: some View {
        content
            .background(cardShape.fill(GlassTokens.secondaryGroupedBackground))
            .clipShape(cardShape)
            .modifier(GlassStroke(shape: AnyShape(cardShape)))
            .modifier(GlassShadow())
    }
}

// MARK: - View Extensions

extension View {
    /// Apply glass stroke to any shape
    func glassStroke<S: Shape>(_ shape: S) -> some View {
        self.modifier(GlassStroke(shape: AnyShape(shape)))
    }

    /// Apply glass shadow
    func glassShadow() -> some View {
        self.modifier(GlassShadow())
    }
}

// MARK: - Previews

#Preview("Glass Components") {
    ZStack {
        GlassTokens.groupedBackground.ignoresSafeArea()

        VStack(spacing: 24) {
            // Icon buttons
            HStack(spacing: 16) {
                GlassIconButton(
                    systemName: "line.3.horizontal.decrease.circle",
                    isActive: false,
                    action: {}
                )
                GlassIconButton(
                    systemName: "line.3.horizontal.decrease.circle.fill",
                    isActive: true,
                    action: {}
                )
                GlassIconButton(
                    systemName: "square.and.pencil",
                    isActive: false,
                    action: {},
                    activeColor: .accentColor
                )
            }

            // Search pill
            GlassPill {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text("Search")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
            }
            .padding(.horizontal, 16)

            // Segment container
            GlassSegmentContainer {
                HStack(spacing: 0) {
                    GlassSegment(title: "All", isSelected: false, action: {})
                    GlassSegment(title: "Primary", isSelected: true, action: {})
                    GlassSegment(title: "Money", isSelected: false, action: {})
                }
            }
            .padding(.horizontal, 16)

            // Sheet card
            GlassSheetCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Card Title")
                        .font(.headline)
                    Text("This is content inside a glass sheet card.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .padding(.horizontal, 16)
        }
    }
}
