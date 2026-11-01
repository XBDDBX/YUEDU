import SwiftUI
import UIKit
import CoreText

struct PageTextView: UIViewRepresentable {
    var attributed: NSAttributedString
    var range: NSRange
    var insets: UIEdgeInsets
    var highlight: NSRange? = nil

    func makeUIView(context: Context) -> PageRenderView {
        let v = PageRenderView()
        v.backgroundColor = .clear
        v.isOpaque = false
        v.contentMode = .redraw
        return v
    }

    func updateUIView(_ view: PageRenderView, context: Context) {
        view.attributed = attributed
        view.range = range
        view.insets = insets
        view.highlight = highlight
        view.setNeedsDisplay()
    }
}

final class PageRenderView: UIView {
    var attributed: NSAttributedString?
    var range: NSRange = NSRange(location: 0, length: 0)
    var insets: UIEdgeInsets = .zero
    var highlight: NSRange?

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let attributed else { return }
        let total = attributed.length
        let loc = min(max(range.location, 0), total)
        let len = min(max(range.length, 0), total - loc)
        let safe = NSRange(location: loc, length: len)

        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)

        let sub = attributed.attributedSubstring(from: safe)
        let framesetter = CTFramesetterCreateWithAttributedString(sub)

        let contentRect = CGRect(
            x: insets.left,
            y: insets.bottom,
            width: max(bounds.width - insets.left - insets.right, 10),
            height: max(bounds.height - insets.top - insets.bottom, 10)
        )
        let path = CGPath(rect: contentRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)

        if let hl = highlight, hl.length > 0, hl.location >= safe.location, NSMaxRange(hl) <= NSMaxRange(safe) {
            drawHighlight(ctx: ctx, frame: frame, localRange: NSRange(location: hl.location - safe.location, length: hl.length), bounds: contentRect)
        }

        CTFrameDraw(frame, ctx)
    }

    private func drawHighlight(ctx: CGContext, frame: CTFrame, localRange: NSRange, bounds: CGRect) {
        let lines = CTFrameGetLines(frame) as NSArray
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), &origins)

        for i in 0..<lines.count {
            let line = lines[i] as! CTLine
            let lineRange = CTLineGetStringRange(line)
            let s = max(lineRange.location, localRange.location)
            let e = min(lineRange.location + lineRange.length, NSMaxRange(localRange))
            if e <= s { continue }

            let startX = CTLineGetOffsetForStringIndex(line, s, nil)
            let endX = CTLineGetOffsetForStringIndex(line, e, nil)
            let origin = origins[i]
            let y = bounds.minY + origin.y - 3
            let rect = CGRect(x: bounds.minX + startX, y: y, width: max(endX - startX, 1), height: 18)
            ctx.setFillColor(UIColor.systemYellow.withAlphaComponent(0.28).cgColor)
            ctx.fill(rect)
        }
    }
}
