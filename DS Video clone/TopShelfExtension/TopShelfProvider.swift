import TVServices

// MARK: - Shared model (local copy for the extension process)
// Keep in sync with TopShelfItem.swift in the main app target.

private struct TopShelfItem: Codable {
    let id: String
    let title: String
    let year: Int?
    let imageURL: String?
    let deepLinkURL: String
}

// MARK: - Provider

@objc(TopShelfProvider)
class TopShelfProvider: TVTopShelfContentProvider {

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let items = loadSnapshot()
        guard !items.isEmpty else { return nil }

        let shelfItems: [TVTopShelfSectionedItem] = items.compactMap { snapshot in
            guard let deepLink = URL(string: snapshot.deepLinkURL) else { return nil }
            let item = TVTopShelfSectionedItem(identifier: snapshot.id)
            item.title = snapshot.title
            item.playAction = TVTopShelfAction(url: deepLink)
            item.displayAction = TVTopShelfAction(url: deepLink)
            if let imageString = snapshot.imageURL, let imageURL = URL(string: imageString) {
                item.setImageURL(imageURL, for: .screenScale1x)
                item.setImageURL(imageURL, for: .screenScale2x)
            }
            return item
        }

        let section = TVTopShelfItemCollection(items: shelfItems)
        section.title = "Just Added"
        return TVTopShelfSectionedContent(sections: [section])
    }

    // MARK: - Private

    private func loadSnapshot() -> [TopShelfItem] {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.HeiloProjects.DSReel"
        ) else { return [] }

        let fileURL = container.appendingPathComponent("topshelf.json")
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([TopShelfItem].self, from: data)) ?? []
    }
}
