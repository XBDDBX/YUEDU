import UIKit
import CoreText

enum Paginator {

    static func font(for settings: ReaderSettings) -> UIFont {
        let size = CGFloat(settings.fontSize)
        switch settings.fontFamily {
        case "serif":
            if let f = UIFont(name: "Songti SC", size: size) { return f }
            if let f = UIFont(name: "NewYork-Regular", size: size) { return f }
            return UIFont.systemFont(ofSize: size)
        case "rounded":
            let base = UIFont.systemFont(ofSize: size)
            if let d = base.fontDescriptor.withDesign(.rounded) { return UIFont(descriptor: d, size: size) }
            return base
        case "mono":
            return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        default:
            if let f = UIFont(name: "PingFang SC", size: size) { return f }
            return UIFont.systemFont(ofSize: size)
        }
    }

    static func attributed(_ text: String, settings: ReaderSettings) -> NSAttributedString {
        let theme = settings.theme
        let para = NSMutableParagraphStyle()
        para.lineSpacing = CGFloat(settings.lineSpacing)
        para.paragraphSpacing = CGFloat(settings.paragraphSpacing)
        para.firstLineHeadIndent = CGFloat(settings.fontSize) * 2
        para.headIndent = 0
        para.alignment = .justified
        para.lineBreakMode = .byWordWrapping

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font(for: settings),
            .foregroundColor: UIColor(hex: theme.text),
            .paragraphStyle: para,
            .kern: 0.2
        ]
        return NSAttributedString(string: text, attributes: attrs)
    }

    static func paginate(_ attr: NSAttributedString, size: CGSize, insets: UIEdgeInsets) -> [NSRange] {
        let width = max(size.width - insets.left - insets.right, 40)
        let height = max(size.height - insets.top - insets.bottom, 40)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let total = attr.length
        guard total > 0 else { return [NSRange(location: 0, length: 0)] }

        var ranges: [NSRange] = []
        var start = 0
        var safety = 0
        while start < total && safety < 5000 {
            safety += 1
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(start, 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length <= 0 { break }
            ranges.append(NSRange(location: visible.location, length: visible.length))
            start = visible.location + visible.length
        }
        if ranges.isEmpty { ranges = [NSRange(location: 0, length: total)] }
        return ranges
    }
}

extension UIColor {
    convenience init(hex: UInt) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
