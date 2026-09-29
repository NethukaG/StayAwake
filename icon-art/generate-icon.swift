import SwiftUI
import AppKit

struct IconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 224, style: .continuous)
                .fill(Color.yellow)
                .frame(width: 896, height: 896)
            Image(systemName: "bolt.fill")
                .font(.system(size: 480, weight: .medium))
                .foregroundStyle(Color(red: 28.0/255, green: 28.0/255, blue: 30.0/255))
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
func renderIcon() {
    let renderer = ImageRenderer(content: IconView())
    renderer.scale = 1.0
    guard let nsImage = renderer.nsImage,
          let tiff = nsImage.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("FAILED"); exit(1)
    }
    let outPath = "/Users/nethukagamaarachcige/Documents/StayAwake/icon-art/icon_fullfill.png"
    try! png.write(to: URL(fileURLWithPath: outPath))
    print("saved \(outPath)")
}
MainActor.assumeIsolated { renderIcon() }
