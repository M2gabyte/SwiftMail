import SwiftUI

// MARK: - Glass Toolbar Tokens (Floating Action Bars)

/// Tokens for floating toolbar surfaces that must NOT pick up color from content behind them.
/// Used for reply/archive/trash bar in email detail.
enum GlassToolbarTokens {
    static let cornerRadius: CGFloat = 22
    static let height: CGFloat = 54
    static let horizontalPadding: CGFloat = 18
    static let iconSize: CGFloat = 19

    static let strokeOpacity: Double = 0.22
    static let strokeWidth: CGFloat = 0.5

    /// Neutralizes underlying email colors so the bar NEVER turns pink/maroon.
    static func neutralOverlay(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.black.opacity(0.42)
        default:
            return Color.white.opacity(0.58)
        }
    }

    static func shadowColor(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.black.opacity(0.55)
        default:
            return Color.black.opacity(0.12)
        }
    }

    static func shadowRadius(_ scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? 18 : 14
    }

    static func shadowYOffset(_ scheme: ColorScheme) -> CGFloat {
        scheme == .dark ? 10 : 8
    }
}

// MARK: - Glass Design Tokens

/// Unified design tokens for glass surfaces across the app.
/// All glass components share these values for visual consistency.
enum GlassTokens {
    // MARK: Materials (contextual hierarchy)
    /// Ultra-thin for top chrome: pills, segmented container backgrounds
    static let chromeMaterial: Material = .ultraThinMaterial
    /// Thin for interactive controls inside chrome: icon buttons
    static let controlMaterial: Material = .thinMaterial
    /// Regular for cards, sheets, and prominent surfaces
    static let cardMaterial: Material = .regularMaterial

    // Legacy aliases (prefer contextual names above)
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

/// Circular glass button for icons (settings, filter, etc.)
/// Uses hierarchical rendering and secondary foreground for premium look.
struct GlassIconButton: View {
    let systemName: String
    var isActive: Bool = false
    var action: (() -> Void)? = nil

    var activeColor: Color = .accentColor
    var inactiveColor: Color = .secondary
    var size: CGFloat = 36

    var body: some View {
        let content = Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isActive ? activeColor : inactiveColor)
            .frame(width: size, height: size)
            .background(Circle().fill(GlassTokens.chromeMaterial))
            .modifier(GlassStroke(shape: AnyShape(Circle())))
            .modifier(GlassShadow())

        if let action = action {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}

// MARK: - Glass Nav Pill

/// Navigation pill for mailbox picker with icon, title, and chevron.
/// Premium glass styling with hierarchical icons.
struct GlassNavPill: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 2)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(GlassTokens.chromeMaterial, in: Capsule())
        .glassStroke(Capsule())
        .glassShadow()
        .contentShape(Capsule())
        .padding(.vertical, 4) // yields ~44pt hit area
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
            Capsule().fill(GlassTokens.chromeMaterial)
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
            containerShape.fill(GlassTokens.chromeMaterial)
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

    /// Use for floating toolbars (reply/archive/trash bar) that must stay neutral over email content.
    /// Neutralizes underlying HTML colors so the bar never picks up pink/maroon from brand imagery.
    func glassToolbarSurface(cornerRadius: CGFloat = GlassToolbarTokens.cornerRadius,
                             scheme: ColorScheme) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return self
            .background {
                shape
                    .fill(GlassTokens.controlMaterial)
                    // Neutralize underlying HTML colors (prevents pink/maroon pickup)
                    .overlay(shape.fill(GlassToolbarTokens.neutralOverlay(scheme)))
                    // Crisp edge
                    .overlay(
                        shape.strokeBorder(GlassTokens.strokeColor.opacity(GlassToolbarTokens.strokeOpacity),
                                           lineWidth: GlassToolbarTokens.strokeWidth)
                    )
                    // Depth
                    .shadow(color: GlassToolbarTokens.shadowColor(scheme),
                            radius: GlassToolbarTokens.shadowRadius(scheme),
                            x: 0,
                            y: GlassToolbarTokens.shadowYOffset(scheme))
                    .compositingGroup()
            }
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
