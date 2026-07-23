import SwiftUI
import GraphCore

// MARK: - Редактор сегмента

/// Редактор сегмента AJTBD: кóровые работы с критериями успеха (корень
/// сегментации), порядок приоритетов, каузальные критерии, квалификационные
/// вопросы и экран отбора — четыре вопроса экономики + вердикт.
/// Правки коммитятся по потере фокуса — целым сегментом в undo-стек.
struct SegmentEditorView: View {
    @ObservedObject var document: PetableDocument
    let segmentID: UUID

    var body: some View {
        if let segment = document.segmentation.segments.first(where: { $0.id == segmentID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(segment)
                    coreJobsSection(segment)
                    prioritySection(segment)
                    listSection(
                        segment,
                        title: "Каузальные критерии",
                        icon: "person.text.rectangle",
                        hint: "Свойства человека и ситуации, из которых следует, как создавать ценность, маржу и спрос. Симптомы («потратил $1000», «enterprise») — не критерии.",
                        prompt: "Например: готов делегировать проект целиком…",
                        items: \.causalCriteria
                    )
                    listSection(
                        segment,
                        title: "Квалификационные вопросы",
                        icon: "questionmark.bubble",
                        hint: "Каузальные критерии, превращённые в 4–5 вопросов — маршрутизация лида за 60 секунд.",
                        prompt: "Например: время или деньги важнее?",
                        items: \.qualificationQuestions
                    )
                    economicsSection(segment)
                    verdictSection(segment)
                    notesSection(segment)
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            ContentUnavailableView("Сегмент не найден", systemImage: "person.3")
        }
    }

    /// Коммит правки: мутирует копию и отдаёт документу целиком.
    private func modify(_ segment: Segment, _ mutate: (inout Segment) -> Void) {
        var updated = segment
        mutate(&updated)
        document.updateSegment(updated)
    }

    private func header(_ segment: Segment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CommittingTextField(
                prompt: "Название сегмента",
                text: segment.name,
                onCommit: { document.renameSegment(segment.id, to: $0) }
            )
            .font(.system(size: 22, weight: .bold))
            .textFieldStyle(.plain)

            HStack(spacing: 8) {
                Label("Сегмент AJTBD", systemImage: "person.3")
                Text(segment.createdAt, style: .date)
                if let verdict = segment.verdict {
                    Text("\(verdict.badge) \(verdict.title)")
                }
                if segment.resolvedOrigin == .agent {
                    Label("Создано ИИ-агентом", systemImage: "sparkles")
                        .foregroundStyle(Color.purple)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Кóровые работы

    private func coreJobsSection(_ segment: Segment) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                "Кóровые работы и критерии успеха",
                icon: "point.3.connected.trianglepath.dotted",
                hint: "Корень сегментации. Тот же результат с другими критериями или другим порядком приоритетов — другая работа и другой сегмент."
            )
            ForEach(segment.coreJobs) { job in
                coreJobCard(job, segment: segment)
            }
            addButton("Добавить кóровую работу") {
                modify(segment) { $0.coreJobs.append(SegmentCoreJob()) }
            }
        }
    }

    private func coreJobCard(_ job: SegmentCoreJob, segment: Segment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                CommittingTextField(
                    prompt: "хочу + глагол (+ объект)…",
                    text: job.statement,
                    onCommit: { text in
                        modify(segment) { updated in
                            guard let index = updated.coreJobs.firstIndex(where: { $0.id == job.id }) else { return }
                            updated.coreJobs[index].statement = text
                        }
                    }
                )
                .font(.system(size: 13, weight: .semibold))
                .textFieldStyle(.roundedBorder)
                if segment.coreJobs.count > 1 {
                    deleteButton("Удалить работу") {
                        modify(segment) { $0.coreJobs.removeAll { $0.id == job.id } }
                    }
                }
            }
            ForEach(job.successCriteria) { criterion in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    CommittingTextField(
                        prompt: "критерий: ось + порог («за 4 минуты», не «быстро»)…",
                        text: criterion.text,
                        onCommit: { text in
                            modify(segment) { updated in
                                guard let jobIndex = updated.coreJobs.firstIndex(where: { $0.id == job.id }),
                                      let index = updated.coreJobs[jobIndex].successCriteria
                                        .firstIndex(where: { $0.id == criterion.id })
                                else { return }
                                updated.coreJobs[jobIndex].successCriteria[index].text = text
                            }
                        }
                    )
                    .font(.system(size: 12))
                    .textFieldStyle(.roundedBorder)
                    deleteButton("Удалить критерий") {
                        modify(segment) { updated in
                            guard let jobIndex = updated.coreJobs.firstIndex(where: { $0.id == job.id }) else { return }
                            updated.coreJobs[jobIndex].successCriteria.removeAll { $0.id == criterion.id }
                        }
                    }
                }
                .padding(.leading, 12)
            }
            addButton("Добавить критерий", small: true) {
                modify(segment) { updated in
                    guard let index = updated.coreJobs.firstIndex(where: { $0.id == job.id }) else { return }
                    updated.coreJobs[index].successCriteria.append(SegmentListItem())
                }
            }
            .padding(.leading, 12)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        )
    }

    // MARK: Приоритет критериев

    private func prioritySection(_ segment: Segment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                "Порядок приоритетов",
                icon: "list.number",
                hint: "Что сегмент ставит первым. Одинаковые критерии в разном порядке — разные сегменты; ведущая механика ценности выбирается по первому приоритету."
            )
            Picker("Первый приоритет", selection: Binding(
                get: { segment.priority },
                set: { newValue in modify(segment) { $0.priority = newValue } }
            )) {
                Text("Не выбран").tag(CriteriaPriority?.none)
                ForEach(CriteriaPriority.allCases, id: \.self) { priority in
                    Text(priority.title).tag(CriteriaPriority?.some(priority))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .labelsHidden()
        }
    }

    // MARK: Редактируемые списки

    private func listSection(
        _ segment: Segment,
        title: String,
        icon: String,
        hint: String,
        prompt: String,
        items keyPath: WritableKeyPath<Segment, [SegmentListItem]>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title, icon: icon, hint: hint)
            ForEach(segment[keyPath: keyPath]) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    CommittingTextField(
                        prompt: prompt,
                        text: item.text,
                        onCommit: { text in
                            modify(segment) { updated in
                                guard let index = updated[keyPath: keyPath]
                                    .firstIndex(where: { $0.id == item.id })
                                else { return }
                                updated[keyPath: keyPath][index].text = text
                            }
                        }
                    )
                    .font(.system(size: 12))
                    .textFieldStyle(.roundedBorder)
                    deleteButton("Удалить") {
                        modify(segment) { $0[keyPath: keyPath].removeAll { $0.id == item.id } }
                    }
                }
            }
            addButton("Добавить", small: true) {
                modify(segment) { $0[keyPath: keyPath].append(SegmentListItem()) }
            }
        }
    }

    // MARK: Экономика

    private func economicsSection(_ segment: Segment) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                "Экран отбора: экономика",
                icon: "chart.bar",
                hint: "Описание сегмента обязано отвечать на четыре вопроса с доказательствами — иначе это фейковая сегментация."
            )
            economicsRow(
                segment, title: "Ценность",
                question: "Можем ли создать добавленную ценность?",
                answer: \.economics.addedValue
            )
            economicsRow(
                segment, title: "Маржа",
                question: "Можем ли зарабатывать целевую юнит-маржу?",
                answer: \.economics.targetMargin
            )
            economicsRow(
                segment, title: "Спрос",
                question: "Можем ли создать или захватить спрос?",
                answer: \.economics.demand
            )
            economicsRow(
                segment, title: "Масштаб",
                question: "Достаточно ли сегмент велик для масштабирования?",
                answer: \.economics.scale
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("Жёсткий блокер")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                CommittingTextField(
                    prompt: "Регуляторика или невозможная технология; пусто — блокера нет…",
                    text: segment.economics.hardBlocker,
                    onCommit: { text in modify(segment) { $0.economics.hardBlocker = text } }
                )
                .font(.system(size: 12))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func economicsRow(
        _ segment: Segment,
        title: String,
        question: String,
        answer keyPath: WritableKeyPath<Segment, SegmentEconomicsAnswer>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Picker(title, selection: Binding(
                    get: { segment[keyPath: keyPath].rating },
                    set: { newValue in modify(segment) { $0[keyPath: keyPath].rating = newValue } }
                )) {
                    Text("—").tag(SegmentEconomicsRating?.none)
                    ForEach(SegmentEconomicsRating.allCases, id: \.self) { rating in
                        Text(rating.title).tag(SegmentEconomicsRating?.some(rating))
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
            }
            Text(question)
                .font(.system(size: 13))
            CommittingTextField(
                prompt: "Доказательства: работы, бюджет, конкуренты, каналы…",
                text: segment[keyPath: keyPath].evidence,
                axis: .vertical,
                onCommit: { text in modify(segment) { $0[keyPath: keyPath].evidence = text } }
            )
            .font(.system(size: 12))
            .lineLimit(1...6)
            .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: Вердикт и заметки

    private func verdictSection(_ segment: Segment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Вердикт", icon: "flag.checkered", hint: nil)
            Picker("Вердикт", selection: Binding(
                get: { segment.verdict },
                set: { newValue in modify(segment) { $0.verdict = newValue } }
            )) {
                Text("Не решено").tag(SegmentVerdict?.none)
                ForEach(SegmentVerdict.allCases, id: \.self) { verdict in
                    Text("\(verdict.badge) \(verdict.title)").tag(SegmentVerdict?.some(verdict))
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
        }
    }

    private func notesSection(_ segment: Segment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Заметки", icon: "note.text", hint: nil)
            CommittingTextField(
                prompt: "Персона, большие работы, наблюдения…",
                text: segment.notes,
                axis: .vertical,
                onCommit: { text in modify(segment) { $0.notes = text } }
            )
            .font(.system(size: 13))
            .lineLimit(2...12)
            .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: Общие элементы

    private func sectionHeader(_ title: String, icon: String, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func addButton(_ title: String, small: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
                .font(.system(size: small ? 11 : 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    private func deleteButton(_ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Карта сегментов

/// Карта сегментов: сравнительная таблица всех сегментов проекта —
/// кóровые работы, приоритет, четыре оценки экономики, блокер, вердикт.
/// Инструмент выбора, где конкурировать; клик по строке открывает редактор.
struct SegmentMapView: View {
    @ObservedObject var document: PetableDocument
    @State private var selection: Segment.ID?

    var body: some View {
        if document.segmentation.segments.isEmpty {
            ContentUnavailableView {
                Label("Карта сегментов пуста", systemImage: "person.3")
            } description: {
                Text("Сегмент — люди со схожими кóровыми работами и критериями успеха. Добавьте первый, чтобы сравнивать, где конкурировать.")
            } actions: {
                Button("Создать сегмент") { document.addSegment() }
            }
        } else {
            Table(document.segmentation.segments, selection: $selection) {
                TableColumn("Сегмент") { segment in
                    Text(segment.name)
                        .fontWeight(.medium)
                }
                .width(min: 120, ideal: 160)
                TableColumn("Кóровые работы") { segment in
                    Text(segment.coreJobs.map(\.statement)
                        .filter { !$0.isEmpty }
                        .joined(separator: "; "))
                        .lineLimit(2)
                        .help(coreJobsTooltip(segment))
                }
                .width(min: 160, ideal: 240)
                TableColumn("Приоритет") { segment in
                    Text(segment.priority?.title ?? "—")
                        .foregroundStyle(segment.priority == nil ? .secondary : .primary)
                }
                .width(min: 90, ideal: 130)
                TableColumn("Экономика") { segment in
                    HStack(spacing: 6) {
                        ratingDot("Ценность", segment.economics.addedValue.rating)
                        ratingDot("Маржа", segment.economics.targetMargin.rating)
                        ratingDot("Спрос", segment.economics.demand.rating)
                        ratingDot("Масштаб", segment.economics.scale.rating)
                    }
                }
                .width(min: 90, ideal: 100)
                TableColumn("Блокер") { segment in
                    if segment.economics.hardBlocker.isEmpty {
                        Text("—").foregroundStyle(.secondary)
                    } else {
                        Text(segment.economics.hardBlocker)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .help(segment.economics.hardBlocker)
                    }
                }
                .width(min: 70, ideal: 120)
                TableColumn("Вердикт") { segment in
                    Text(segment.verdict.map { "\($0.badge) \($0.title)" } ?? "—")
                        .foregroundStyle(segment.verdict == nil ? .secondary : .primary)
                }
                .width(min: 90, ideal: 110)
            }
            .onChange(of: selection) { _, id in
                guard let id else { return }
                document.selectResearch(.segment(id))
            }
        }
    }

    private func coreJobsTooltip(_ segment: Segment) -> String {
        segment.coreJobs
            .filter { !$0.statement.isEmpty }
            .map { job in
                let criteria = job.successCriteria.map(\.text).filter { !$0.isEmpty }
                return criteria.isEmpty
                    ? job.statement
                    : "\(job.statement) — \(criteria.joined(separator: ", "))"
            }
            .joined(separator: "\n")
    }

    /// Точка-оценка: зелёная/жёлтая/красная; серая — не оценено.
    private func ratingDot(_ title: String, _ rating: SegmentEconomicsRating?) -> some View {
        Circle()
            .fill(color(for: rating))
            .frame(width: 9, height: 9)
            .help("\(title): \(rating?.title ?? "не оценено")")
    }

    private func color(for rating: SegmentEconomicsRating?) -> Color {
        switch rating {
        case .strong: return .green
        case .medium: return .yellow
        case .weak: return .red
        case nil: return Color.secondary.opacity(0.3)
        }
    }
}
