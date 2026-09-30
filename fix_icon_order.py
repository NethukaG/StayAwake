import re

path = "Sources/StayAwake/App.swift"
with open(path) as f:
    src = f.read()

old = """    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )"""

assert src.count(old) == 1, "updaterController decl not found"

new = """    // lazy + startingUpdater: false: a stored-property initializer for this would run during
    // AppDelegate's own init(), before applicationDidFinishLaunching gets a chance to set
    // NSApp.applicationIconImage below -- Sparkle reads the host app icon once, at controller
    // creation time, so it was permanently caching the generic fallback icon. Making this lazy
    // and starting the updater manually (after the icon is set) fixes that ordering.
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )"""

src = src.replace(old, new)

old2 = """        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = icon
        }
"""

assert src.count(old2) == 1, "icon-setting block not found"

new2 = old2 + """
        // Now that the real icon is set, create/start the updater controller so Sparkle's
        // own dialogs pick it up instead of caching the generic fallback.
        updaterController.startUpdater()
"""

src = src.replace(old2, new2)

with open(path, "w") as f:
    f.write(src)
print("ok")
