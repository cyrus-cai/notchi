import SwiftUI
import AppKit

/// The app's icons come from **Phosphor** (regular weight; fill where an SF name
/// asked for `.fill`), the same set the backend uses for generated pages.
///
/// Each glyph is compiled into `Assets.xcassets/Phosphor` as a custom symbol
/// (`ph.<name>`), so it sizes with `.font`, `.imageScale` and
/// `.symbolEffect` like an SF Symbol. The assets are generated from
/// @phosphor-icons/core 2.1.1. MIT License, Copyright (c) 2023 Phosphor Icons.
enum PhosphorIcons {
    struct Mark: Equatable {
        /// Custom symbol name in the asset catalog.
        let asset: String
    }

    /// The update row, resting and "Update to X".
    static let circleFadingArrowUp = Mark(asset: "ph.arrow-circle-up")
    /// A loop's prompt.
    static let scrollText = Mark(asset: "ph.scroll")
    /// What's New.
    static let calendarStar = Mark(asset: "ph.calendar-star")
    /// The Ask bucket.
    static let messageCircle = Mark(asset: "ph.chat-circle")
    /// The Note destination.
    static let pencilLine = Mark(asset: "ph.pencil-line")
    /// The Remind destination.
    static let bell = Mark(asset: "ph.bell")
    /// The Agent bucket.
    static let codeXml = Mark(asset: "ph.code")
    static let terminal = Mark(asset: "ph.terminal")
    static let folder = Mark(asset: "ph.folder")
    static let plus = Mark(asset: "ph.plus")
    static let paperclip = Mark(asset: "ph.paperclip")
    static let chevronDown = Mark(asset: "ph.caret-down")
    static let clock = Mark(asset: "ph.clock")
    /// Loop rows.
    static let loop = Mark(asset: "ph.repeat")
    /// The stop-loop row.
    static let circleStop = Mark(asset: "ph.stop")
    /// The continue-loop row.
    static let play = Mark(asset: "ph.play")
    /// Token counts in Stats.
    static let hash = Mark(asset: "ph.hash")
    /// The manage menu's Stats row.
    static let chartNoAxesColumn = Mark(asset: "ph.chart-bar")
    /// Wallet menu: Models and pricing.
    static let pricingBars = Mark(asset: "ph.chart-bar")
    /// Wallet menu: Usage.
    static let activity = Mark(asset: "ph.pulse")
    /// Wallet menu: Billing history.
    static let receipt = Mark(asset: "ph.receipt")
    /// Keyboard shortcuts.
    static let command = Mark(asset: "ph.command")
    /// Add credit.
    static let circleDollarSign = Mark(asset: "ph.currency-circle-dollar")
    /// The balance card's Privacy link.
    static let shieldCheck = Mark(asset: "ph.shield-check")
    static let settings = Mark(asset: "ph.gear-six")
    /// Settings sidebar categories.
    static let userSound = Mark(asset: "ph.user-sound")
    static let brain = Mark(asset: "ph.brain")
    static let palette = Mark(asset: "ph.palette")
    static let plugs = Mark(asset: "ph.plugs-connected")
    static let paperPlane = Mark(asset: "ph.paper-plane-tilt")
    static let info = Mark(asset: "ph.info")
    static let key = Mark(asset: "ph.key")
    static let magnifyingGlass = Mark(asset: "ph.magnifying-glass")
    /// Settings picker cards.
    static let laptop = Mark(asset: "ph.laptop")
    static let monitor = Mark(asset: "ph.monitor")
    static let cornersOut = Mark(asset: "ph.corners-out")
    static let browser = Mark(asset: "ph.browser")
    static let pictureInPicture = Mark(asset: "ph.picture-in-picture")

    /// SF Symbol name -> Phosphor custom symbol. Call sites keep their SF names
    /// and go through `Image(icon:)`; a name missing here falls back to SF
    /// Symbols, which covers icon names the model picks for visual blocks.
    static let bySystemName: [String: String] = [
        "xmark": "ph.x",
        "arrow.up.right": "ph.arrow-up-right",
        "chevron.right": "ph.caret-right",
        "chevron.left": "ph.caret-left",
        "chevron.down": "ph.caret-down",
        "chevron.up": "ph.caret-up",
        "chevron.up.chevron.down": "ph.caret-up-down",
        "checkmark": "ph.check",
        "ellipsis": "ph.dots-three",
        "trash": "ph.trash",
        "doc.text": "ph.file-text",
        "doc.on.doc": "ph.copy",
        "arrow.clockwise": "ph.arrow-clockwise",
        "arrow.counterclockwise": "ph.arrow-counter-clockwise",
        "pin": "ph.push-pin",
        "pin.fill": "ph.push-pin.fill",
        "photo": "ph.image",
        "plus": "ph.plus",
        "minus": "ph.minus",
        "pencil": "ph.pencil-simple",
        "clock.arrow.circlepath": "ph.clock-counter-clockwise",
        "arrow.down": "ph.arrow-down",
        "arrow.up": "ph.arrow-up",
        "slider.horizontal.3": "ph.sliders-horizontal",
        "text.quote": "ph.quotes",
        "checkmark.circle.fill": "ph.check-circle.fill",
        "link": "ph.link",
        "stop.circle": "ph.stop-circle",
        "bubble.left": "ph.chat",
        "magnifyingglass": "ph.magnifying-glass",
        "paperclip": "ph.paperclip",
        "info.circle": "ph.info",
        "arrowshape.turn.up.left": "ph.arrow-bend-up-left",
        "square": "ph.square",
        "checkmark.square": "ph.check-square",
        "macwindow.on.rectangle": "ph.browsers",
        "arrow.turn.down.right": "ph.arrow-elbow-down-right",
        "camera.viewfinder": "ph.scan",
        "icloud": "ph.cloud",
        "icloud.slash": "ph.cloud-slash",
        "text.bubble": "ph.chat-text",
        "power": "ph.power",
        "star": "ph.star",
        "star.fill": "ph.star.fill",
        "heart": "ph.heart",
        "heart.fill": "ph.heart.fill",
        "bubble.left.and.bubble.right.fill": "ph.chats.fill",
        "checklist": "ph.list-checks",
        "text.alignleft": "ph.text-align-left",
        "arrow.uturn.left": "ph.arrow-u-up-left",
        "clock": "ph.clock",
        "circle.dotted": "ph.circle-dashed",
        "circle": "ph.circle",
        "command": "ph.command",
        "folder": "ph.folder",
        "repeat": "ph.repeat",
        "gift": "ph.gift",
        "calendar": "ph.calendar-blank",
        "envelope": "ph.envelope",
        "mail": "ph.envelope",
        "key": "ph.key",
        "tag": "ph.tag",
        "note": "ph.note",
        "clipboard": "ph.clipboard",
        "location": "ph.map-pin",
        "cloud": "ph.cloud",
        "video": "ph.video-camera",
        "dice": "ph.dice-five",
        "network": "ph.globe",
    ]
}

extension Image {
    /// Phosphor glyph for an SF Symbol name, or the SF Symbol when none is mapped.
    init(icon name: String) {
        if let asset = PhosphorIcons.bySystemName[name] {
            self.init(asset)
        } else {
            self.init(systemName: name)
        }
    }
}

extension NSImage {
    /// AppKit counterpart of `Image(icon:)`.
    static func icon(_ name: String) -> NSImage? {
        if let asset = PhosphorIcons.bySystemName[name], let image = NSImage(named: asset) {
            return image
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}

/// A Phosphor glyph drawn in a square of `size` points. Takes its colour from the
/// environment's foreground style.
struct PhosphorIcon: View {
    let mark: PhosphorIcons.Mark
    /// Rendered side, in points.
    var size: CGFloat = 13

    var body: some View {
        // Sized by font, not `.resizable()`: a resizable symbol stretches its ink
        // to the frame and drops the glyph's own margins, so a plus fills the
        // square edge to edge. The 256-unit Phosphor grid comes out 1.195 times
        // the point size, so this puts the full grid in `size`.
        Image(mark.asset)
            .font(.system(size: size / 1.195))
            .frame(width: size, height: size)
    }
}
