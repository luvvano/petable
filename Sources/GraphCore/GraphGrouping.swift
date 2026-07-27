import Foundation

/// Группировка графов проекта. Граф работ может лежать **под** другим
/// графом (`Stage.parentID`) — сайдбар показывает дерево, а не плоский
/// список: связанные графы (разные сегменты одного продукта, версии
/// одной гипотезы, декомпозиция большой работы в отдельный граф)
/// собираются в группу под общим родителем.
///
/// Группировка — свойство списка стадий, а не содержимого графов:
/// вложенный граф остаётся самостоятельным документом со своими
/// уровнями, undo и экспортом. Родитель — обычный граф, а не папка:
/// отдельной сущности «группа» нет, любой граф можно сделать
/// контейнером, ничего при этом не теряя.
///
/// Порядок внутри одного родителя — порядок стадий в файле.
extension Envelope {
    /// Строка дерева графов, разложенного в плоский список для сайдбара:
    /// потомки идут сразу за родителем, `depth` даёт отступ.
    public struct GraphOutlineRow: Identifiable, Equatable, Sendable {
        public var stage: Stage
        /// Глубина вложенности: 0 — верхний уровень.
        public var depth: Int
        /// Есть ли видимые потомки — рисовать ли треугольник раскрытия.
        public var hasChildren: Bool

        public var id: UUID { stage.id }

        public init(stage: Stage, depth: Int, hasChildren: Bool) {
            self.stage = stage
            self.depth = depth
            self.hasChildren = hasChildren
        }
    }
}

extension Array where Element == Envelope.Stage {
    /// Графы работ в порядке файла.
    public var jobGraphStages: [Envelope.Stage] {
        filter { $0.type == Envelope.jobGraphStageType }
    }

    /// Прямые потомки графа; `nil` — верхний уровень.
    public func graphChildren(of parent: UUID?) -> [Envelope.Stage] {
        jobGraphStages.filter { $0.parentID == parent }
    }

    /// Все потомки на любую глубину, сверху вниз (сам граф не включён).
    /// Нужны при удалении (группа уходит целиком) и при переносе
    /// (в свой потомок вкладывать нельзя — получился бы цикл).
    public func graphDescendants(of id: UUID) -> [UUID] {
        var result: [UUID] = []
        var queue = graphChildren(of: id).map(\.id)
        while !queue.isEmpty {
            let next = queue.removeFirst()
            result.append(next)
            queue.append(contentsOf: graphChildren(of: next).map(\.id))
        }
        return result
    }

    /// Можно ли положить граф под нового родителя. `nil` — верхний
    /// уровень (всегда можно). Запрещены только циклы: сам в себя и
    /// в собственного потомка — иначе поддерево исчезает из дерева.
    public func canNestGraph(_ id: UUID, under parent: UUID?) -> Bool {
        guard jobGraphStages.contains(where: { $0.id == id }) else { return false }
        guard let parent else { return true }
        guard parent != id, jobGraphStages.contains(where: { $0.id == parent }) else { return false }
        return !graphDescendants(of: id).contains(parent)
    }

    /// Дерево графов в плоском виде для списка сайдбара.
    /// `collapsed` — свёрнутые узлы: их поддеревья не выдаются.
    /// `includes` — фильтр (например, по происхождению артефакта):
    /// родитель остаётся видимым, если подходит он сам **или** кто-то
    /// в его поддереве, иначе фильтр разорвал бы группу.
    public func graphOutline(
        collapsed: Set<UUID> = [],
        includes: (Envelope.Stage) -> Bool = { _ in true }
    ) -> [Envelope.GraphOutlineRow] {
        func matchesSubtree(_ stage: Envelope.Stage) -> Bool {
            includes(stage) || graphChildren(of: stage.id).contains(where: matchesSubtree)
        }

        var rows: [Envelope.GraphOutlineRow] = []
        func walk(parent: UUID?, depth: Int) {
            for stage in graphChildren(of: parent) where matchesSubtree(stage) {
                let visibleChildren = graphChildren(of: stage.id).filter(matchesSubtree)
                rows.append(
                    Envelope.GraphOutlineRow(
                        stage: stage,
                        depth: depth,
                        hasChildren: !visibleChildren.isEmpty
                    )
                )
                if !collapsed.contains(stage.id) {
                    walk(parent: stage.id, depth: depth + 1)
                }
            }
        }
        walk(parent: nil, depth: 0)
        return rows
    }

    /// Чинит ссылки на родителя: несуществующий родитель, ссылка на себя
    /// и циклы (правленый вручную или собранный агентом файл) → граф
    /// уезжает на верхний уровень. Иначе такие графы пропали бы из
    /// сайдбара: обход дерева идёт от верхнего уровня вниз.
    public mutating func normalizeGraphParents() {
        let ids = Set(jobGraphStages.map(\.id))
        for index in indices {
            guard self[index].type == Envelope.jobGraphStageType else {
                self[index].parentID = nil // родитель есть только у графов
                continue
            }
            if let parent = self[index].parentID,
               parent == self[index].id || !ids.contains(parent) {
                self[index].parentID = nil
            }
        }
        // Цикл — узел, от которого не дойти до верхнего уровня. Рвём его
        // на первом же таком узле: тот встаёт наверх, остальные остаются
        // его потомками — минимальная правка, ни один граф не потерян.
        for index in indices where self[index].type == Envelope.jobGraphStageType {
            var seen: Set<UUID> = [self[index].id]
            var current = self[index].parentID
            while let id = current {
                guard seen.insert(id).inserted else {
                    self[index].parentID = nil
                    break
                }
                current = first(where: { $0.id == id })?.parentID
            }
        }
    }
}
