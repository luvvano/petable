import GraphCore
import SwiftUI

/// Комментарии графа = записи механик (MechanicSticker) с тредами.
/// Два представления одного и того же: окно по клику на конвертик узла
/// и правый сайдбар со всеми комментариями графа (как в Confluence).
enum CommentsUI {
    /// Русский заголовок механики; слаг как есть, если каталог не загрузился.
    static func mechanicTitle(_ slug: String) -> String {
        guard case let .success(catalog) = MechanicCatalogStore.result,
              let mechanic = catalog.mechanic(slug)
        else { return slug }
        return mechanic.title
    }

    /// Изображение комментария: у каждой механики свой SF Symbol из
    /// словаря; конвертик — только запасной вариант для чужого слага.
    static func mechanicSymbol(_ slug: String) -> String {
        guard case let .success(catalog) = MechanicCatalogStore.result,
              let mechanic = catalog.mechanic(slug)
        else { return "envelope.fill" }
        return mechanic.symbol
    }

    /// Подпись якоря комментария: живой текст работы из графа, а для
    /// удалённого якоря — снимок текста на момент применения.
    static func anchorLabel(_ sticker: MechanicSticker, in graph: WorkGraph) -> String? {
        switch sticker.anchor {
        case let .node(id):
            if let job = graph.job(id) { return job.displayText }
            guard !sticker.anchorLabels.isEmpty else { return "работа удалена" }
            return "\(sticker.anchorLabels.joined(separator: ", ")) — работа удалена"
        case let .chainEdge(from, to):
            let labels = [graph.job(from)?.displayText, graph.job(to)?.displayText]
                .compactMap { $0 }
            if labels.count == 2 { return labels.joined(separator: " → ") }
            guard !sticker.anchorLabels.isEmpty else { return "связь удалена" }
            return sticker.anchorLabels.joined(separator: " → ")
        case let .zone(id):
            if let zone = graph.levels.flatMap(\.zones).first(where: { $0.id == id }) {
                return zone.resolvedName
            }
            return sticker.anchorLabels.first ?? "область удалена"
        case .unanchored:
            return nil
        }
    }
}

/// Тред одного комментария: механика, заметка, реплики, поле ответа.
/// Общий для окна конвертика и сайдбара.
struct StickerThreadView: View {
    @ObservedObject var document: PetableDocument
    let sticker: MechanicSticker
    /// Показывать подпись якоря (в окне узла она избыточна — узел и так
    /// известен, в сайдбаре обязательна).
    var showsAnchor = false

    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Изображение механики — то же, что на бейдже узла.
                Image(systemName: CommentsUI.mechanicSymbol(sticker.slug))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 13, height: 13)
                    .padding(3)
                    .background(Circle().fill(Color.orange.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text(CommentsUI.mechanicTitle(sticker.slug))
                        .font(.system(size: 12, weight: .semibold))
                    if showsAnchor,
                       let label = CommentsUI.anchorLabel(sticker, in: document.graph) {
                        Text(label)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(sticker.createdAt, format: .dateTime.day().month())
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Button {
                    document.removeMechanicSticker(sticker.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Убрать комментарий (⌘Z вернёт)")
            }

            if !sticker.note.isEmpty {
                Text(sticker.note)
                    .font(.system(size: 11.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            // Тред обсуждения — реплики под комментарием, как в Confluence.
            ForEach(sticker.messages) { message in
                HStack(alignment: .top, spacing: 6) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.orange.opacity(0.45))
                        .frame(width: 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(message.text)
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Text(message.createdAt, format: .dateTime.day().month().hour().minute())
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 2)
            }

            TextField("Ответить…", text: $reply)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit {
                    document.addStickerMessage(sticker.id, text: reply)
                    reply = ""
                }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }
}

/// Окно комментариев узла — открывается кликом по конвертику на работе.
struct NodeCommentsPopover: View {
    @ObservedObject var document: PetableDocument
    let jobID: UUID

    private var stickers: [MechanicSticker] {
        document.stickers.filter { $0.anchor == .node(jobID) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(document.graph.job(jobID)?.displayText ?? "Комментарии")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                ForEach(stickers) { sticker in
                    StickerThreadView(document: document, sticker: sticker)
                }
            }
            .padding(12)
        }
        .frame(width: 320)
        .frame(minHeight: 120, maxHeight: 420)
    }
}

/// Правый сайдбар комментариев графа: все записи механик с тредами.
/// Клик по комментарию выделяет и центрирует его якорь на канвасе.
struct CommentsSidebar: View {
    @ObservedObject var document: PetableDocument
    /// Комментарий, чей якорь сейчас выделен на канвасе.
    let revealedID: UUID?
    let onReveal: (MechanicSticker) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Комментарии", systemImage: "envelope")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Закрыть комментарии")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()

            if document.stickers.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "envelope")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("Комментариев пока нет.\nПримените механику ценности (⌘K) — запись появится здесь.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(document.stickers) { sticker in
                            StickerThreadView(
                                document: document,
                                sticker: sticker,
                                showsAnchor: true
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        revealedID == sticker.id
                                            ? Color.accentColor.opacity(0.8)
                                            : .clear,
                                        lineWidth: 1.5
                                    )
                            )
                            .contentShape(Rectangle())
                            // Клик по комментарию — выделить и показать якорь.
                            // simultaneousGesture: обычный onTapGesture съел бы
                            // клики полей ответа и кнопок внутри треда.
                            .simultaneousGesture(TapGesture().onEnded { onReveal(sticker) })
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
    }
}
