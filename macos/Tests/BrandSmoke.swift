import AppKit
@main struct BrandSmoke {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let source = NSImage(contentsOf: root.appendingPathComponent("artifacts/FusionPlay Mac.app/Contents/Resources/AppIcon.icns"))!
        let tile = AppBrand.dockImage(from: source)
        let rep = NSBitmapImageRep(data: tile.tiffRepresentation!)!
        assert(rep.pixelsWide == 1024 && rep.pixelsHigh == 1024)
        assert(rep.colorAt(x: 0, y: 0)!.alphaComponent == 0)
        assert(rep.colorAt(x: 512, y: 20)!.alphaComponent == 0)
        assert(rep.colorAt(x: 512, y: 512)!.alphaComponent > 0.99)
        assert(AppBrand.menuIcon.isTemplate)
        assert(AppBrand.menuIcon.size == NSSize(width: 20, height: 16))
        print("Dock tile: transparent margins, rounded corners, opaque interior PASS")
    }
}
