#if DEBUG
    import SwiftUI

    // Interactive entry scenarios use the same protected image pipeline and local fixtures as UI tests.
    #Preview("Zgłoszenie — scenariusz z profilu") {
        GatewayCommunityPreviewView(mode: "avatar-report")
    }
    #Preview("Odzyskiwanie — scenariusz po błędzie") {
        GatewayCommunityPreviewView(mode: "avatar-report-lost")
    }
#endif
