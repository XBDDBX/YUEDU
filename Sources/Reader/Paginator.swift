import UIKit
import CoreText

enum Paginator {

    /// 双栏排版时两栏之间的间距
    static let columnGap: CGFloat = 28

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
        para.firstLineHeadIndent = CGFloat(settings.fontSize) * CGFloat(settings.firstLineIndent)
        para.headIndent = 0
        para.alignment = .justified
        para.lineBreakMode = .byWordWrapping

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font(for: settings),
            .foregroundColor: UIColor(hex: theme.text),
            .paragraphStyle: para,
            .kern: CGFloat(settings.letterSpacing)
        ]
        return NSAttributedString(string: text, attributes: attrs)
    }

    /// 单栏宽度（双栏时已经扣掉栏间距）
    static func columnWidth(size: CGSize, insets: UIEdgeInsets, columns: Int) -> CGFloat {
        let usable = size.width - insets.left - insets.right
        guard columns > 1 else { return max(usable, 40) }
        let gap = columnGap * CGFloat(columns - 1)
        return max((usable - gap) / CGFloat(columns), 40)
    }

    /// 按栏分页：每一"屏"是一段连续文本，双栏时这段文本会先填满左栏再填右栏
    static func paginate(_ attr: NSAttributedString, size: CGSize, insets: UIEdgeInsets, columns: Int = 1) -> [NSRange] {
        let width = columnWidth(size: size, insets: insets, columns: columns)
        let height = max(size.height - insets.top - insets.bottom, 40)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let total = attr.length
        guard total > 0 else { return [NSRange(location: 0, length: 0)] }

        var ranges: [NSRange] = []
        var start = 0
        var safety = 0
        let perScreen = max(columns, 1)

        while start < total && safety < 5000 {
            safety += 1
            var cursor = start
            var end = start
            for _ in 0..<perScreen {
                if cursor >= total { break }
                let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(cursor, 0), path, nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                if visible.length <= 0 { break }
                end = visible.location + visible.length
                cursor = end
            }
            if end <= start { break }
            ranges.append(NSRange(location: start, length: end - start))
            start = end
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
