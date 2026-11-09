import SwiftUI
import UIKit

// Keep only the visible photo and its two neighbours; never decode a whole album.
@MainActor
final class ReviewImageCache: ObservableObject {
    @Published private(set) var images: [String:UIImage] = [:]
    @Published private(set) var failed: Set<String> = []
    private var tasks: [String:Task<Void,Never>] = [:]
    private var tokens: [String:UUID] = [:]
    private let loader: (String) async -> UIImage?
    init(loader: @escaping (String) async -> UIImage? = { id in
        guard !DesignPreview.enabled else { return nil }
        return await PhotoAccess.image(id:id,size:CGSize(width:2048,height:2048),highQuality:true)
    }) { self.loader = loader }
    func update(_ ids: [String]) {
        let wanted = Set(ids.prefix(3))
        for id in Array(tasks.keys) where !wanted.contains(id) {
            tasks.removeValue(forKey:id)?.cancel(); tokens.removeValue(forKey:id)
        }
        images = images.filter { wanted.contains($0.key) }; failed.formIntersection(wanted)
        for id in ids.prefix(3) where images[id] == nil && tasks[id] == nil {
            let token = UUID(); tokens[id] = token; failed.remove(id)
            tasks[id] = Task { [weak self] in
                guard let self else { return }
                let image = await loader(id)
                guard !Task.isCancelled, tokens[id] == token else { return }
                guard let image, image.cgImage != nil || image.ciImage != nil else {
                    tasks.removeValue(forKey:id); tokens.removeValue(forKey:id); failed.insert(id); return
                }
                // UIKit uses its background preparation queue, so decoding is not
                // deferred to the first frame of the horizontal animation.
                let prepared = await image.byPreparingForDisplay()
                guard !Task.isCancelled, tokens[id] == token else { return }
                tasks.removeValue(forKey:id); tokens.removeValue(forKey:id)
                images[id] = prepared ?? image
            }
        }
    }
    func clear() {
        tasks.values.forEach { $0.cancel() }; tasks = [:]; tokens = [:]; images = [:]; failed = []
    }
}

struct ReviewPager: View {
    let current: String
    let previous: String?
    let next: String?
    let video: Bool
    let step: (Int)->Void
    let stage: ()->Void
    @StateObject private var cache = ReviewImageCache()
    private var window: [String] { [current,next,previous].compactMap { $0 } }
    var body: some View {
        NativeReviewPager(current:current,previous:previous,next:next,video:video,images:cache.images,failed:cache.failed,step:step,stage:stage)
            .onAppear { cache.update(window) }
            .onChange(of:window) { _,ids in cache.update(ids) }
            .onDisappear { cache.clear() }
            .onReceive(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification)) { _ in
                cache.clear(); cache.update([current])
            }
    }
}

private struct NativeReviewPager: UIViewRepresentable {
    let current: String
    let previous: String?
    let next: String?
    let video: Bool
    let images: [String:UIImage]
    let failed: Set<String>
    let step: (Int)->Void
    let stage: ()->Void
    func makeUIView(context: Context) -> ReviewScrollView { ReviewScrollView() }
    func updateUIView(_ view: ReviewScrollView,context: Context) {
        view.configure(current:current,previous:previous,next:next,video:video,images:images,failed:failed,step:step,stage:stage)
    }
}

// UIScrollView supplies native finger tracking, momentum, paging and edge bounce.
// Three reusable image views avoid building thousands of SwiftUI pages.
@MainActor
private final class ReviewScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let cards = (0..<3).map { _ in UIImageView() }
    private let placeholders = (0..<3).map { _ in UILabel() }
    private var pages: [String?] = []
    private var centre = 0
    private var currentID = ""
    private var previousSize = CGSize.zero
    private var step: (Int)->Void = { _ in }
    private var stage: ()->Void = {}
    private var resetPosition = true
    private var vertical: UIPanGestureRecognizer!
    override init(frame: CGRect) {
        super.init(frame:frame)
        delegate = self; isPagingEnabled = true; isDirectionalLockEnabled = true
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = UIColor(Palette.surface)
        accessibilityIdentifier = "review.photo"; isAccessibilityElement = true
        accessibilityTraits = [.image,.allowsDirectInteraction]
        for i in cards.indices {
            cards[i].contentMode = .scaleAspectFit; cards[i].clipsToBounds = true
            addSubview(cards[i]); placeholders[i].textAlignment = .center
            placeholders[i].font = .preferredFont(forTextStyle:.subheadline)
            placeholders[i].textColor = .secondaryLabel; addSubview(placeholders[i])
        }
        vertical = UIPanGestureRecognizer(target:self,action:#selector(verticalPan(_:)))
        vertical.delegate = self; addGestureRecognizer(vertical)
        panGestureRecognizer.require(toFail:vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(current: String,previous: String?,next: String?,video: Bool,images: [String:UIImage],failed: Set<String>,step: @escaping (Int)->Void,stage: @escaping ()->Void) {
        self.step = step; self.stage = stage
        let newPages: [String?] = previous == nil ? [current,next] : [previous,current,next]
        if currentID != current || pages != newPages {
            currentID = current; pages = newPages; centre = previous == nil ? 0 : 1
            resetPosition = true
        }
        accessibilityLabel = L.t(video ? "视频" : "照片")
        for i in cards.indices {
            let shown = i < pages.count
            cards[i].isHidden = !shown; placeholders[i].isHidden = !shown
            let id = shown ? pages[i] : nil
            cards[i].image = id.flatMap { images[$0] }
            if let id {
                placeholders[i].text = cards[i].image == nil ? L.t(failed.contains(id) ? "图片暂不可用，请点查看清晰" : "正在读取清晰照片…") : nil
            } else { placeholders[i].text = L.t("这一组看完了") }
        }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        let size = bounds.size
        for i in cards.indices {
            let frame = CGRect(x:CGFloat(i)*size.width,y:0,width:size.width,height:size.height)
            cards[i].frame = frame; placeholders[i].frame = frame
        }
        contentSize = CGSize(width:CGFloat(pages.count)*size.width,height:size.height)
        if resetPosition || previousSize != size {
            resetPosition = false; previousSize = size
            setContentOffset(CGPoint(x:CGFloat(centre)*size.width,y:0),animated:false)
        }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView,willDecelerate decelerate: Bool) { if !decelerate { settle() } }
    private func settle() {
        guard bounds.width > 0 else { return }
        let page = Int((contentOffset.x/bounds.width).rounded())
        let direction = page-centre
        if direction != 0 { step(direction > 0 ? 1 : -1) }
        else { setContentOffset(CGPoint(x:CGFloat(centre)*bounds.width,y:0),animated:true) }
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === vertical else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        let velocity = vertical.velocity(in:self)
        return velocity.y < 0 && abs(velocity.y) > abs(velocity.x)*1.2 && !isDecelerating
    }
    @objc private func verticalPan(_ pan: UIPanGestureRecognizer) {
        let distance = pan.translation(in:superview).y
        switch pan.state {
        case .changed: transform = CGAffineTransform(translationX:0,y:min(0,distance)*0.65)
        case .ended:
            if distance < -100 || pan.velocity(in:superview).y < -750 { stage() }
            fallthrough
        case .cancelled,.failed:
            UIView.animate(withDuration:0.25,delay:0,usingSpringWithDamping:0.9,initialSpringVelocity:0) { self.transform = .identity }
        default: break
        }
    }
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        if direction == .left { step(1); return true }
        if direction == .right { step(-1); return true }
        if direction == .up { stage(); return true }
        return false
    }
}
