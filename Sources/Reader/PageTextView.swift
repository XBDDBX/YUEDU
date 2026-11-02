import SwiftUI
import UIKit
import CoreText

struct PageTextView: UIViewRepresentable {
    var attributed: NSAttributedString
    var range: NSRange
    var insets: UIEdgeInsets
    var highlight: NSRange? = nil
    var columns: Int = 1

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
        view.columns = columns
        view.setNeedsDisplay()
    }
}

final class PageRenderView: UIView {
    var attributed: NSAttributedString?
    var range: NSRange = NSRange(location: 0, length: 0)
    var insets: UIEdgeInsets = .zero
    var highlight: NSRange?
    var columns: Int = 1

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
        let contentHeight = max(bounds.height - insets.top - insets.bottom, 10)
        let colWidth = Paginator.columnWidth(size: bounds.size, insets: insets, columns: columns)

        let highlightRange: NSRange? = {
            guard let hl = highlight, hl.length > 0,
                  hl.location >= safe.location, NSMaxRange(hl) <= NSMaxRange(safe) else { return nil }
            return NSRange(location: hl.location - safe.location, length: hl.length)
        }()

        if columns <= 1 {
            let contentRect = CGRect(x: insets.left, y: insets.bottom, width: colWidth, height: contentHeight)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), CGPath(rect: contentRect, transform: nil), nil)
            if let hr = highlightRange {
                drawHighlight(ctx: ctx, frame: frame, localRange: hr, bounds: contentRect)
            }
            CTFrameDraw(frame, ctx)
            return
        }

        let gap = Paginator.columnGap
        var cursor = 0
        for col in 0..<columns {
            let originX = insets.left + CGFloat(col) * (colWidth + gap)
            let contentRect = CGRect(x: originX, y: insets.bottom, width: colWidth, height: contentHeight)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(cursor, 0), CGPath(rect: contentRect, transform: nil), nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length <= 0 { break }
            if let hr = highlightRange {
                drawHighlight(ctx: ctx, frame: frame, localRange: hr, bounds: contentRect)
            }
            CTFrameDraw(frame, ctx)
            cursor = visible.location + visible.length
        }
    }

    private func drawHighlight(ctx: CGContext, frame: CTFrame, localRange: NSRange, bounds: CGRect) {
        let lines = CTFrameGetLines(frame) as NSArray
        guard lines.count > 0 else { return }
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

/// 上下滚动模式：整章放在一个可滚动文本视图里
struct ChapterScrollView: UIViewRepresentable {
    var attributed: NSAttributedString
    var insets: UIEdgeInsets
    var bg: UIColor
    var highlight: NSRange?
    var onTap: (() -> Void)? = nil

    final class Coordinator: NSObject {
        var onTap: (() -> Void)?
        init(onTap: (() -> Void)?) { self.onTap = onTap }
        @objc func handleTap() { onTap?() }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = false
        tv.alwaysBounceVertical = true
        tv.showsVerticalScrollIndicator = true
        tv.backgroundColor = bg
        tv.textContainerInset = insets
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.numberOfTapsRequired = 1
        tv.addGestureRecognizer(tap)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.onTap = onTap
        if tv.attributedText.string != attributed.string {
            tv.attributedText = attributed
        }
        tv.textContainerInset = insets
        tv.backgroundColor = bg
    }
}
