#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The resource bundle ID.
static NSString * const ACBundleID AC_SWIFT_PRIVATE = @"com.bontecou.PocketREPL";

/// The "EscherBackground" asset catalog color resource.
static NSString * const ACColorNameEscherBackground AC_SWIFT_PRIVATE = @"EscherBackground";

/// The "EscherForeground" asset catalog color resource.
static NSString * const ACColorNameEscherForeground AC_SWIFT_PRIVATE = @"EscherForeground";

/// The "EscherSecondaryText" asset catalog color resource.
static NSString * const ACColorNameEscherSecondaryText AC_SWIFT_PRIVATE = @"EscherSecondaryText";

/// The "EscherSurface" asset catalog color resource.
static NSString * const ACColorNameEscherSurface AC_SWIFT_PRIVATE = @"EscherSurface";

/// The "EscherSurfaceSecondary" asset catalog color resource.
static NSString * const ACColorNameEscherSurfaceSecondary AC_SWIFT_PRIVATE = @"EscherSurfaceSecondary";

#undef AC_SWIFT_PRIVATE
