import SwiftUI
import UIKit

// Reversing the drag restores the original selection outside the current range.
// Starting on a selected item subtracts a range, rather than toggling repeatedly.
struct DragSelection {
    let baseline: Set<String>
    let anchor: Int
    let adding: Bool
    init(ids: [String], selection: Set<String>, anchor: Int) {
        self.baseline = selection; self.anchor = anchor
        self.adding = ids.indices.contains(anchor) && !selection.contains(ids[anchor])
    }
    func selection(through end: Int, ids: [String]) -> Set<String> {
        guard ids.indices.contains(anchor), ids.indices.contains(end) else { return baseline }
        let range = Set(ids[min(anchor,end)...max(anchor,end)])
        return adding ? baseline.union(range) : baseline.subtracting(range)
    }
}

struct PendingPhotoGrid: UIViewRepresentable {
    var records: [MediaRecord]
    @Binding var selection: Set<String>
    var enabled: Bool
    var preview: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 4; layout.minimumLineSpacing = 4
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear; view.alwaysBounceVertical = true
        // Let photos scroll underneath the floating glass actions, but leave
        // enough trailing space to bring the final row entirely above them.
        view.contentInset = UIEdgeInsets(top: 0, left: 16, bottom: 100, right: 16)
        view.verticalScrollIndicatorInsets.bottom = 100
        view.register(PhotoCell.self, forCellWithReuseIdentifier: "photo")
        view.dataSource = context.coordinator; view.delegate = context.coordinator
        view.accessibilityIdentifier = "pending.grid"
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.drag(_:)))
        press.minimumPressDuration = 0.3; press.allowableMovement = 12
        view.addGestureRecognizer(press)
        view.panGestureRecognizer.require(toFail: press)
        context.coordinator.collection = view
        return view
    }
    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let ids = records.map(\.id)
        if coordinator.ids != ids {
            coordinator.stop(); coordinator.ids = ids; view.reloadData()
        }
        view.isUserInteractionEnabled = enabled
        coordinator.refreshChecks()
    }
    static func dismantleUIView(_ view: UICollectionView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        var parent: PendingPhotoGrid
        var ids: [String] = []
        weak var collection: UICollectionView?
        private var range: DragSelection?
        private var press: UILongPressGestureRecognizer?
        private var displayLink: CADisplayLink?
        private var lastIndex: Int?
        private var lastTime: CFTimeInterval = 0
        init(_ parent: PendingPhotoGrid) { self.parent = parent }
        func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int { ids.count }
        func collectionView(_ view: UICollectionView, cellForItemAt path: IndexPath) -> UICollectionViewCell {
            let cell = view.dequeueReusableCell(withReuseIdentifier: "photo", for: path) as! PhotoCell
            let record = parent.records[path.item]
            cell.configure(record, selected: parent.selection.contains(record.id))
            cell.preview = { [weak self] in self?.parent.preview(record.id) }
            return cell
        }
        func collectionView(_ view: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt path: IndexPath) -> CGSize {
            let width = floor((view.bounds.width - 32 - 8) / 3)
            return CGSize(width: max(40,width), height: max(40,width))
        }
        func collectionView(_ view: UICollectionView, didSelectItemAt path: IndexPath) {
            guard parent.enabled, ids.indices.contains(path.item), range == nil else { return }
            let id = ids[path.item]
            if parent.selection.contains(id) { parent.selection.remove(id) } else { parent.selection.insert(id) }
            refreshChecks()
        }
        func refreshChecks() {
            guard let collection else { return }
            for case let cell as PhotoCell in collection.visibleCells {
                if let id = cell.photoID { cell.setChecked(parent.selection.contains(id)) }
            }
        }
        @objc func drag(_ gesture: UILongPressGestureRecognizer) {
            guard let collection, parent.enabled else { stop(); return }
            switch gesture.state {
            case .began:
                guard let index = index(at: gesture.location(in: collection)) else { return }
                range = DragSelection(ids: ids, selection: parent.selection, anchor: index)
                press = gesture; update(index)
                UISelectionFeedbackGenerator().selectionChanged()
                let target = ScrollTarget(self)
                let link = CADisplayLink(target: target, selector: #selector(ScrollTarget.tick(_:)))
                link.add(to: .main, forMode: .common); displayLink = link
            case .changed:
                if let index = index(at: gesture.location(in: collection)) { update(index) }
            case .ended, .cancelled, .failed: stop()
            default: break
            }
        }
        private func index(at point: CGPoint) -> Int? {
            guard let view = collection, !ids.isEmpty else { return nil }
            if let item = view.indexPathForItem(at: point)?.item { return item }
            // Include the inter-cell gaps and clamp just outside an edge while scrolling.
            let width = floor((view.bounds.width - 40) / 3), step = max(44,width + 4)
            let row = max(0,Int(floor(point.y / step)))
            let col = min(2,max(0,Int(floor((point.x - 16) / step))))
            return min(ids.count - 1,row * 3 + col)
        }
        private func update(_ index: Int) {
            guard lastIndex != index, let range else { return }
            lastIndex = index
            parent.selection = range.selection(through: index, ids: ids)
            refreshChecks()
        }
        func scroll(_ link: CADisplayLink) {
            guard let view = collection, let press, range != nil else { return }
            let dt = lastTime == 0 ? 1.0 / 60 : min(0.04,link.timestamp - lastTime)
            lastTime = link.timestamp
            let point = press.location(in: view)
            let y = point.y - view.contentOffset.y
            let top = view.adjustedContentInset.top, bottom = view.bounds.height - view.adjustedContentInset.bottom
            let edge: CGFloat = 64
            let speed: CGFloat = y < top + edge ? -min(1,(top + edge - y) / edge) : (y > bottom - edge ? min(1,(y - bottom + edge) / edge) : 0)
            guard speed != 0 else { return }
            let minY = -view.adjustedContentInset.top
            let maxY = max(minY,view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
            let next = min(maxY,max(minY,view.contentOffset.y + speed * 420 * CGFloat(dt)))
            view.contentOffset.y = next
            if let index = index(at: press.location(in: view)) { update(index) }
        }
        func stop() { displayLink?.invalidate(); displayLink = nil; range = nil; press = nil; lastIndex = nil; lastTime = 0 }
    }

    @MainActor private final class ScrollTarget: NSObject {
        weak var owner: Coordinator?
        init(_ owner: Coordinator) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) { owner?.scroll(link) }
    }

    @MainActor final class PhotoCell: UICollectionViewCell {
        private let photo = UIImageView()
        private let check = UIImageView()
        private let video = UIImageView(image: UIImage(systemName: "play.fill"))
        private var task: Task<Void,Never>?
        var photoID: String?
        var preview: (() -> Void)?
        override init(frame: CGRect) {
            super.init(frame: frame)
            contentView.clipsToBounds = true; contentView.layer.cornerRadius = 10
            photo.contentMode = .scaleAspectFill; photo.clipsToBounds = true
            photo.backgroundColor = .secondarySystemFill; photo.tintColor = .tertiaryLabel
            check.contentMode = .scaleAspectFit; check.layer.shadowColor = UIColor.black.cgColor
            check.layer.shadowOpacity = 0.25; check.layer.shadowRadius = 2; check.layer.shadowOffset = .zero
            video.tintColor = .white
            for child in [photo,check,video] { contentView.addSubview(child) }
            isAccessibilityElement = true
            accessibilityCustomActions = [UIAccessibilityCustomAction(name: L.t("查看清晰"), target: self, selector: #selector(showPreview))]
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews(); photo.frame = contentView.bounds
            check.frame = CGRect(x: contentView.bounds.width - 35,y: 7,width: 28,height: 28)
            video.frame = CGRect(x: contentView.bounds.width - 26,y: contentView.bounds.height - 25,width: 16,height: 16)
        }
        override func prepareForReuse() { super.prepareForReuse(); task?.cancel(); task = nil; photoID = nil; photo.image = nil; preview = nil }
        func configure(_ record: MediaRecord, selected: Bool) {
            task?.cancel(); photoID = record.id
            accessibilityIdentifier = "pending.select." + record.id
            video.isHidden = !record.isVideo
            photo.image = UIImage(systemName: "photo")
            setChecked(selected)
            guard !DesignPreview.enabled else { return }
            task = Task { [weak self] in
                let image = await PhotoAccess.image(id: record.id, size: CGSize(width: 320,height: 320))
                guard !Task.isCancelled, self?.photoID == record.id else { return }
                self?.photo.image = image ?? UIImage(systemName: "photo.badge.exclamationmark")
            }
        }
        func setChecked(_ value: Bool) {
            check.image = UIImage(systemName: value ? "checkmark.circle.fill" : "circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold))?
                .applyingSymbolConfiguration(UIImage.SymbolConfiguration(paletteColors: value ? [UIColor(Palette.onAccent),tintColor] : [.white]))
            accessibilityLabel = L.t(value ? "取消选择" : "选择照片")
            accessibilityTraits = value ? [.button,.selected] : [.button]
            contentView.layer.borderWidth = value ? 2 : 0
            contentView.layer.borderColor = tintColor.cgColor
        }
        @objc private func showPreview() -> Bool { preview?(); return true }
    }
}
