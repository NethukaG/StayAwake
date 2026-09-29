import Cocoa
let args = CommandLine.arguments
guard args.count == 3, let img = NSImage(contentsOfFile: args[1]) else {
    print("usage: seticon <icns> <target>"); exit(1)
}
let ok = NSWorkspace.shared.setIcon(img, forFile: args[2], options: [])
print(ok ? "seticon OK" : "seticon FAILED")
