import Foundation
import CoreGraphics

/// Автораскладка tidy tree (Бухгейм/Уокер, линейное время).
/// Чистая функция: дерево → позиции центров кругов. Сиблинги слева направо
/// в порядке массива children, родитель центрируется над своим поддеревом.
/// Ручного перетаскивания узлов в продукте нет — эта функция единственный
/// источник позиций; поэтому анимация перекладки — просто withAnimation
/// вокруг мутации модели.
public enum GraphLayout {
    public static func layout(_ root: Job) -> [UUID: CGPoint] {
        let tree = LNode(root, parent: nil, index: 0)
        firstWalk(tree)
        var positions: [UUID: CGPoint] = [:]
        secondWalk(tree, modSum: 0, depth: 0, into: &positions)
        // Нормализация: минимальный x = 0.
        if let minX = positions.values.map(\.x).min(), minX != 0 {
            for (key, point) in positions {
                positions[key] = CGPoint(x: point.x - minX, y: point.y)
            }
        }
        return positions
    }

    private static let distance = LayoutMetrics.columnWidth

    // MARK: - Рабочий узел алгоритма

    private final class LNode {
        let job: Job
        weak var parent: LNode?
        var children: [LNode] = []
        let index: Int // номер среди сиблингов (number в терминах Бухгейма)

        var prelim: CGFloat = 0
        var mod: CGFloat = 0
        var shift: CGFloat = 0
        var change: CGFloat = 0
        var thread: LNode?
        var ancestorNode: LNode?

        init(_ job: Job, parent: LNode?, index: Int) {
            self.job = job
            self.parent = parent
            self.index = index
            self.ancestorNode = nil
            self.children = job.children.enumerated().map { LNode($0.element, parent: self, index: $0.offset) }
            self.ancestorNode = self
        }

        var leftSibling: LNode? {
            guard let parent, index > 0 else { return nil }
            return parent.children[index - 1]
        }

        var leftmostSibling: LNode? {
            guard let parent, index > 0 else { return nil }
            return parent.children[0]
        }
    }

    private static func nextLeft(_ v: LNode) -> LNode? {
        v.children.first ?? v.thread
    }

    private static func nextRight(_ v: LNode) -> LNode? {
        v.children.last ?? v.thread
    }

    private static func firstWalk(_ v: LNode) {
        if v.children.isEmpty {
            v.prelim = v.leftSibling.map { $0.prelim + distance } ?? 0
            return
        }
        var defaultAncestor = v.children[0]
        for w in v.children {
            firstWalk(w)
            defaultAncestor = apportion(w, defaultAncestor: defaultAncestor)
        }
        executeShifts(v)
        let midpoint = (v.children.first!.prelim + v.children.last!.prelim) / 2
        if let left = v.leftSibling {
            v.prelim = left.prelim + distance
            v.mod = v.prelim - midpoint
        } else {
            v.prelim = midpoint
        }
    }

    private static func apportion(_ v: LNode, defaultAncestor: LNode) -> LNode {
        guard let w = v.leftSibling else { return defaultAncestor }
        var defaultAncestor = defaultAncestor
        var vip = v, vop = v
        var vim = w
        var vom = vip.leftmostSibling ?? vip
        var sip = vip.mod, sop = vop.mod
        var sim = vim.mod, som = vom.mod

        while let nextVim = nextRight(vim), let nextVip = nextLeft(vip) {
            vim = nextVim
            vip = nextVip
            vom = nextLeft(vom) ?? vom
            vop = nextRight(vop) ?? vop
            vop.ancestorNode = v
            let shift = (vim.prelim + sim) - (vip.prelim + sip) + distance
            if shift > 0 {
                moveSubtree(ancestor(vim, v: v, defaultAncestor: defaultAncestor), v, shift)
                sip += shift
                sop += shift
            }
            sim += vim.mod
            sip += vip.mod
            som += vom.mod
            sop += vop.mod
        }
        if let nextVim = nextRight(vim), nextRight(vop) == nil {
            vop.thread = nextVim
            vop.mod += sim - sop
        }
        if let nextVip = nextLeft(vip), nextLeft(vom) == nil {
            vom.thread = nextVip
            vom.mod += sip - som
            defaultAncestor = v
        }
        return defaultAncestor
    }

    private static func moveSubtree(_ wm: LNode, _ wp: LNode, _ shift: CGFloat) {
        let subtrees = CGFloat(wp.index - wm.index)
        guard subtrees != 0 else { return }
        wp.change -= shift / subtrees
        wp.shift += shift
        wm.change += shift / subtrees
        wp.prelim += shift
        wp.mod += shift
    }

    private static func executeShifts(_ v: LNode) {
        var shift: CGFloat = 0
        var change: CGFloat = 0
        for w in v.children.reversed() {
            w.prelim += shift
            w.mod += shift
            change += w.change
            shift += w.shift + change
        }
    }

    private static func ancestor(_ vim: LNode, v: LNode, defaultAncestor: LNode) -> LNode {
        if let anc = vim.ancestorNode, anc.parent === v.parent {
            return anc
        }
        return defaultAncestor
    }

    private static func secondWalk(_ v: LNode, modSum: CGFloat, depth: Int, into positions: inout [UUID: CGPoint]) {
        positions[v.job.id] = CGPoint(
            x: v.prelim + modSum,
            y: CGFloat(depth) * LayoutMetrics.rowHeight
        )
        for w in v.children {
            secondWalk(w, modSum: modSum + v.mod, depth: depth + 1, into: &positions)
        }
    }
}
