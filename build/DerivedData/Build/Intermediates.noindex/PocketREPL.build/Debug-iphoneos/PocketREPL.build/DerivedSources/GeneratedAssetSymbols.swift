import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(DeveloperToolsSupport)
import DeveloperToolsSupport
#endif

#if SWIFT_PACKAGE
private let resourceBundle = Foundation.Bundle.module
#else
private class ResourceBundleClass {}
private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
#endif

// MARK: - Color Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ColorResource {

    /// The "EscherBackground" asset catalog color resource.
    static let escherBackground = DeveloperToolsSupport.ColorResource(name: "EscherBackground", bundle: resourceBundle)

    /// The "EscherForeground" asset catalog color resource.
    static let escherForeground = DeveloperToolsSupport.ColorResource(name: "EscherForeground", bundle: resourceBundle)

    /// The "EscherSecondaryText" asset catalog color resource.
    static let escherSecondaryText = DeveloperToolsSupport.ColorResource(name: "EscherSecondaryText", bundle: resourceBundle)

    /// The "EscherSurface" asset catalog color resource.
    static let escherSurface = DeveloperToolsSupport.ColorResource(name: "EscherSurface", bundle: resourceBundle)

    /// The "EscherSurfaceSecondary" asset catalog color resource.
    static let escherSurfaceSecondary = DeveloperToolsSupport.ColorResource(name: "EscherSurfaceSecondary", bundle: resourceBundle)

}

// MARK: - Image Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ImageResource {

}

// MARK: - Color Symbol Extensions -

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSColor {

    /// The "EscherBackground" asset catalog color.
    static var escherBackground: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .escherBackground)
#else
        .init()
#endif
    }

    /// The "EscherForeground" asset catalog color.
    static var escherForeground: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .escherForeground)
#else
        .init()
#endif
    }

    /// The "EscherSecondaryText" asset catalog color.
    static var escherSecondaryText: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .escherSecondaryText)
#else
        .init()
#endif
    }

    /// The "EscherSurface" asset catalog color.
    static var escherSurface: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .escherSurface)
#else
        .init()
#endif
    }

    /// The "EscherSurfaceSecondary" asset catalog color.
    static var escherSurfaceSecondary: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .escherSurfaceSecondary)
#else
        .init()
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIColor {

    /// The "EscherBackground" asset catalog color.
    static var escherBackground: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .escherBackground)
#else
        .init()
#endif
    }

    /// The "EscherForeground" asset catalog color.
    static var escherForeground: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .escherForeground)
#else
        .init()
#endif
    }

    /// The "EscherSecondaryText" asset catalog color.
    static var escherSecondaryText: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .escherSecondaryText)
#else
        .init()
#endif
    }

    /// The "EscherSurface" asset catalog color.
    static var escherSurface: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .escherSurface)
#else
        .init()
#endif
    }

    /// The "EscherSurfaceSecondary" asset catalog color.
    static var escherSurfaceSecondary: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .escherSurfaceSecondary)
#else
        .init()
#endif
    }

}
#endif

#if canImport(SwiftUI)
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.Color {

    /// The "EscherBackground" asset catalog color.
    static var escherBackground: SwiftUI.Color { .init(.escherBackground) }

    /// The "EscherForeground" asset catalog color.
    static var escherForeground: SwiftUI.Color { .init(.escherForeground) }

    /// The "EscherSecondaryText" asset catalog color.
    static var escherSecondaryText: SwiftUI.Color { .init(.escherSecondaryText) }

    /// The "EscherSurface" asset catalog color.
    static var escherSurface: SwiftUI.Color { .init(.escherSurface) }

    /// The "EscherSurfaceSecondary" asset catalog color.
    static var escherSurfaceSecondary: SwiftUI.Color { .init(.escherSurfaceSecondary) }

}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.ShapeStyle where Self == SwiftUI.Color {

    /// The "EscherBackground" asset catalog color.
    static var escherBackground: SwiftUI.Color { .init(.escherBackground) }

    /// The "EscherForeground" asset catalog color.
    static var escherForeground: SwiftUI.Color { .init(.escherForeground) }

    /// The "EscherSecondaryText" asset catalog color.
    static var escherSecondaryText: SwiftUI.Color { .init(.escherSecondaryText) }

    /// The "EscherSurface" asset catalog color.
    static var escherSurface: SwiftUI.Color { .init(.escherSurface) }

    /// The "EscherSurfaceSecondary" asset catalog color.
    static var escherSurfaceSecondary: SwiftUI.Color { .init(.escherSurfaceSecondary) }

}
#endif

// MARK: - Image Symbol Extensions -

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSImage {

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIImage {

}
#endif

// MARK: - Thinnable Asset Support -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@available(watchOS, unavailable)
extension DeveloperToolsSupport.ColorResource {

    private init?(thinnableName: Swift.String, bundle: Foundation.Bundle) {
#if canImport(AppKit) && os(macOS)
        if AppKit.NSColor(named: NSColor.Name(thinnableName), bundle: bundle) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#elseif canImport(UIKit) && !os(watchOS)
        if UIKit.UIColor(named: thinnableName, in: bundle, compatibleWith: nil) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSColor {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
#if !targetEnvironment(macCatalyst)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIColor {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
#if !os(watchOS)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

#if canImport(SwiftUI)
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.Color {

    private init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
        if let resource = thinnableResource {
            self.init(resource)
        } else {
            return nil
        }
    }

}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.ShapeStyle where Self == SwiftUI.Color {

    private init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
        if let resource = thinnableResource {
            self.init(resource)
        } else {
            return nil
        }
    }

}
#endif

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@available(watchOS, unavailable)
extension DeveloperToolsSupport.ImageResource {

    private init?(thinnableName: Swift.String, bundle: Foundation.Bundle) {
#if canImport(AppKit) && os(macOS)
        if bundle.image(forResource: NSImage.Name(thinnableName)) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#elseif canImport(UIKit) && !os(watchOS)
        if UIKit.UIImage(named: thinnableName, in: bundle, compatibleWith: nil) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIImage {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ImageResource?) {
#if !os(watchOS)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

