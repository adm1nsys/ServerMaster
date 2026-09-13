//
//  ServerMasterMonitorBundle.swift
//  ServerMasterMonitor
//

import WidgetKit
import SwiftUI

@main
struct ServerMasterMonitorBundle: WidgetBundle {
    var body: some Widget {
        ServerMasterMonitor()

        // Control Center controls arrived in macOS 26. The widget itself works
        // on Sonoma, so the control is included only where it exists rather than
        // dragging the whole extension's minimum system up with it.
        if #available(macOS 26.0, *) {
            ServerMasterMonitorControl()
        }
    }
}
