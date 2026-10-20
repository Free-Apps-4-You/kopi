import CoreServices
import Foundation

/// Status codes the Apple Event Manager and Cocoa scripting report.
public enum AppleEventStatus {
    public static let success: OSStatus = 0
    public static let eventNotPermitted: OSStatus = -1743
    public static let targetNotFound: OSStatus = -600
    public static let wouldRequireConsent: OSStatus = -1744
    public static let eventNotHandled: OSStatus = -1708
    public static let noSuchObject: OSStatus = -1728
    public static let timedOut: OSStatus = -1712
    public static let userCanceled: OSStatus = -128
}
