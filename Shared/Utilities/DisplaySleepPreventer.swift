import Foundation
#if !os(macOS)
import UIKit
#endif

#if os(macOS)
import IOKit.pwr_mgt

/// A utility to prevent the display from sleeping while the app is actively reading.
@MainActor
final class DisplaySleepPreventer {
    static let shared = DisplaySleepPreventer()
    
    private var assertionID: IOPMAssertionID = 0
    private var isPreventing = false
    
    func preventSleep() {
        guard !isPreventing else { return }
        
        let reasonForActivity = "Reading Book in LingoBook" as CFString
        var newAssertionID: IOPMAssertionID = 0
        
        let success = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reasonForActivity,
            &newAssertionID
        )
        
        if success == kIOReturnSuccess {
            assertionID = newAssertionID
            isPreventing = true
        }
    }
    
    func allowSleep() {
        guard isPreventing else { return }
        
        IOPMAssertionRelease(assertionID)
        isPreventing = false
    }
}
#else
@MainActor
final class DisplaySleepPreventer {
    static let shared = DisplaySleepPreventer()

    func preventSleep() { UIApplication.shared.isIdleTimerDisabled = true }
    func allowSleep() { UIApplication.shared.isIdleTimerDisabled = false }
}
#endif
