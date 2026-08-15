import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Registered before the run loop starts: Finder gives up on a service
// request that is not answered promptly after launch.
application.servicesProvider = delegate
NSUpdateDynamicServices()
application.setActivationPolicy(.regular)
application.run()
